"""Tests of the App Store release chain: release_checks.py, release.sh, the workflow, the READMEs."""
import contextlib
import hashlib
import io
import json
import os
import plistlib
import re
import shutil
import subprocess
import tempfile
import unittest
from datetime import datetime
from pathlib import Path
from unittest import mock

import release_checks as rc

ROOT = Path(__file__).resolve().parent.parent
FAKE_TOOLS = ("security", "openssl", "base64", "codesign", "xcodegen", "xcodebuild", "xcrun")
KEY_MATERIAL = "BEGIN " + "PRIVATE KEY"
README_LANGS = {
    "README.md": {
        "toc_title": "Contributing",
        "subs": ["Prerequisites", "Secrets", "Publishing a release", "After the upload"],
        "ci": "### CI and signed IPA",
        "terms": {
            "Prerequisites": ["fr.millianlmx.immich-ios", "App Store Connect", "`app-store`", "`v*`",
                              "Environment", "not as repository secrets", "tag ruleset", "expire"],
            "Publishing a release": ["git tag v1.2.3 && git push origin v1.2.3", "App Store upload",
                                     "swimmich-ipa"],
            "After the upload": ["TestFlight", "Missing Compliance", "export compliance", "every build",
                                 "review", "manual"],
        },
    },
    "README.fr.md": {
        "toc_title": "Contribuer",
        "subs": ["Préalables", "Secrets", "Publier une release", "Après l'envoi"],
        "ci": "### CI et IPA signé",
        "terms": {
            "Préalables": ["fr.millianlmx.immich-ios", "App Store Connect", "`app-store`", "`v*`",
                           "Environment", "pas en secrets de dépôt", "ruleset de tags", "expir"],
            "Publier une release": ["git tag v1.2.3 && git push origin v1.2.3", "App Store upload",
                                    "swimmich-ipa"],
            "Après l'envoi": ["TestFlight", "Missing Compliance", "conformité export", "chaque build",
                              "review", "manuel"],
        },
    },
}


def read(rel):
    return (ROOT / rel).read_text(encoding="utf-8")


def headings(text):
    """(level, title, start, end) of every ##/### heading outside code fences."""
    found, fenced, pos = [], False, 0
    for line in text.splitlines(keepends=True):
        if line.startswith("```"):
            fenced = not fenced
        match = None if fenced else re.match(r"^(##|###) (.+?)\s*$", line)
        if match:
            found.append([len(match.group(1)), match.group(2), pos, len(text)])
        pos += len(line)
    for here, after in zip(found, found[1:]):
        here[3] = after[2]
    return found


def release_section(name):
    text = read(name)
    start = next(h for h in headings(text) if h[1] == "Release (App Store)")
    end = next((h[2] for h in headings(text) if h[2] > start[2] and h[0] == 2), len(text))
    return text[start[2]:end]


def subsection(name, title):
    text = release_section(name)
    own = headings(text)
    head = next(h for h in own if h[1] == title)
    return text[head[2]:head[3]]


def ci_section(name):
    text = read(name)
    start = text.index(README_LANGS[name]["ci"])
    return text[start:text.index("\n### ", start + 5)]


def job_blocks(text):
    lines = text.splitlines()
    blocks, current = {}, None
    for line in lines[lines.index("jobs:") + 1:]:
        match = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line)
        if match:
            current = match.group(1)
            blocks[current] = []
        elif current:
            blocks[current].append(line)
    return {k: "\n".join(v) for k, v in blocks.items()}


def code_lines(text):
    return "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("#"))


def make_profile(**override):
    cert = b"distribution-certificate-der"
    plist = {
        "UUID": "11111111-2222-3333-4444-555555555555",
        "Name": "Swimmich App Store",
        "TeamIdentifier": [rc.TEAM],
        "ExpirationDate": datetime(2030, 1, 1),
        "DeveloperCertificates": [cert],
        "Entitlements": {
            "application-identifier": f"{rc.TEAM}.fr.millianlmx.immich-ios",
            "keychain-access-groups": [f"{rc.TEAM}.*"],
        },
    }
    plist.update(override)
    return plistlib.dumps(plist), hashlib.sha1(cert).hexdigest().upper()


NOW = datetime(2026, 11, 15)
BUNDLE = "fr.millianlmx.immich-ios"


