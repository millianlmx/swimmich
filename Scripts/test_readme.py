"""Tests of the READMEs and of the screenshot chain: sections, links, citations, sample photos, stub, script."""
import hashlib
import http.server
import json
import os
import re
import shlex
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

from test_release_checks import headings, job_blocks, read

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "UITests" / "stubs"))

import immich_stub_readme_screenshots as shots  # noqa: E402
from immich_stub_base import Request  # noqa: E402

# The showcase (what the app does, for everyone) and the technical documentation
# (how it is built, tested and released), each in English and French.
READMES = ("README.md", "README.fr.md")
TECHNICAL = ("docs/TECHNICAL.md", "docs/TECHNICAL.fr.md")
DOCS = READMES + TECHNICAL
FEATURES_TITLE = {"docs/TECHNICAL.md": "Features", "docs/TECHNICAL.fr.md": "Fonctionnalités"}
SHOWCASE_SCENARIO = "UITests/Scenarios/ShowcaseScreenshotsUITests.swift"
SCREENSHOTS = ["timeline", "viewer", "albums", "search", "backup"]
FIXTURES = ROOT / "UITests" / "stubs" / "fixtures" / "readme"
PATH_EXTENSIONS = (".swift", ".sh", ".py", ".yml", ".md", ".json", ".plist", ".xcstrings", ".xcodeproj",
                   ".txt", ".png", ".entitlements")
# Names a README cites in backticks that no Swift file of the repository declares.
EXTERNAL_NAMES = {"ASWebAuthenticationSession", "NavigationStack", "NSAllowsArbitraryLoads", "SessionCreate"}
# Hosts a README may link to: public documentation (Immich, XcodeGen, simslim), never an Immich server.
DOC_HOSTS = {"github.com"}


def prose(text):
    """The README without its fenced code blocks."""
    out, fenced = [], False
    for line in text.splitlines():
        if line.startswith("```"):
            fenced = not fenced
        elif not fenced:
            out.append(line)
    return "\n".join(out)


def fences(text):
    """The command lines of the ```bash blocks (comments and blanks dropped)."""
    out, language = [], None
    for line in text.splitlines():
        if line.startswith("```"):
            language = None if language is not None else line[3:].strip() or "text"
        elif language == "bash" and line.strip() and not line.lstrip().startswith("#"):
            out.append(line.strip())
    return out


def section(name, title):
    text = read(name)
    start = next(h for h in headings(text) if h[1] == title and h[0] == 2)
    end = next((h[2] for h in headings(text) if h[2] > start[2] and h[0] == 2), len(text))
    return text[start[2]:end]


def tracked_files():
    listed = subprocess.run(["git", "ls-files", "--cached", "--others", "--exclude-standard"],
                            cwd=ROOT, capture_output=True, text=True)
    if listed.returncode == 0 and listed.stdout:
        return listed.stdout.splitlines()
    return [str(p.relative_to(ROOT)) for p in ROOT.rglob("*")
            if p.is_file() and not {".git", "build"} & set(p.relative_to(ROOT).parts)]


def swift_declarations():
    names = set()
    for rel in tracked_files():
        if rel.endswith(".swift"):
            text = (ROOT / rel).read_text(encoding="utf-8", errors="replace")
            names.update(re.findall(r"\b(?:class|struct|enum|protocol|actor|typealias)\s+([A-Za-z_]\w*)", text))
    return names


def citation(item, roots):
    """What a backticked item claims: ("path", p), ("type", T) or None (a value, a command, an API route)."""
    if not item.strip() or re.search(r"[<>*{}$~|]|://", item) or item.startswith("/"):
        return None
    if item.startswith(".") and not item.startswith((".github/", ".omp/")):
        return None
    first = item.split()[0]
    if first.split("/")[0] in roots and ("/" in first or first in roots):
        return ("path", first)
    if " " not in item and first.endswith(PATH_EXTENSIONS):
        return ("path", first)
    head = re.match(r"^([A-Z][A-Za-z0-9]*)(?:[.(<\s]|$)", item)
    if head and len(re.findall("[A-Z]", head.group(1))) >= 2 and re.search("[a-z]", head.group(1)):
        return ("type", head.group(1))
    return None


def png_size(path):
    data = path.read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", f"{path.name} is not a PNG"
    return struct.unpack(">II", data[16:24])


