#!/usr/bin/env python3
"""Permanent guard for Resources/Localizable.xcstrings.

Compares the catalog against the keys the build targets actually claim, by
extracting the strings of a *virgin* DerivedData build with
`SWIFT_EMIT_LOC_STRINGS=YES` — the only source of truth (the catalog's own
`extractionState` marks 461 live keys as `stale`, so it is not a signal).

Four rules, each one printing the offending keys, one per line:

  R1 dead keys        in the catalog, claimed by no build target
  R2 missing keys     claimed with words, absent from the catalog
  R3 untranslated     claimed, present, missing one of fr/de/es/it
  R4 plural forms     a key that formats an integer counter (`%lld`, `%d`,
                      `%2$lld`…) has plural forms in en/fr/de/es/it: one
                      `variations.plural` with `one` and `other`, or, for a
                      key with several counters, one plural substitution per
                      counter. Closed exceptions: "N of M" reports,
                      percentages and a named list of bare numbers
                      (PLURAL_EXCEPTIONS); an exception that is not one of
                      those three is itself refused.

Options: `--catalog PATH` audits another catalog; `--plurals-only` runs only
R4 — no build, no Xcode — and prints `plural violations: <n>`.

Exit codes: 0 = all four sets empty, 1 = at least one offending key,
2 = tooling (no valid DEVELOPER_DIR/xcodebuild, build failed, extraction
incomplete, catalog unreadable).

The script only reports — it never edits the catalog or a source file. It runs
offline. ~40 s on a cold DerivedData.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
CATALOG_PATH = REPO_ROOT / "Resources" / "Localizable.xcstrings"
PROJECT = "ImmichSwiftUI.xcodeproj"
SCHEME = "ImmichSwiftUI"
DESTINATION = "generic/platform=iOS Simulator"
DEFAULT_DERIVED_DATA = Path("/tmp/immich-i18n-audit-dd")

SHIPPED_LANGUAGES = ("fr", "de", "es", "it")

# The four products that ship strings, mirroring project.yml's `sources`. A
# plain string is a directory (every .swift under it); a string ending in
# `*.swift` is a single file. This list is cross-checked against what the build
# actually extracted, so a project.yml change that is not mirrored here fails
# loudly instead of silently narrowing the audit.
TARGET_SOURCES: dict[str, list[str]] = {
    "ImmichSwiftUI": [
        "Sources",
        "ImmichShareExtension/ShareItem.swift",
        "ImmichShareExtension/ShareExtensionViewModel.swift",
    ],
    "ImmichSharedKit": ["Sources/ImmichSharedKit"],
    "ImmichWidgets": ["ImmichWidgets"],
    "ImmichShareExtension": [
        "ImmichShareExtension",
        "Sources/DesignSystem/Tokens",
    ],
}

# Extraction artifacts the compiler emits for things that are not a source
# file. Anything else in the extraction that matches no listed .swift is a
# signal that this script's expected lists went stale.
GENERATED_BASENAMES = frozenset(
    {
        "ExtractedAppShortcutsMetadata",
        "GeneratedAssetSymbols",
    }
)

# Same rule as Tests/AppStringsTests.hasWords: a key carrying only format
# specifiers and punctuation has nothing to translate.
_FORMAT_SPECIFIER = re.compile(r"%(\d+\$)?[@dfslu]|%lld|%@")


def has_words(key: str) -> bool:
    return any(ch.isalpha() for ch in _FORMAT_SPECIFIER.sub("", key))


# R4. A counter is an integer format specifier, optionally positional
# (`%2$lld`). `%%` is a literal percent sign and is removed before matching.
_COUNTER = re.compile(r"%(?:(\d+)\$)?(?:lld|ld|llu|lu|d|u|i)")
_INTEGER_SPECIFIERS = frozenset({"lld", "ld", "llu", "lu", "d", "u", "i"})
_SUBSTITUTION_REFERENCE = re.compile(r"%#@([A-Za-z_][A-Za-z0-9_]*)@")
_RATIO = re.compile(r"%(?:\d+\$)?lld(?: of |/)%(?:\d+\$)?lld")

PLURAL_LANGUAGES = ("en", "fr", "de", "es", "it")

# The closed list of counted keys that take no plural (decision #7). Every
# entry is re-checked against its category: a key that counts something nameable
# ("Log out %lld devices") is refused, so the list cannot grow by accident.
#   ratio   "N of M" / "N/M" reports
#   percent percentages
#   number  a number with no counted noun (NAMED_NUMBERS)
NAMED_NUMBERS = frozenset(
    {
        "%lld",
        "+%lld",
        "Users (%lld)",
        "Libraries (%lld)",
        "Stop %lld",
        "URLError %lld",
        "iCloud not ready yet — retrying (%lld)…",
        "%lldy",
    }
)
PLURAL_EXCEPTIONS: dict[str, str] = {
    **{
        key: "ratio"
        for key in (
            "%lld of %lld",
            "%lld of %lld downloads in progress",
            "Cancelled — %lld of %lld done",
            "Page %lld of %lld",
            "Photo %lld of %lld",
            "Slide %lld of %lld: %@",
            "Swimmich backup, %lld of %lld, %@",
            "Uploading %lld/%lld",
        )
    },
    **{
        key: "percent"
        for key in (
            "%lld percent",
            "%lld%%",
            "%lld percent of the offline storage budget used",
            "Backing up — %lld percent",
            "Backing up, %lld percent",
            "Crop square, %lld percent of the image",
            "Downloading from iCloud… %lld%%",
            "Uploading %lld%%",
        )
    },
    **{key: "number" for key in sorted(NAMED_NUMBERS)},
}


def fail(message: str) -> None:
    print(f"i18n-audit: error: {message}", file=sys.stderr)
    sys.exit(2)


def developer_dir() -> Path:
    configured = os.environ.get("DEVELOPER_DIR")
    if configured:
        path = Path(configured)
    else:
        try:
            path = Path(
                subprocess.run(
                    ["xcode-select", "-p"],
                    check=True,
                    capture_output=True,
                    text=True,
                ).stdout.strip()
            )
        except (OSError, subprocess.CalledProcessError) as error:
            fail(f"cannot resolve DEVELOPER_DIR (xcode-select -p failed: {error})")
    if not path.exists():
        fail(f"DEVELOPER_DIR does not exist: {path}")
    return path


def expected_basenames(target: str) -> set[str]:
    basenames: set[str] = set()
    for entry in TARGET_SOURCES[target]:
        if entry.endswith(".swift"):
            basenames.add(Path(entry).stem)
        else:
            basenames.update(path.stem for path in (REPO_ROOT / entry).rglob("*.swift"))
    return basenames


def extract(derived_data: Path, jobs: int) -> Path:
    """Builds with string extraction on a virgin DerivedData. Returns the
    `ImmichSwiftUI.build` intermediates directory."""
    shutil.rmtree(derived_data, ignore_errors=True)
    command = [
        "xcodebuild",
        "build",
        "-project",
        PROJECT,
        "-scheme",
        SCHEME,
        "-destination",
        DESTINATION,
        "-derivedDataPath",
        str(derived_data),
        "-jobs",
        str(jobs),
        "SWIFT_EMIT_LOC_STRINGS=YES",
    ]
    print(f"i18n-audit: extracting strings into {derived_data} …", file=sys.stderr)
    process = subprocess.run(
        command,
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        env={**os.environ, "DEVELOPER_DIR": str(developer_dir())},
    )
    if process.returncode != 0:
        print(process.stdout[-4000:], file=sys.stderr)
        print(process.stderr[-4000:], file=sys.stderr)
        fail(f"xcodebuild failed with status {process.returncode}")
    intermediates = derived_data / "Build/Intermediates.noindex" / f"{SCHEME}.build"
    if not intermediates.is_dir():
        fail(f"no build intermediates under {intermediates}")
    return intermediates


def collect(
    intermediates: Path,
) -> tuple[set[str], dict[str, set[str]], list[str]]:
    """Returns (claimed keys, keys per claiming target, coverage problems)."""
    claimed: set[str] = set()
    claimed_by: dict[str, set[str]] = {}
    problems: list[str] = []

    for target in TARGET_SOURCES:
        target_dir = next(
            iter(sorted(intermediates.glob(f"*-iphonesimulator/{target}.build"))),
            None,
        )
        if target_dir is None:
            problems.append(f"{target}: no build products (target not built?)")
            continue
        artifacts = sorted(target_dir.glob("Objects-normal/*/*.stringsdata"))
        observed = {artifact.stem for artifact in artifacts}
        expected = expected_basenames(target)

        for basename in sorted(expected - observed):
            problems.append(f"{target}: compiled without extraction: {basename}.swift")
        unattributed = observed - expected - GENERATED_BASENAMES
        for basename in sorted(unattributed):
            problems.append(
                f"{target}: extracted artifact matches no project.yml source "
                f"(TARGET_SOURCES is stale?): {basename}.stringsdata"
            )

        # Generated artifacts are read too: `ExtractedAppShortcutsMetadata`
        # carries the AppShortcuts table whose keys (`Run ${applicationName}
        # backup`) ship in the same Localizable catalog. They are excluded from
        # the coverage arithmetic only (they match no .swift file).
        for artifact in artifacts:
            try:
                payload = json.loads(artifact.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError) as error:
                problems.append(f"{target}: unreadable {artifact.name}: {error}")
                continue
            # Every table of a .stringsdata feeds the same Localizable
            # catalog — filtering on the table name would report the
            # AppShortcuts keys (e.g. "Run ${applicationName} backup",
            # translated) as dead.
            for entries in (payload.get("tables") or {}).values():
                for entry in entries or []:
                    if entry.get("shouldTranslate") is False:
                        continue
                    key = entry.get("key")
                    if key is None:
                        continue
                    claimed.add(key)
                    claimed_by.setdefault(key, set()).add(target)

    return claimed, claimed_by, problems


def load_catalog(path: Path = CATALOG_PATH) -> dict[str, object]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"cannot read {path}: {error}")
    strings = payload.get("strings") if isinstance(payload, dict) else None
    if not isinstance(strings, dict):
        fail(f"{path} has no `strings` object")
    return strings


def has_text(unit: object) -> bool:
    """True when `unit` is a `stringUnit` holder with a non-empty value."""
    if not isinstance(unit, dict):
        return False
    string_unit = unit.get("stringUnit")
    if not isinstance(string_unit, dict):
        return False
    value = string_unit.get("value")
    return isinstance(value, str) and bool(value.strip())


def is_translated(localization: object) -> bool:
    """A plain `stringUnit`, or a plural whose every form has a non-empty text."""
    if has_text(localization):
        return True
    if not isinstance(localization, dict):
        return False
    variations = localization.get("variations")
    plural = variations.get("plural") if isinstance(variations, dict) else None
    return isinstance(plural, dict) and bool(plural) and all(has_text(form) for form in plural.values())


def untranslated_languages(entry: object) -> list[str]:
    """Shipped languages with no non-empty translation for this key."""
    if not isinstance(entry, dict):
        return list(SHIPPED_LANGUAGES)
    localizations = entry.get("localizations")
    if not isinstance(localizations, dict):
        return list(SHIPPED_LANGUAGES)
    return [language for language in SHIPPED_LANGUAGES if not is_translated(localizations.get(language))]


def counters_of(key: str) -> list[int]:
    """Positions (1-based) of the integer counters a key formats. `%%` is a
    literal percent sign, not a counter; `%N$lld` names its own position."""
    positions: list[int] = []
    for rank, match in enumerate(_COUNTER.finditer(key.replace("%%", "")), start=1):
        positions.append(int(match.group(1)) if match.group(1) else rank)
    return positions


def _form_violations(plural: dict, suffix: str) -> list[str]:
    """`one` and `other` must exist; every form present must have a text."""
    problems: list[str] = []
    for form in ("one", "other"):
        if form not in plural:
            problems.append(f"missing form {form}{suffix}")
    for form, unit in plural.items():
        if form in plural and not has_text(unit):
            problems.append(f"empty form {form}{suffix}")
    return problems


def _plural_of(holder: object) -> dict | None:
    if not isinstance(holder, dict):
        return None
    variations = holder.get("variations")
    plural = variations.get("plural") if isinstance(variations, dict) else None
    return plural if isinstance(plural, dict) and plural else None


def _language_violations(localization: object, counters: list[int]) -> list[str]:
    """Plural problems of one language of one counted key."""
    if not isinstance(localization, dict):
        return ["no plural forms"]
    substitutions = localization.get("substitutions")
    substitutions = substitutions if isinstance(substitutions, dict) else {}
    own_plural = _plural_of(localization)
    plural_substitutions = {name: sub for name, sub in substitutions.items() if _plural_of(sub) is not None}
    if own_plural is None and not plural_substitutions:
        return ["no plural forms"]
    if len(counters) == 1 and own_plural is not None:
        return _form_violations(own_plural, "")

    value = ""
    string_unit = localization.get("stringUnit")
    if isinstance(string_unit, dict) and isinstance(string_unit.get("value"), str):
        value = string_unit["value"]
    references = _SUBSTITUTION_REFERENCE.findall(value)

    problems: list[str] = []
    covered: set[str] = set()
    for position in range(1, len(counters) + 1):
        match = None
        for name, sub in plural_substitutions.items():
            arg_num = sub.get("argNum")
            if arg_num is None and name in references:
                arg_num = references.index(name) + 1
            if arg_num == position and sub.get("formatSpecifier") in _INTEGER_SPECIFIERS:
                match = name
                break
        if match is None:
            problems.append(f"argument {position} has no plural substitution")
            continue
        covered.add(match)
        problems.extend(_form_violations(_plural_of(plural_substitutions[match]), f" in substitution {match}"))
    for name in sorted(covered):
        if f"%#@{name}@" not in value:
            problems.append(f"substitution {name} not referenced")
    return problems


def plural_violations(catalog: dict) -> list[str]:
    """R4: every key that formats an integer counter has plural forms in all
    five languages, unless it is one of the closed exceptions. No build."""
    problems: list[str] = []
    for key, entry in catalog.items():
        counters = counters_of(key)
        if not counters:
            continue
        category = PLURAL_EXCEPTIONS.get(key)
        if category is not None:
            accepted = {
                "ratio": _RATIO.search(key) is not None,
                "percent": "percent" in key or "%%" in key,
                "number": key in NAMED_NUMBERS,
            }.get(category, False)
            if not accepted:
                problems.append(f"{key}  exception refused: not a ratio, a percentage or a named number")
            continue
        localizations = entry.get("localizations") if isinstance(entry, dict) else None
        localizations = localizations if isinstance(localizations, dict) else {}
        for language in PLURAL_LANGUAGES:
            for problem in _language_violations(localizations.get(language), counters):
                problems.append(f"{key}  {language}: {problem}")
    return sorted(problems)


def print_plural_violations(violations: list[str]) -> None:
    print(f"plural violations: {len(violations)}")
    for line in violations:
        print(f"  - {line}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--derived-data",
        type=Path,
        default=DEFAULT_DERIVED_DATA,
        help=f"DerivedData for the audit build (deleted first). Default: {DEFAULT_DERIVED_DATA}",
    )
    parser.add_argument("--jobs", type=int, default=6, help="xcodebuild -jobs (default: 6)")
    parser.add_argument(
        "--catalog",
        type=Path,
        default=CATALOG_PATH,
        help=f"String Catalog to audit. Default: {CATALOG_PATH}",
    )
    parser.add_argument(
        "--plurals-only",
        action="store_true",
        help="run only R4 (plural forms) on the catalog: no build, no Xcode needed",
    )
    arguments = parser.parse_args()

    catalog = load_catalog(arguments.catalog)
    violations = plural_violations(catalog)
    if arguments.plurals_only:
        print_plural_violations(violations)
        return 1 if violations else 0

    claimed, claimed_by, coverage = collect(extract(arguments.derived_data, arguments.jobs))
    if coverage:
        print("i18n-audit: extraction is not complete — no key verdict is rendered", file=sys.stderr)
        for problem in coverage:
            print(f"  - {problem}", file=sys.stderr)
        return 2

    dead = sorted(set(catalog) - claimed)
    missing = sorted(key for key in claimed - set(catalog) if has_words(key))
    untranslated = sorted(
        key for key in claimed & set(catalog) if has_words(key) and untranslated_languages(catalog[key])
    )

    print(f"catalog: {len(catalog)} keys, {len(claimed)} claimed")
    print(f"dead keys (in the catalog, claimed by no build target): {len(dead)}")
    for key in dead:
        print(f"  - {key}")
    print(f"missing keys (claimed with words, absent from the catalog): {len(missing)}")
    for key in missing:
        targets = ", ".join(sorted(claimed_by.get(key, ())))
        print(f"  - {key}  claimed by {targets}")
    print(f"untranslated keys (claimed, missing a shipped language): {len(untranslated)}")
    for key in untranslated:
        languages = ", ".join(untranslated_languages(catalog[key]))
        print(f"  - {key}  missing: {languages}")
    print_plural_violations(violations)

    return 1 if dead or missing or untranslated or violations else 0


if __name__ == "__main__":
    sys.exit(main())