class ReleaseChecksCase(unittest.TestCase):
    def run_main(self, argv, env=None):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), mock.patch.dict(os.environ, env or {}, clear=env is not None):
            code = rc.main(argv)
        return code, out.getvalue().splitlines()


class TestSecrets(ReleaseChecksCase):
    def test_AC_16_missing_secrets_named_in_order(self):
        env = {n: "x" for n in rc.REQUIRED_SECRETS}
        env["PROFILE_WIDGETS_BASE64"] = "  \n"
        del env["ASC_KEY_P8_BASE64"]
        self.assertEqual(rc.missing_secrets(env), ["PROFILE_WIDGETS_BASE64", "ASC_KEY_P8_BASE64"])
        code, lines = self.run_main(["secrets"], env)
        self.assertEqual(code, 1)
        self.assertTrue(lines[0].startswith("::error title=Missing secret::PROFILE_WIDGETS_BASE64 is not set"))
        self.assertTrue(lines[1].startswith("::error title=Missing secret::ASC_KEY_P8_BASE64 is not set"))
        self.assertEqual(len(rc.REQUIRED_SECRETS), 8)

    def test_AC_16_malformed_key_id_and_issuer(self):
        env = {n: "x" for n in rc.REQUIRED_SECRETS}
        env.update(ASC_KEY_ID="abc", ASC_ISSUER_ID="not-a-uuid")
        self.assertEqual(
            rc.malformed_secrets(env),
            [("ASC_KEY_ID", "must be the 10-character key ID"), ("ASC_ISSUER_ID", "must be the issuer UUID")],
        )
        env.update(ASC_KEY_ID="AB12CD34EF", ASC_ISSUER_ID="69a6de70-03db-47e3-e053-5b8c7c11a4d1")
        self.assertEqual(rc.malformed_secrets(env), [])
        code, lines = self.run_main(["secrets"], env)
        self.assertEqual((code, lines), (0, ["release_checks: the 8 release secrets are set"]))

    def test_AC_9_marketing_version_from_tag(self):
        self.assertEqual(rc.marketing_version("v1.2.3"), "1.2.3")
        self.assertEqual(rc.marketing_version("v2"), "2")
        self.assertEqual(rc.marketing_version("v1.10"), "1.10")
        self.assertEqual(self.run_main(["version", "v1.2.3"]), (0, ["1.2.3"]))

    def test_AC_9_rejected_tags(self):
        for tag in ["1.2.3", "v", "v1.2.3.4", "v1.2-beta", "v01.2", "v1..2", "refs/tags/v1.2.3", ""]:
            with self.subTest(tag=tag):
                with self.assertRaises(rc.ReleaseError):
                    rc.marketing_version(tag)
        code, lines = self.run_main(["version", "v1.2-beta"])
        self.assertEqual(code, 1)
        self.assertTrue(lines[0].startswith("::error title=Release tag::v1.2-beta is not"))