class TestReadmeContent(unittest.TestCase):
    def test_AC_1_features_table_lists_every_feature_folder(self):
        folders = sorted(p.name for p in (ROOT / "Sources" / "Features").iterdir() if p.is_dir())
        for name in TECHNICAL:
            rows = "\n".join(l for l in section(name, FEATURES_TITLE[name]).splitlines() if l.startswith("|"))
            for folder in folders:
                with self.subTest(name=name, folder=folder):
                    self.assertIn(f"`Sources/Features/{folder}/`", rows)
            for cited in re.findall(r"`(Sources/[^`<>*]+)`", rows):
                with self.subTest(name=name, cited=cited):
                    self.assertTrue((ROOT / cited).exists())

    def test_AC_2_title_and_intro_name_swimmich_and_link_immich(self):
        for name in READMES:
            text = read(name)
            intro = text.split("---")[0]
            with self.subTest(name=name):
                self.assertEqual(text.splitlines()[0], "# Swimmich")
                self.assertIn("[Immich](https://github.com/immich-app/immich)", intro)
                self.assertIn("**Swimmich**", intro)

    def test_AC_3_every_relative_link_exists(self):
        for name in DOCS:
            text = read(name)
            slugs = {re.sub(r"[^\w\- ]", "", h[1].lower()).replace(" ", "-") for h in headings(text)}
            targets = re.findall(r"\]\(([^)\s]+)\)", prose(text)) + re.findall(r'(?:src|href)="([^"]+)"', prose(text))
            for target in targets:
                if target.startswith(("http://", "https://", "mailto:")):
                    continue
                path, _, anchor = target.partition("#")
                with self.subTest(name=name, target=target):
                    if path:
                        # Relative to the document, as GitHub resolves it.
                        self.assertTrue(((ROOT / name).parent / path).exists(), f"{path} is missing")
                    else:
                        self.assertIn(anchor, slugs)

    def test_AC_4_no_dated_test_count_and_no_french_in_the_english_readme(self):
        for name in DOCS:
            with self.subTest(name=name):
                body = prose(read(name))
                self.assertIsNone(re.search(r"\b\d[\d ,.]* (unit )?tests\b", body), "a frozen test count")
                self.assertIsNone(re.search(r"\b20\d\d-\d\d-\d\d\b", body), "a dated figure")
        for name in ("README.md", "docs/TECHNICAL.md"):
            english = prose(read(name))
            with self.subTest(name=name):
                self.assertIsNone(re.search(r"[àâçéèêëîïôûùüÿœ]", english))
                self.assertIsNone(re.search(r"\b(les|des|une|pour|avec|dans|sont|est|nous|vous)\b", english, re.I))

    def test_AC_5_readmes_have_the_same_sections_and_images(self):
        images = lambda t: re.findall(r"!\[[^\]]+\]\(([^)]+)\)", t) + re.findall(r'<img src="([^"]+)"', t)
        for english, french in ((READMES[0], READMES[1]), (TECHNICAL[0], TECHNICAL[1])):
            en, fr = read(english), read(french)
            with self.subTest(document=english):
                self.assertEqual([h[0] for h in headings(en)], [h[0] for h in headings(fr)])
                self.assertEqual(images(en), images(fr))
                self.assertEqual(len(re.findall(r"^- \[", en, re.M)), len(re.findall(r"^- \[", fr, re.M)))
                self.assertEqual(len(re.findall(r"^```", en, re.M)), len(re.findall(r"^```", fr, re.M)))
        for name in DOCS:
            self.assertTrue(read(name).count("```") % 2 == 0, f"{name}: an unclosed code fence")

    def test_AC_20_backticked_paths_and_types_exist(self):
        files = tracked_files()
        roots = {f.split("/")[0] for f in files}
        components = {part for f in files for part in f.split("/")}
        declared = swift_declarations() | EXTERNAL_NAMES | components
        declared |= set(re.findall(r"^  (\w+):\s*$", read("project.yml"), re.M))
        for name in DOCS:
            for item in sorted(set(re.findall(r"`([^`\n]+)`", prose(read(name))))):
                found = citation(item, roots)
                if found is None:
                    continue
                kind, value = found
                with self.subTest(name=name, item=item):
                    if kind == "path":
                        wanted = value.rstrip("/")
                        self.assertTrue((ROOT / wanted).exists() or any(f.endswith("/" + wanted) for f in files),
                                        f"{wanted} is not in the repository")
                    else:
                        self.assertIn(value, declared, f"{value} is not declared in the code")

    def test_AC_21_documented_commands_point_at_existing_scripts_and_targets(self):
        project = read("project.yml")
        for name in DOCS:
            for line in fences(read(name)):
                for command in line.split("&&"):
                    tokens = shlex.split(command.strip(), comments=True)
                    if not tokens:
                        continue
                    with self.subTest(name=name, command=command.strip()):
                        head = tokens[0]
                        if head.startswith("Scripts/"):
                            self.assertTrue(os.access(ROOT / head, os.X_OK), f"{head} is not executable")
                        elif head == "python3" and tokens[1] != "-m":
                            self.assertTrue((ROOT / tokens[1]).is_file())
                        elif head == "python3":
                            self.assertEqual(tokens[2], "unittest")
                            self.assertTrue((ROOT / tokens[tokens.index("-s") + 1]).is_dir())
                        elif head == "xcodebuild":
                            for flag, value in zip(tokens, tokens[1:]):
                                if flag == "-project":
                                    self.assertTrue((ROOT / value).exists())
                                if flag == "-scheme":
                                    self.assertRegex(project, rf"(?m)^  {re.escape(value)}:")
                            for only in (t for t in tokens if t.startswith("-only-testing:")):
                                self.assertRegex(project, rf"(?m)^  {re.escape(only.split(':')[1])}:")
                        else:
                            self.assertIn(head, {"xcodegen", "open", "git", "svc.sh", "cd", "npm"})
                            if head == "cd":
                                self.assertTrue(((ROOT / tokens[1]).is_dir()), f"{tokens[1]} is not a folder")
        for script in sorted((ROOT / "Scripts").glob("*.sh")):
            done = subprocess.run(["bash", "-n", str(script)], capture_output=True, text=True)
            self.assertEqual(done.returncode, 0, f"{script.name}: {done.stderr}")

    def test_AC_21_heredoc_in_command_substitution_holds_no_quote_for_bash_3_2(self):
        # `bash -n` above only proves the scripts parse on the bash of the machine running the tests.
        # macOS ships bash 3.2, which scans the body of a `$(cat <<EOF ... EOF)` for quotes and
        # parentheses and reports "unexpected EOF" on an apostrophe in the data.
        for script in sorted((ROOT / "Scripts").glob("*.sh")):
            lines = script.read_text(encoding="utf-8").splitlines()
            for number, line in enumerate(lines):
                opened = re.search(r"\$\(.*<<-?\s*['\"]?(\w+)['\"]?\s*$", line)
                if not opened:
                    continue
                body = []
                for following in lines[number + 1:]:
                    if following.strip() == opened.group(1):
                        break
                    body.append(following)
                with self.subTest(script=script.name, line=number + 1):
                    self.assertIsNone(re.search(r"['\"`()]", "\n".join(body)),
                                      "quote, backtick or parenthesis in a heredoc inside $( ): "
                                      "move the heredoc into a function body")


