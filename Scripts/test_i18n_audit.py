"""Tests of R4 (plural forms) of Scripts/i18n-audit.py.

Run with `python3 -m unittest discover -s Scripts -p 'test_*.py'` (Scripts/ci.sh
does). Each case writes a minimal catalog to a temporary file and runs the
audit's `--plurals-only` mode on it, exactly as a developer or the CI would.
Standard library only; no Xcode, no build.
"""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "Scripts" / "i18n-audit.py"
LANGUAGES = ("en", "fr", "de", "es", "it")


def load_audit_module():
    spec = importlib.util.spec_from_file_location("i18n_audit", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def unit(value: str) -> dict:
    return {"stringUnit": {"state": "translated", "value": value}}


def plural(one: str, other: str) -> dict:
    return {"variations": {"plural": {"one": unit(one), "other": unit(other)}}}


def substitution(arg_num: int, one: str, other: str) -> dict:
    return {"argNum": arg_num, "formatSpecifier": "lld", **plural(one, other)}


def counted(key: str, **overrides: dict) -> dict:
    """A one-counter key with valid plural forms in the five languages,
    except where `overrides` (language -> localization) say otherwise."""
    localizations = {language: plural(key.replace("%lld", "%lld x", 1), key) for language in LANGUAGES}
    localizations.update(overrides)
    return {"localizations": localizations}


def two_counters(**overrides: dict) -> dict:
    """`%lld photos · %lld videos` with complete substitutions everywhere,
    except where `overrides` (language -> localization) say otherwise."""
    localizations = {
        language: {
            **unit("%#@photos@ · %#@videos@"),
            "substitutions": {
                "photos": substitution(1, "%arg photo", "%arg photos"),
                "videos": substitution(2, "%arg video", "%arg videos"),
            },
        }
        for language in LANGUAGES
    }
    localizations.update(overrides)
    return {"localizations": localizations}


def run_audit(catalog: dict) -> subprocess.CompletedProcess:
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "Localizable.xcstrings"
        path.write_text(json.dumps({"sourceLanguage": "en", "strings": catalog, "version": "1.0"}), encoding="utf-8")
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--plurals-only", "--catalog", str(path)],
            cwd=ROOT,
            capture_output=True,
            text=True,
        )


class PluralAuditTests(unittest.TestCase):
    def assert_fails_with(self, result: subprocess.CompletedProcess, *fragments: str) -> None:
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        for fragment in fragments:
            self.assertIn(fragment, result.stdout)

    def test_AC_32_7_singleFormInOneLanguageFails(self) -> None:
        catalog = {"%lld selected": counted("%lld selected", fr=unit("%lld sélectionné(s)"))}
        self.assert_fails_with(run_audit(catalog), "%lld selected", "fr: no plural forms")

    def test_AC_32_7_pluralMissingInGermanFails(self) -> None:
        catalog = {"%lld selected": counted("%lld selected", de=unit("%lld ausgewählt"))}
        result = run_audit(catalog)
        self.assert_fails_with(result, "de: no plural forms")
        self.assertNotIn("fr:", result.stdout)

    def test_AC_32_7_emptyFormFails(self) -> None:
        catalog = {"%lld selected": counted("%lld selected", it=plural("%lld selezionato", ""))}
        self.assert_fails_with(run_audit(catalog), "it: empty form other")

    def test_AC_32_7_multiCounterWithoutSubstitutionFails(self) -> None:
        only_photos = {
            **unit("%#@photos@ · %lld Videos"),
            "substitutions": {"photos": substitution(1, "%arg Foto", "%arg Fotos")},
        }
        result = run_audit({"%lld photos · %lld videos": two_counters(de=only_photos)})
        self.assert_fails_with(result, "%lld photos · %lld videos", "de: argument 2 has no plural substitution")

        empty_form = {
            **unit("%#@photos@ · %#@videos@"),
            "substitutions": {
                "photos": substitution(1, "%arg Foto", "%arg Fotos"),
                "videos": substitution(2, "", "%arg Videos"),
            },
        }
        result = run_audit({"%lld photos · %lld videos": two_counters(de=empty_form)})
        self.assert_fails_with(result, "de: empty form one in substitution videos")

    def test_AC_32_7_multiCounterWithFullSubstitutionsPasses(self) -> None:
        result = run_audit({"%lld photos · %lld videos": two_counters()})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("plural violations: 0", result.stdout)

    def test_AC_32_7_countableExceptionIsRefused(self) -> None:
        audit = load_audit_module()
        audit.PLURAL_EXCEPTIONS = {**audit.PLURAL_EXCEPTIONS, "Log out %lld devices": "number"}
        catalog = {"Log out %lld devices": {"localizations": {language: unit("Log out %lld devices") for language in LANGUAGES}}}
        violations = audit.plural_violations(catalog)
        self.assertEqual(len(violations), 1, violations)
        self.assertIn("Log out %lld devices", violations[0])
        self.assertIn("exception refused", violations[0])

    def test_AC_32_7_exceptionsPassWithoutForms(self) -> None:
        catalog = {
            key: {"localizations": {language: unit(key) for language in LANGUAGES}}
            for key in ("Page %lld of %lld", "%lld percent", "Users (%lld)")
        }
        result = run_audit(catalog)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_AC_32_7_keyWithoutCounterIgnored(self) -> None:
        catalog = {
            key: {"localizations": {language: unit(key) for language in LANGUAGES}} for key in ("Photos", "%@ today")
        }
        result = run_audit(catalog)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_AC_32_7_literalPercentIsNotACounter(self) -> None:
        audit = load_audit_module()
        self.assertEqual(audit.counters_of("100%% sure"), [])
        self.assertEqual(audit.counters_of("%lld%%"), [1])
        self.assertEqual(audit.counters_of("%2$lld of %1$lld"), [2, 1])

    def test_AC_32_8_shippedCatalogPasses(self) -> None:
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--plurals-only"],
            cwd=ROOT,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("plural violations: 0", result.stdout)

    def test_unreadableCatalogExitsTwo(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Localizable.xcstrings"
            path.write_text("this is not json", encoding="utf-8")
            result = subprocess.run(
                [sys.executable, str(SCRIPT), "--plurals-only", "--catalog", str(path)],
                cwd=ROOT,
                capture_output=True,
                text=True,
            )
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