class TestProfiles(ReleaseChecksCase):
    def check(self, bundle=BUNDLE, **override):
        data, sha1 = make_profile(**override)
        return rc.check_profile(data, bundle, sha1, "PROFILE_APP_BASE64", NOW)

    def test_AC_10_valid_profile_gives_its_uuid(self):
        self.assertEqual(self.check(), ("11111111-2222-3333-4444-555555555555", "Swimmich App Store", []))

    def test_AC_10_profile_errors_name_the_secret(self):
        entitlements = {"application-identifier": f"{rc.TEAM}.{BUNDLE}", "keychain-access-groups": [f"{rc.TEAM}.*"]}
        cases = [
            ("is for 2MJF39L8VY.fr.millianlmx.immich-ios, expected 2MJF39L8VY.fr.millianlmx.immich-ios.widgets",
             self.check(bundle=BUNDLE + ".widgets")[2]),
            ("is not an App Store distribution profile", self.check(ProvisionedDevices=["udid"])[2]),
            ("is not an App Store distribution profile",
             self.check(Entitlements={**entitlements, "get-task-allow": True})[2]),
            ("expired on 2020-01-01", self.check(ExpirationDate=datetime(2020, 1, 1))[2]),
            (f"is not for the team {rc.TEAM}", self.check(TeamIdentifier=["OTHERTEAM1"])[2]),
            ("does not include the certificate of APPLE_DISTRIBUTION_P12_BASE64",
             self.check(DeveloperCertificates=[b"another"])[2]),
            ("does not allow the keychain group 2MJF39L8VY.fr.millianlmx.swimmich",
             self.check(Entitlements={**entitlements, "keychain-access-groups": ["2MJF39L8VY.other"]})[2]),
        ]
        for reason, errors in cases:
            with self.subTest(reason=reason):
                self.assertIn(f"PROFILE_APP_BASE64: {reason}", errors)
        self.assertEqual(rc.check_profile(b"junk", BUNDLE, "AA", "PROFILE_APP_BASE64", NOW),
                         ("", "", ["PROFILE_APP_BASE64: is not a provisioning profile"]))
        self.assertGreater(len(self.check(bundle="x", TeamIdentifier=[], ExpirationDate=datetime(2020, 1, 1))[2]), 2)

    def test_AC_10_signing_mismatch_names_the_bundle(self):
        ok = ("AA" * 20, "u1", "u1")
        errors = rc.check_signing("AA" * 20, {
            "app": ok,
            "widgets": ("BB" * 20, "u2", "u2"),
            "share-extension": ("AA" * 20, "other", "u3"),
        })
        self.assertEqual(errors, [
            f"widgets is signed by {'BB' * 20}, expected {'AA' * 20} from APPLE_DISTRIBUTION_P12_BASE64",
            "share-extension embeds profile other, expected u3 from PROFILE_SHARE_EXTENSION_BASE64",
        ])
        self.assertEqual(rc.check_signing("AA" * 20, {"app": ok, "widgets": ok}),
                         ["share-extension was not inspected in the IPA"])

    def test_AC_10_signing_match_prints_the_notice(self):
        sha = "ab" * 20
        code, lines = self.run_main(["signing", sha.upper(), f"app={sha},u1,u1", f"widgets={sha},u2,u2",
                                     f"share-extension={sha},u3,u3"])
        self.assertEqual(code, 0)
        self.assertEqual(lines, [
            f"::notice title=Signing::certificate {sha.upper()} (APPLE_DISTRIBUTION_P12_BASE64) signed app, "
            "widgets, share-extension; profiles app=u1, widgets=u2, share-extension=u3"])
        self.assertEqual(self.run_main(["signing", sha, f"app={sha},u1,u2"])[0], 1)


class TestPayload(unittest.TestCase):
    def payload(self, apps=("ImmichSwiftUI.app",), appexes=rc.EXTENSIONS, framework=True, extra=(), appex_frameworks=()):
        root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, root, True)
        for app in apps:
            for appex in appexes:
                (root / app / "PlugIns" / appex).mkdir(parents=True)
            if framework:
                (root / app / "Frameworks" / rc.FRAMEWORK).mkdir(parents=True)
            for path in extra:
                (root / app / path).mkdir(parents=True)
            for appex in appex_frameworks:
                (root / app / "PlugIns" / appex / "Frameworks").mkdir()
        return root

    def test_AC_17_conforming_payload_passes(self):
        root = self.payload()
        self.assertEqual(rc.check_payload(root), [])
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(rc.main(["payload", str(root)]), 0)
        self.assertEqual(out.getvalue().strip(),
                         "release_checks: payload ok (ImmichSwiftUI.app, 2 extensions, ImmichSharedKit embedded once)")

    def test_AC_17_appex_with_frameworks_fails(self):
        errors = rc.check_payload(self.payload(appex_frameworks=["ImmichWidgets.appex"]))
        self.assertIn("ImmichWidgets.appex embeds a Frameworks/ folder (ITMS-90206)", errors)

    def test_AC_17_missing_appex_fails(self):
        self.assertEqual(rc.check_payload(self.payload(appexes=["ImmichWidgets.appex"])),
                         ["PlugIns holds [ImmichWidgets.appex], expected [ImmichShareExtension.appex, ImmichWidgets.appex]"])
        self.assertEqual(rc.check_payload(self.payload(appexes=[])),
                         ["PlugIns holds [], expected [ImmichShareExtension.appex, ImmichWidgets.appex]"])

    def test_AC_17_framework_twice_fails(self):
        errors = rc.check_payload(self.payload(extra=[f"Other/{rc.FRAMEWORK}"]))
        self.assertEqual(errors, [f"{rc.FRAMEWORK} found 2 times: [Frameworks/{rc.FRAMEWORK}, Other/{rc.FRAMEWORK}]"])
        self.assertEqual(rc.check_payload(self.payload(framework=False)),
                         [f"{rc.FRAMEWORK} found 0 times: []"])

    def test_AC_17_zero_or_two_apps_fail(self):
        self.assertEqual(rc.check_payload(self.payload(apps=())), ["Payload holds 0 .app bundles, expected 1"])
        self.assertEqual(rc.check_payload(self.payload(apps=("A.app", "B.app"))),
                         ["Payload holds 2 .app bundles, expected 1"])

    def test_AC_17_project_embeds_shared_kit_in_app_only(self):
        blocks, current = {}, None
        for line in read("project.yml").splitlines():
            match = re.match(r"^  (Immich\w+):$", line)
            if match:
                current = blocks.setdefault(match.group(1), [])
            elif current is not None:
                current.append(line)
        embeds = {name: re.findall(r"target: ImmichSharedKit\n\s+embed: (\w+)", "\n".join(body))
                  for name, body in blocks.items()}
        self.assertEqual(embeds["ImmichSwiftUI"], ["true"])
        self.assertEqual(embeds["ImmichWidgets"], ["false"])
        self.assertEqual(embeds["ImmichShareExtension"], ["false"])