class TestScreenshots(unittest.TestCase):
    def test_AC_6_readmes_embed_the_five_screenshots_with_alt_text(self):
        for name in TECHNICAL:
            embedded = re.findall(r"!\[([^\]]*)\]\((screenshots/[^)]+)\)", read(name))
            self.assertEqual(sorted(Path(p).stem for _, p in embedded), sorted(SCREENSHOTS), name)
            for alt, _ in embedded:
                self.assertGreater(len(alt.strip()), 10, f"{name}: alternative text too short")

    def test_AC_6_five_screenshots_are_versioned_with_alt_text(self):
        digests = set()
        for shot in SCREENSHOTS:
            path = ROOT / "docs" / "screenshots" / f"{shot}.png"
            with self.subTest(shot=shot):
                self.assertTrue(path.is_file(), f"{path.relative_to(ROOT)} is missing: run Scripts/screenshots.sh")
                width, height = png_size(path)
                self.assertGreater(height, width)
                self.assertGreaterEqual(width, 600)
                self.assertGreater(path.stat().st_size, 50_000, "a nearly empty screen")
                digests.add(hashlib.sha256(path.read_bytes()).hexdigest())
        self.assertEqual(len(digests), len(SCREENSHOTS), "two screenshots are the same picture")

    def test_AC_6_stub_serves_a_loaded_timeline_albums_and_search(self):
        def ask(method, path, query="", body=None):
            return shots.router.handle(Request(method, path, query, {}, body or {})).payload

        months = ask("GET", "/api/timeline/buckets")
        self.assertEqual(sum(m["count"] for m in months), shots.COUNT)
        seen = []
        for month in months:
            payload = ask("GET", "/api/timeline/bucket", f"timeBucket={month['timeBucket']}")
            columns = [v for v in payload.values() if isinstance(v, list)]
            self.assertEqual({len(c) for c in columns}, {month["count"]}, "a parallel array is out of step")
            seen += payload["id"]
        self.assertEqual(len(set(seen)), shots.COUNT)
        slugs = [shots.photo_of(shots.number_of(i))[0] for i in seen]
        self.assertTrue(all(a != b for a, b in zip(slugs, slugs[1:])), "two neighbours show the same photo")
        self.assertEqual(len(set(slugs)), len(shots.PHOTOS))

        jpeg = ask("GET", f"/api/assets/{seen[0]}/thumbnail", "size=thumbnail")
        full = ask("GET", f"/api/assets/{seen[0]}/thumbnail", "size=preview")
        self.assertEqual((jpeg[:3], full[:3]), (b"\xff\xd8\xff", b"\xff\xd8\xff"))
        self.assertLess(len(jpeg), len(full))

        albums = ask("GET", "/api/albums")
        self.assertEqual(len(albums), len(shots.ALBUMS))
        self.assertTrue(all(a["assetCount"] > 0 and a["albumThumbnailAssetId"] for a in albums))
        album = ask("POST", "/api/search/metadata", body={"albumIds": [albums[0]["id"]]})["assets"]
        self.assertEqual(album["count"], albums[0]["assetCount"])

        nature = ask("POST", "/api/search/smart", body={"query": "nature"})["assets"]
        self.assertTrue(0 < nature["count"] < shots.COUNT)
        self.assertEqual(ask("POST", "/api/search/smart", body={"query": "zzz"})["assets"]["count"], 0)

    def test_AC_7_script_scenario_and_readme_agree_on_the_files(self):
        script = read("Scripts/screenshots.sh")
        self.assertEqual(re.search(r"^NAMES=\((.+)\)$", script, re.M).group(1).split(), SCREENSHOTS)
        self.assertIn('OUT="$PWD/docs/screenshots"', script)
        scenario = read("UITests/Scenarios/ReadmeScreenshotsUITests.swift")
        self.assertEqual(re.findall(r'try capture\("(\w+)"\)', scenario), SCREENSHOTS)
        self.assertIn("immich_stub_readme_screenshots.py", script)
        for name in TECHNICAL:
            self.assertIn("Scripts/screenshots.sh", fences(read(name)))

    def test_AC_7_scenario_and_stub_are_in_the_xcode_project(self):
        project = read("ImmichSwiftUI.xcodeproj/project.pbxproj")
        self.assertIn("ReadmeScreenshotsUITests.swift in Sources", project)
        self.assertIn("immich_stub_readme_screenshots.py in Resources", project)

    def test_AC_8_sample_photos_have_provenance_and_a_free_licence(self):
        notice = (FIXTURES / "README.md").read_text(encoding="utf-8")
        rows = [l for l in notice.splitlines() if l.startswith("| `")]
        self.assertTrue((FIXTURES / "LICENSE").is_file())
        photos = sorted(p.name for p in FIXTURES.glob("*.jpg"))
        self.assertEqual(len(photos), 2 * len(shots.PHOTOS))
        for photo in photos:
            row = next((r for r in rows if f"`{photo}`" in r), None)
            with self.subTest(photo=photo):
                self.assertIsNotNone(row, "no provenance row")
                cells = [c.strip() for c in row.strip("|").split("|")]
                self.assertRegex(cells[3], r"CC0|[Pp]ublic domain")
                self.assertTrue(cells[4].startswith("https://commons.wikimedia.org/wiki/File:"))
                self.assertEqual((FIXTURES / photo).read_bytes()[:3], b"\xff\xd8\xff")
        for slug, *_ in shots.PHOTOS:
            self.assertIn(f"{slug}.jpg", photos)
            self.assertIn(f"{slug}-thumb.jpg", photos)

    def test_AC_8_stub_and_readmes_name_no_real_host_or_account(self):
        stub = read("UITests/stubs/immich_stub_readme_screenshots.py")
        self.assertIsNone(re.search(r"https?://(?!127\.0\.0\.1)", stub))
        # The showcase walk takes its server and account from the environment only.
        self.assertIsNone(re.search(r"https?://", read(SHOWCASE_SCENARIO)))
        self.assertIsNone(re.search(r"https?://|@", read("Scripts/showcase.sh").split("set -euo pipefail")[1]))
        for name in DOCS:
            self.assertIsNone(re.search(r"\b(?!127\.0\.0\.1\b)\d{1,3}(\.\d{1,3}){3}\b", prose(read(name))), name)
            for url in re.findall(r"https?://[^\s)>\"'`]+", read(name)):
                host = re.match(r"https?://([^/:?#]+)", url).group(1)
                self.assertTrue(host in DOC_HOSTS or host == "127.0.0.1", f"{name}: {url} is not a documentation link")


