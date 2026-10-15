#!/usr/bin/env python3
"""Permanent guard for Resources/Localizable.xcstrings.

Compares the catalog against the keys the build targets actually claim, by
extracting the strings of a *virgin* DerivedData build with
`SWIFT_EMIT_LOC_STRINGS=YES` — the only source of truth (the catalog's own
`extractionState` marks 461 live keys as `stale`, so it is not a signal).

Three rules, each one printing the offending keys, one per line:

  R1 dead keys        in the catalog, claimed by no build target
  R2 missing keys     claimed with words, absent from the catalog
  R3 untranslated     claimed, present, missing one of fr/de/es/it

Exit codes: 0 = all three sets empty, 1 = at least one offending key,
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


def load_catalog() -> dict[str, object]:
    try:
        payload = json.loads(CATALOG_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"cannot read {CATALOG_PATH}: {error}")
    strings = payload.get("strings")
    if not isinstance(strings, dict):
        fail(f"{CATALOG_PATH} has no `strings` object")
    return strings


def untranslated_languages(entry: object) -> list[str]:
    """Shipped languages with no non-empty translation for this key."""
    if not isinstance(entry, dict):
        return list(SHIPPED_LANGUAGES)
    localizations = entry.get("localizations")
    if not isinstance(localizations, dict):
        return list(SHIPPED_LANGUAGES)
    missing: list[str] = []
    for language in SHIPPED_LANGUAGES:
        unit = localizations.get(language)
        value = None
        if isinstance(unit, dict):
            string_unit = unit.get("stringUnit")
            if isinstance(string_unit, dict):
                value = string_unit.get("value")
        if not isinstance(value, str) or not value.strip():
            missing.append(language)
    return missing


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--derived-data",
        type=Path,
        default=DEFAULT_DERIVED_DATA,
        help=f"DerivedData for the audit build (deleted first). Default: {DEFAULT_DERIVED_DATA}",
    )
    parser.add_argument("--jobs", type=int, default=6, help="xcodebuild -jobs (default: 6)")
    arguments = parser.parse_args()

    catalog = load_catalog()
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

    return 1 if dead or missing or untranslated else 0


if __name__ == "__main__":
    sys.exit(main())