class TestState(ReleaseChecksCase):
    def test_AC_14_state_dir_outside_repository(self):
        self.assertEqual(rc.state_dir("/runner/tmp", "", "u", ROOT), Path("/runner/tmp/swimmich-release"))
        self.assertEqual(rc.state_dir("", "/var/x", "bob", ROOT), Path("/var/x/swimmich-release-bob"))
        self.assertEqual(rc.state_dir("", "", "bob", ROOT), Path("/tmp/swimmich-release-bob"))
        with self.assertRaises(rc.ReleaseError):
            rc.state_dir(str(ROOT / "build"), "", "u", ROOT)
        with self.assertRaises(rc.ReleaseError):
            rc.state_dir("", str(ROOT), "u", ROOT)
        code, lines = self.run_main(["state-dir"], {"RUNNER_TEMP": str(ROOT / "build"), "USER": "u"})
        self.assertEqual(code, 1)
        self.assertTrue(lines[0].startswith("::error title=Signing state::"))

    def test_AC_14_search_list_keeps_foreign_keychains(self):
        self.assertEqual(rc.parse_search_list('    "/a/login.keychain-db"\n\n  "/b/x.keychain-db"\n'),
                         ["/a/login.keychain-db", "/b/x.keychain-db"])
        job = "/tmp/job/release.keychain-db"
        self.assertEqual(rc.without_keychain(["/s/login", job, "/late/extra"], job), ["/s/login", "/late/extra"])
        self.assertEqual(rc.lost_entries(["/a", "/b"], ["/a", "/c"]), ["/b"])
        with tempfile.TemporaryDirectory() as tmp:
            real = Path(tmp, "real")
            real.mkdir()
            Path(tmp, "link").symlink_to(real)
            self.assertEqual(rc.without_keychain([str(Path(tmp, "link", "k")), "/other"], str(real / "k")), ["/other"])