class TestShowcase(unittest.TestCase):
    """The showcase READMEs: their pictures come from the walk, the video from Remotion."""

    def test_every_showcase_picture_is_taken_by_the_walk_and_versioned(self):
        scenario = read(SHOWCASE_SCENARIO)
        captured = set(re.findall(r'capture\("([\w-]+)"', scenario)) | set(re.findall(r'"(wrapped-\w+)"', scenario))
        for name in READMES:
            shown = re.findall(r"docs/showcase/([\w-]+)\.png", read(name))
            self.assertGreater(len(shown), 10, name)
            for shot in shown:
                path = ROOT / "docs" / "showcase" / f"{shot}.png"
                with self.subTest(name=name, shot=shot):
                    self.assertIn(shot, captured, "no step of the walk takes it")
                    self.assertTrue(path.is_file(), f"{path.relative_to(ROOT)} is missing: run Scripts/showcase.sh")
                    width, height = png_size(path)
                    self.assertGreater(height, width)

    def test_the_video_and_its_preview_are_versioned_and_linked(self):
        for media in ("docs/media/swimmich.mp4", "docs/media/swimmich-preview.gif"):
            with self.subTest(media=media):
                self.assertTrue((ROOT / media).is_file(), f"{media} is missing: render docs/video")
                self.assertLess((ROOT / media).stat().st_size, 25_000_000, f"{media} is too heavy for a README")
        for name in READMES:
            self.assertIn('href="docs/media/swimmich.mp4"', read(name))
            self.assertIn('src="docs/media/swimmich-preview.gif"', read(name))

    def test_readmes_link_their_technical_documentation(self):
        for name, technical in zip(READMES, TECHNICAL):
            self.assertIn(technical, read(name))