@unittest.skipUnless(shutil.which("bash") and shutil.which("python3"), "needs bash and python3")
class TestReleaseScript(unittest.TestCase):
    def run_release(self, args, env_extra=None):
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp, True)
        (tmp / "bin").mkdir()
        (tmp / "runner").mkdir()
        (tmp / "home").mkdir()
        for tool in FAKE_TOOLS:
            fake = tmp / "bin" / tool
            fake.write_text('#!/bin/sh\necho "$(basename "$0")" >> "$TOOL_LOG"\nexit 1\n')
            fake.chmod(0o755)
        env = {"PATH": f"{tmp / 'bin'}:{os.environ['PATH']}", "HOME": str(tmp / "home"), "USER": "tester",
               "RUNNER_TEMP": str(tmp / "runner"), "TOOL_LOG": str(tmp / "tools.log")}
        env.update(env_extra or {})
        done = subprocess.run(["bash", str(ROOT / "Scripts/release.sh"), *args], env=env, cwd=ROOT,
                              capture_output=True, text=True, timeout=60)
        log = (tmp / "tools.log").read_text().split() if (tmp / "tools.log").exists() else []
        return done, log, tmp

    def secrets(self, **override):
        env = {name: f"value-of-{name.lower()}" for name in rc.REQUIRED_SECRETS}
        env.update(ASC_KEY_ID="AB12CD34EF", ASC_ISSUER_ID="69a6de70-03db-47e3-e053-5b8c7c11a4d1")
        env.update(override)
        return {k: v for k, v in env.items() if v is not None}

    def test_AC_16_release_stops_before_any_signing_tool(self):
        env = self.secrets(PROFILE_APP_BASE64=None, ASC_KEY_P8_BASE64="  ")
        done, log, tmp = self.run_release(["v1.2.3"], env)
        self.assertEqual(done.returncode, 1)
        self.assertIn("::error title=Missing secret::PROFILE_APP_BASE64 is not set", done.stdout)
        self.assertIn("::error title=Missing secret::ASC_KEY_P8_BASE64 is not set", done.stdout)
        self.assertEqual(log, [])
        self.assertFalse((tmp / "runner" / "swimmich-release").exists())
        done, log, _ = self.run_release(["1.2.3"], self.secrets())
        self.assertEqual((done.returncode, log), (1, []))
        self.assertIn("::error title=Release tag::", done.stdout)
        self.assertEqual(self.run_release([])[0].returncode, 2)

    def test_AC_14_cleanup_without_state_is_a_no_op(self):
        done, log, _ = self.run_release(["--cleanup"])
        self.assertEqual(done.returncode, 0)
        self.assertEqual(done.stdout.strip(), "release.sh: no signing state to clean")
        self.assertEqual(log, [])

    def test_AC_14_secret_values_never_printed(self):
        env = self.secrets()
        done, log, tmp = self.run_release(["v1.2.3"], env)
        self.assertEqual(done.returncode, 1)
        self.assertIn("security", log)
        output = done.stdout + done.stderr
        for name, value in env.items():
            if name not in ("ASC_KEY_ID", "ASC_ISSUER_ID"):
                self.assertNotIn(value, output, name)
        self.assertFalse((tmp / "runner" / "swimmich-release").exists(), "the state is removed on failure")


class TestWorkflow(unittest.TestCase):
    workflow = read(".github/workflows/ci.yml")
    jobs = job_blocks(workflow)

    def test_AC_22_environment_only_in_upload_job_on_tags(self):
        code = code_lines(self.workflow)
        self.assertEqual(re.findall(r"(?m)^[ \t]*environment:.*$", code), ["    environment: app-store"])
        self.assertIn("environment: app-store", code_lines(self.jobs["appstore"]))
        self.assertIn("if: startsWith(github.ref, 'refs/tags/v')", self.jobs["appstore"])
        self.assertNotIn("pull_request", code)
        self.assertNotIn("Nothing is uploaded", self.workflow)

    def test_AC_11_upload_job_needs_both_suites_without_always(self):
        block = code_lines(self.jobs["appstore"])
        self.assertIn("name: App Store upload", block)
        self.assertIn("needs: [unit-tests, ui-suite]", block)
        self.assertNotIn("always()", re.sub(r"(?s)- name: Remove the signing state.*", "", block))
        self.assertIn("name: Unit tests (iOS simulator)", self.jobs["unit-tests"])

    def test_AC_12_signed_ipa_job_runs_on_main_without_secrets(self):
        block = code_lines(self.jobs["ipa"])
        self.assertIn("github.ref == 'refs/heads/main'", block)
        self.assertNotIn("refs/tags", block)
        self.assertNotIn("secrets.", block)
        self.assertNotIn("environment:", block)
        self.assertRegex(block, r"(?m)run: Scripts/ipa\.sh[ \t]*$")
        self.assertIn("name: swimmich-ipa", block)

    def test_AC_13_secrets_read_only_in_upload_job(self):
        names = re.findall(r"\$\{\{ secrets\.([A-Za-z0-9_]+) \}\}", self.workflow)
        self.assertEqual(sorted(names), sorted(rc.REQUIRED_SECRETS))
        for line in self.workflow.splitlines():
            if "secrets." in line:
                self.assertRegex(line, r"^          (\w+): \$\{\{ secrets\.\1 \}\}$")
        self.assertEqual([j for j, body in self.jobs.items() if "secrets." in body], ["appstore"])

    def test_AC_14_cleanup_step_runs_always(self):
        steps = re.split(r"\n      - ", self.jobs["appstore"])
        self.assertTrue(steps[-1].startswith("name: Remove the signing state"))
        self.assertIn("if: always()", steps[-1])
        self.assertIn("run: Scripts/release.sh --cleanup", steps[-1])


class TestRepository(unittest.TestCase):
    def test_AC_13_no_signing_material_tracked(self):
        listed = subprocess.run(["git", "ls-files"], cwd=ROOT, capture_output=True, text=True)
        if listed.returncode != 0:
            self.skipTest("not a git checkout")
        files = listed.stdout.splitlines()
        self.assertEqual([f for f in files if f.endswith((".p8", ".p12", ".mobileprovision", ".cer"))], [])
        hits = subprocess.run(["git", "grep", "-I", "-l", KEY_MATERIAL], cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(hits.stdout.split(), [])

    def test_AC_2_no_nothing_is_uploaded_claim(self):
        for name in ("README.md", "README.fr.md", ".github/workflows/ci.yml"):
            text = read(name)
            self.assertNotIn("Nothing is uploaded", text, name)
            self.assertNotIn("Rien n'est envoyé", text, name)

    def test_AC_10_release_signing_include_sets_manual_signing_per_target(self):
        out = self.generate({
            "SWIMMICH_RELEASE_SIGNING": "YES", "SWIMMICH_SIGN_IDENTITY": "A" * 40,
            "SWIMMICH_SIGN_KEYCHAIN": "/tmp/fake.keychain-db", "SWIMMICH_PROFILE_SPECIFIER_APP": "App profile",
            "SWIMMICH_PROFILE_SPECIFIER_WIDGETS": "Widgets profile", "SWIMMICH_PROFILE_SPECIFIER_SHARE": "Share profile"})
        cache = os.environ.get("SWIMMICH_CI_CACHE", str(Path.home() / "Library/Caches/swimmich-ci"))

        def settings(target):
            done = subprocess.run(
                ["xcodebuild", "-showBuildSettings", "-json", "-project", str(out / "ImmichSwiftUI.xcodeproj"),
                 "-target", target, "-configuration", "Release", "-sdk", "iphoneos",
                 "-clonedSourcePackagesDirPath", f"{cache}/SourcePackages"],
                cwd=ROOT, capture_output=True, text=True, timeout=600, check=True)
            return json.loads(done.stdout)[0]["buildSettings"]

        for target, profile in (("ImmichSwiftUI", "App profile"), ("ImmichWidgets", "Widgets profile"),
                                ("ImmichShareExtension", "Share profile"), ("ImmichSharedKit", "")):
            with self.subTest(target=target):
                found = settings(target)
                self.assertEqual(found["CODE_SIGN_STYLE"], "Manual")
                self.assertEqual(found["CODE_SIGN_IDENTITY"], "A" * 40)
                self.assertIn("--keychain /tmp/fake.keychain-db", found["OTHER_CODE_SIGN_FLAGS"])
                self.assertEqual(found.get("PROVISIONING_PROFILE_SPECIFIER", ""), profile)
        tests = settings("ImmichSwiftUITests")
        self.assertNotEqual(tests.get("CODE_SIGN_STYLE"), "Manual")
        self.assertEqual(tests.get("PROVISIONING_PROFILE_SPECIFIER", ""), "")

    def test_AC_12_release_signing_include_off_without_variable(self):
        project = (self.generate({}) / "ImmichSwiftUI.xcodeproj" / "project.pbxproj").read_text()
        for forbidden in ("CODE_SIGN_STYLE = Manual", "--keychain", "SWIMMICH_"):
            self.assertNotIn(forbidden, project)

    def generate(self, extra_env):
        if not (shutil.which("xcodegen") and shutil.which("xcodebuild")):
            self.skipTest("needs XcodeGen and Xcode")
        out = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, out, True)
        env = {k: v for k, v in os.environ.items() if not k.startswith("SWIMMICH_RELEASE")}
        env.update(extra_env)
        subprocess.run(["xcodegen", "generate", "--quiet", "--spec", str(ROOT / "project.yml"),
                        "--project", str(out)], cwd=ROOT, env=env, check=True)
        return out