class TestDocumentedCommands(unittest.TestCase):
    @unittest.skipUnless(shutil.which("xcrun") and shutil.which("xcodebuild"), "needs Xcode")
    def test_AC_21_readme_destination_exists_on_this_mac(self):
        # The CI Mac creates its simulators on demand (Scripts/ci.sh), so none is named "iPhone 17" there: what
        # a Mac must offer is the device type and an iOS 26+ runtime. A Mac without an "iPhone 17" device still
        # has to create one (`xcrun simctl create`, as Scripts/screenshots.sh does) before the README's xcodebuild command runs.
        def simctl(*args):
            return json.loads(subprocess.run(["xcrun", "simctl", "list", *args, "-j"],
                                             capture_output=True, text=True, check=True).stdout)

        types = {t["name"] for t in simctl("devicetypes")["devicetypes"]}
        runtimes = [r for r in simctl("runtimes")["runtimes"]
                    if r.get("isAvailable") and r["name"].startswith("iOS ") and int(r["version"].split(".")[0]) >= 26]
        self.assertTrue(runtimes, "no iOS 26+ simulator runtime is installed")
        for name in TECHNICAL:
            destination = re.search(r"-destination 'platform=iOS Simulator,name=([^']+)'", section(name, "Tests"))
            with self.subTest(name=name):
                self.assertIsNotNone(destination, "no simulator destination in the Tests section")
                self.assertIn(destination.group(1), types, "no such simulator device type")


def write_tool(path, body):
    path.write_text("#!/bin/sh\n" + body, encoding="utf-8")
    path.chmod(0o755)


@unittest.skipUnless(shutil.which("python3") and shutil.which("curl") and shutil.which("bash"),
                     "needs python3, curl and bash")
class TestScreenshotsScript(unittest.TestCase):
    """Scripts/screenshots.sh against fake xcrun, xcodegen and xcodebuild, and the real stub."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp()).resolve()
        self.addCleanup(shutil.rmtree, self.tmp, True)
        (self.tmp / "Scripts").mkdir()
        shutil.copy2(ROOT / "Scripts" / "screenshots.sh", self.tmp / "Scripts" / "screenshots.sh")
        (self.tmp / "UITests").symlink_to(ROOT / "UITests")
        self.shots = self.tmp / "docs" / "screenshots"
        self.shots.mkdir(parents=True)
        self.witness = {name: f"committed {name}".encode() for name in SCREENSHOTS}
        for name, data in self.witness.items():
            (self.shots / f"{name}.png").write_bytes(data)
        self.calls = self.tmp / "calls.log"
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        write_tool(bin_dir / "xcodegen", 'echo "xcodegen $*" >> "$FAKE_CALLS"\n')
        write_tool(bin_dir / "xcrun", '''echo "xcrun $*" >> "$FAKE_CALLS"
case "$1 $2 $3" in
  "simctl list runtimes")
    echo '{"runtimes": [{"isAvailable": true, "name": "iOS 26.0", "version": "26.0", "identifier": "fake-ios-26"}]}' ;;
  "simctl create "*) echo FAKE-UDID ;;
esac
exit 0
''')
        write_tool(bin_dir / "xcodebuild", '''echo "xcodebuild $*" >> "$FAKE_CALLS"
case "$*" in
  *build-for-testing*)
    if [ -n "$FAKE_BUILD_FAILS" ]; then echo "Foo.swift:1:1: error: boom"; exit 65; fi ;;
  *test-without-building*)
    echo "url $TEST_RUNNER_IMMICH_STUB_URL" >> "$FAKE_CALLS"
    for name in $FAKE_WRITE; do printf 'new picture of %s' "$name" > "$TEST_RUNNER_SWIMMICH_SCREENSHOT_DIR/$name.png"; done ;;
esac
exit 0
''')

    def run_script(self, write=(), port=None, build_fails=False):
        env = dict(os.environ, PATH=f"{self.tmp / 'bin'}{os.pathsep}{os.environ['PATH']}",
                   FAKE_CALLS=str(self.calls), FAKE_WRITE=" ".join(write),
                   FAKE_BUILD_FAILS="1" if build_fails else "")
        env.pop("SWIMMICH_SCREENSHOT_PORT", None)
        if port:
            env["SWIMMICH_SCREENSHOT_PORT"] = str(port)
        return subprocess.run(["bash", "Scripts/screenshots.sh"], cwd=self.tmp, env=env,
                              capture_output=True, text=True, timeout=60)

    def logged(self):
        return self.calls.read_text(encoding="utf-8").splitlines() if self.calls.exists() else []

    def assert_witnesses_intact(self):
        for name, data in self.witness.items():
            self.assertEqual((self.shots / f"{name}.png").read_bytes(), data, f"{name}.png was touched")

    def test_AC_28_screenshots_script_only_trusts_its_own_stub(self):
        class Impostor(http.server.BaseHTTPRequestHandler):
            def do_GET(handler):
                body = json.dumps({"port": handler.server.server_address[1], "pid": os.getpid(),
                                   "stub": "other_stub.py"}).encode()
                handler.send_response(200)
                handler.send_header("Content-Length", str(len(body)))
                handler.end_headers()
                handler.wfile.write(body)

            def log_message(handler, *args):
                pass

        class Exclusive(http.server.HTTPServer):
            allow_reuse_address = False  # the stub's bind must fail the same way on macOS and Linux

        server = Exclusive(("127.0.0.1", 0), Impostor)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        port = server.server_address[1]

        done = self.run_script(write=SCREENSHOTS, port=port)
        calls = "\n".join(self.logged())
        self.assertNotEqual(done.returncode, 0)
        self.assertIn(str(port), done.stderr)
        self.assertNotIn("simctl boot", calls)
        self.assertNotIn("xcodebuild", calls)
        self.assertIn("simctl delete FAKE-UDID", calls)
        self.assert_witnesses_intact()

    def test_AC_7_screenshots_script_grants_photos_after_install(self):
        done = self.run_script(write=SCREENSHOTS)
        self.assertEqual(done.returncode, 0, done.stderr)
        calls = self.logged()

        def at(prefix):
            return next(i for i, line in enumerate(calls) if line.startswith(prefix))

        added = calls[at("xcrun simctl addmedia FAKE-UDID")].split()[4:]
        expected = sorted(p.name for p in FIXTURES.glob("*.jpg") if not p.name.endswith("-thumb.jpg"))
        self.assertEqual(len(expected), len(shots.PHOTOS))
        self.assertEqual(sorted(Path(a).name for a in added), expected)
        order = [at("xcrun simctl boot FAKE-UDID"), at("xcrun simctl addmedia FAKE-UDID"),
                 at("xcodebuild build-for-testing"), at("xcrun simctl install FAKE-UDID"),
                 at("xcrun simctl privacy FAKE-UDID grant photos fr.millianlmx.immich-ios"),
                 at("xcodebuild test-without-building"), at("xcrun simctl delete FAKE-UDID")]
        self.assertEqual(order, sorted(order))
        self.assertTrue(calls[at("xcrun simctl install FAKE-UDID")].endswith("/ImmichSwiftUI.app"))
        test_run = calls[at("xcodebuild test-without-building")]
        self.assertIn("-only-testing:ImmichSwiftUIUITests/ReadmeScreenshotsUITests", test_run)
        self.assertIn("-resultBundlePath", test_run)
        url = calls[at("url ")].split()[1]
        port = int(url.rsplit(":", 1)[1])
        self.assertNotEqual(port, 8421)
        for name in SCREENSHOTS:
            self.assertNotEqual((self.shots / f"{name}.png").read_bytes(), self.witness[name], f"{name}.png kept")
        deadline = time.time() + 5
        while True:
            with socket.socket() as probe:
                probe.settimeout(1)
                listening = probe.connect_ex(("127.0.0.1", port)) == 0
            if not listening or time.time() > deadline:
                break
            time.sleep(0.1)
        self.assertFalse(listening, "the stub is still listening after the script exited")

    def test_AC_7_screenshots_script_names_the_missing_capture(self):
        done = self.run_script(write=[n for n in SCREENSHOTS if n != "backup"])
        self.assertEqual(done.returncode, 1)
        self.assertIn("docs/screenshots/backup.png was not written", done.stderr)

    def test_AC_29_screenshots_script_names_the_failed_build(self):
        done = self.run_script(write=SCREENSHOTS, build_fails=True)
        calls = "\n".join(self.logged())
        self.assertNotEqual(done.returncode, 0)
        self.assertRegex(done.stderr, r"screenshots\.sh: build error: .*error: boom")
        self.assertIn("screenshots.sh: xcodebuild build-for-testing failed (exit 65)", done.stderr)
        self.assertNotIn("test-without-building", calls)
        self.assertNotIn("simctl privacy", calls)
        self.assert_witnesses_intact()


class TestCaptureJob(unittest.TestCase):
    workflow = read(".github/workflows/ci.yml")

    def test_AC_29_capture_job_writes_only_its_branch(self):
        jobs = job_blocks(self.workflow)
        block = jobs["readme-screenshots"]
        for wanted in ("name: README screenshots", "needs: unit-tests", "!cancelled()", "github.event_name == 'push'",
                       "contents: write", "${{ github.token }}", "run: Scripts/ci-readme-screenshots.sh"):
            self.assertIn(wanted, block)
        self.assertNotIn("secrets.", block)
        self.assertNotIn("environment:", block)
        self.assertEqual(sorted(n for n, b in jobs.items() if "contents: write" in b), ["readme-screenshots", "search-captures"])
        self.assertRegex(self.workflow.split("\njobs:")[0], r"(?m)^permissions:\n  contents: read$")


@unittest.skipUnless(shutil.which("git") and shutil.which("bash"), "needs git and bash")
class TestCaptureJobScript(unittest.TestCase):
    """Scripts/ci-readme-screenshots.sh with a fake screenshots.sh and a local bare repository as the remote."""
    BOT = "github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>"

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp()).resolve()
        self.addCleanup(shutil.rmtree, self.tmp, True)
        (self.tmp / "Scripts").mkdir()
        shutil.copy2(ROOT / "Scripts" / "ci-readme-screenshots.sh", self.tmp / "Scripts" / "ci-readme-screenshots.sh")
        write_tool(self.tmp / "Scripts" / "screenshots.sh", '''echo called >> "$FAKE_CALLS"
case "$FAKE_MODE" in
  write)
    mkdir -p docs/screenshots
    for name in timeline viewer albums search backup; do printf 'png of %s' "$name" > "docs/screenshots/$name.png"; done ;;
  prefixed)
    echo "screenshots.sh: docs/screenshots/backup.png was not written" >&2; exit 1 ;;
  unprefixed)
    echo 'xcrun: error: unable to find utility "simctl"' >&2; exit 72 ;;
esac
''')
        (self.tmp / "bin").mkdir()
        write_tool(self.tmp / "bin" / "xcrun", "exit 1\n")
        (self.tmp / "gitconfig").write_text(
            f'[url "file://{self.tmp}/remote.git"]\n\tinsteadOf = https://x-access-token:t0ken@github.com/owner/repo.git\n'
            "[user]\n\tuseConfigOnly = true\n", encoding="utf-8")  # no user.name: git cannot guess an identity
        self.shots = self.tmp / "docs" / "screenshots"
        self.shots.mkdir(parents=True)
        self.remote = self.tmp / "remote.git"
        self.calls = self.tmp / "calls.log"
        subprocess.run(["git", "init", "--bare", "--quiet", str(self.remote)], check=True, env=self.env("none"))

    def env(self, mode):
        return {"PATH": f"{self.tmp / 'bin'}{os.pathsep}{os.environ['PATH']}", "HOME": str(self.tmp),
                "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": str(self.tmp / "gitconfig"),
                "GITHUB_SHA": "abc123", "GITHUB_REF_NAME": "harness/x", "GITHUB_REPOSITORY": "owner/repo",
                "GITHUB_TOKEN": "t0ken", "FAKE_CALLS": str(self.calls), "FAKE_MODE": mode}

    def run_job(self, mode):
        return subprocess.run(["bash", "Scripts/ci-readme-screenshots.sh"], cwd=self.tmp, env=self.env(mode),
                              capture_output=True, text=True, timeout=60)

    def git(self, *args, binary=False):
        done = subprocess.run(["git", "-C", str(self.remote), *args], capture_output=True, check=True)
        return done.stdout if binary else done.stdout.decode().strip()

    def branches(self):
        return self.git("for-each-ref", "--format=%(refname)").splitlines()

    def commit_four(self):
        for name in SCREENSHOTS[:-1]:
            (self.shots / f"{name}.png").write_bytes(f"committed {name}".encode())

    def test_AC_29_capture_script_does_nothing_when_the_five_are_committed(self):
        for name in SCREENSHOTS:
            (self.shots / f"{name}.png").write_bytes(b"png")
        done = self.run_job("write")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertFalse(self.calls.exists(), "screenshots.sh was called")
        self.assertEqual(self.branches(), [])

    def test_AC_29_capture_script_pushes_to_the_dedicated_branch_and_fails(self):
        for attempt in range(2):  # the second push replaces the first: --force
            self.commit_four()
            (self.shots / "backup.png").unlink(missing_ok=True)
            done = self.run_job("write")
            self.assertEqual(done.returncode, 1, done.stderr)
            self.assertEqual(self.branches(), ["refs/heads/ci/readme-screenshots"])
            tree = self.git("ls-tree", "-r", "--name-only", "ci/readme-screenshots").splitlines()
            self.assertEqual(sorted(tree), sorted(["SOURCE.txt"] + [f"docs/screenshots/{n}.png" for n in SCREENSHOTS]))
            self.assertEqual(self.git("show", "ci/readme-screenshots:SOURCE.txt"), "abc123 harness/x")
            for name in SCREENSHOTS:
                self.assertEqual(self.git("cat-file", "blob", f"ci/readme-screenshots:docs/screenshots/{name}.png",
                                          binary=True), (self.shots / f"{name}.png").read_bytes())
            self.assertEqual(self.git("log", "-1", "--format=%an <%ae>|%cn <%ce>", "ci/readme-screenshots"),
                             f"{self.BOT}|{self.BOT}")
            pushed = self.git("rev-parse", "ci/readme-screenshots")
            annotation = next(l for l in done.stdout.splitlines() if "ci/readme-screenshots" in l)
            self.assertTrue(annotation.startswith("::error title=README screenshots::"))
            self.assertIn("abc123", annotation)
            self.assertIn(pushed, annotation)
            self.assertNotIn("t0ken", done.stdout + done.stderr)

    def test_AC_29_capture_script_reports_the_capture_failure_without_pushing(self):
        self.commit_four()
        done = self.run_job("prefixed")
        self.assertEqual(done.returncode, 1)
        lines = done.stdout.splitlines()
        self.assertIn("::error title=README screenshots::Scripts/screenshots.sh exited 1", lines)
        self.assertIn("::error title=README screenshots::screenshots.sh: docs/screenshots/backup.png was not written", lines)
        self.assertLess(lines.index("::error title=README screenshots::Scripts/screenshots.sh exited 1"),
                        lines.index("::error title=README screenshots::screenshots.sh: docs/screenshots/backup.png was not written"))
        self.assertEqual(self.branches(), [])

    def test_AC_29_capture_script_reports_an_unprefixed_failure(self):
        self.commit_four()
        done = self.run_job("unprefixed")
        self.assertEqual(done.returncode, 1)
        self.assertIn("::error title=README screenshots::Scripts/screenshots.sh exited 72", done.stdout)
        self.assertIn("unable to find utility", done.stdout)
        self.assertEqual(self.branches(), [])


if __name__ == "__main__":
    unittest.main()