class TestReadmes(unittest.TestCase):
    def test_AC_19_readme_release_section_structure(self):
        for name, lang in README_LANGS.items():
            with self.subTest(name=name):
                text = read(name)
                toc = re.findall(r"^- \[(.+?)\]\((#.+?)\)$", text.split("---")[1], re.M)
                titles = [t for t, _ in toc]
                self.assertEqual(titles[titles.index("Tests") + 1], "Release (App Store)")
                self.assertEqual(titles[titles.index("Release (App Store)") + 1], lang["toc_title"])
                self.assertIn(("Release (App Store)", "#release-app-store"), toc)
                section = release_section(name)
                self.assertEqual([h[1] for h in headings(section) if h[0] == 3], lang["subs"])
                self.assertIn("git push origin v", section)
                order = [m.start() for m in (re.search(rf"^## {re.escape(t)}$", text, re.M)
                                             for t in ("Release (App Store)", lang["toc_title"])) if m]
                self.assertEqual(order, sorted(order))

    def test_AC_19_readme_release_subsections_say_what_to_do(self):
        for name, lang in README_LANGS.items():
            for title, terms in list(lang["terms"].items())[1:]:
                body = subsection(name, title).lower()
                for term in terms:
                    with self.subTest(name=name, title=title, term=term):
                        self.assertIn(term.lower(), body)

    def test_AC_15_readme_secrets_match_workflow(self):
        workflow = set(re.findall(r"secrets\.([A-Z0-9_]+)", read(".github/workflows/ci.yml")))
        self.assertEqual(workflow, set(rc.REQUIRED_SECRETS))
        for name in README_LANGS:
            with self.subTest(name=name):
                rows = [line for line in subsection(name, "Secrets").splitlines()
                        if re.match(r"^\| `[A-Z0-9_]+` ", line)]
                names = []
                for row in rows:
                    cells = [c.strip() for c in row.strip().strip("|").split(" | ")]
                    self.assertEqual(len(cells), 5, row)
                    self.assertTrue(all(cells), row)
                    names.append(cells[0].strip("`"))
                self.assertEqual(names, list(rc.REQUIRED_SECRETS))

    def test_AC_15_readme_secrets_go_to_the_environment(self):
        for name, lang in README_LANGS.items():
            body = subsection(name, lang["subs"][0])
            for term in lang["terms"][lang["subs"][0]]:
                with self.subTest(name=name, term=term):
                    self.assertIn(term.lower(), body.lower())

    def test_AC_3_release_section_links_exist(self):
        for name in README_LANGS:
            text = read(name)
            slugs = {re.sub(r"[^\w\- ]", "", h[1].lower()).replace(" ", "-") for h in headings(text)}
            for part in (release_section(name), ci_section(name)):
                for target in re.findall(r"\]\(([^)]+)\)", part):
                    if target.startswith("http"):
                        continue
                    path, _, anchor = target.partition("#")
                    with self.subTest(name=name, target=target):
                        if path:
                            self.assertTrue((ROOT / path).exists())
                        else:
                            self.assertIn(anchor, slugs)

    def test_AC_4_release_section_english_only(self):
        text = release_section("README.md") + ci_section("README.md")
        self.assertIsNone(re.search(r"préalables|publier|après|envoi|contenu|obtenir|rôle", text, re.I))
        self.assertIsNone(re.search(r"\b\d+ (unit )?tests\b", text))

    def test_AC_5_release_sections_parity(self):
        def outline(name):
            return [(h[0], h[1]) for h in headings(release_section(name))]

        en, fr = outline("README.md"), outline("README.fr.md")
        self.assertEqual([lvl for lvl, _ in en], [lvl for lvl, _ in fr])
        self.assertEqual(en[0], fr[0])
        self.assertEqual(en[2], fr[2])
        secrets = [re.findall(r"^\| `([A-Z0-9_]+)`", release_section(n), re.M) for n in README_LANGS]
        self.assertEqual(secrets[0], secrets[1])

    def test_AC_20_release_section_paths_exist(self):
        for name in README_LANGS:
            for part in (release_section(name), ci_section(name)):
                for item in re.findall(r"`([^`\n]+)`", part):
                    first = item.split()[0]
                    if first.startswith(("Scripts/", ".github/", "project.yml", "README")) or item.endswith(
                            (".sh", ".py", ".yml")):
                        with self.subTest(name=name, item=item):
                            self.assertTrue((ROOT / first).exists())


if __name__ == "__main__":
    unittest.main()
