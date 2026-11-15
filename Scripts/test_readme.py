"""Tests of the READMEs and of the screenshot chain: sections, links, citations, sample photos, stub, script."""
import hashlib
import os
import re
import shlex
import struct
import subprocess
import sys
import unittest
from pathlib import Path

from test_release_checks import headings, read

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "UITests" / "stubs"))

import immich_stub_readme_screenshots as shots  # noqa: E402
from immich_stub_base import Request  # noqa: E402

READMES = ("README.md", "README.fr.md")
FEATURES_TITLE = {"README.md": "Features", "README.fr.md": "Fonctionnalités"}
SCREENSHOTS = ["timeline", "viewer", "albums", "search", "backup"]
FIXTURES = ROOT / "UITests" / "stubs" / "fixtures" / "readme"
PATH_EXTENSIONS = (".swift", ".sh", ".py", ".yml", ".md", ".json", ".plist", ".xcstrings", ".xcodeproj",
                   ".txt", ".png", ".entitlements")
# Names a README cites in backticks that no Swift file of the repository declares.
EXTERNAL_NAMES = {"ASWebAuthenticationSession", "NavigationStack", "NSAllowsArbitraryLoads", "SessionCreate"}


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


def screenshots_captured():
    """False until a human has run Scripts/screenshots.sh on a Mac and committed the pictures."""
    return any((ROOT / "docs" / "screenshots").glob("*.png"))


def png_size(path):
    data = path.read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", f"{path.name} is not a PNG"
    return struct.unpack(">II", data[16:24])


class TestReadmeContent(unittest.TestCase):
    def test_AC_1_features_table_lists_every_feature_folder(self):
        folders = sorted(p.name for p in (ROOT / "Sources" / "Features").iterdir() if p.is_dir())
        for name in READMES:
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
        for name in READMES:
            text = read(name)
            slugs = {re.sub(r"[^\w\- ]", "", h[1].lower()).replace(" ", "-") for h in headings(text)}
            for target in re.findall(r"\]\(([^)\s]+)\)", prose(text)):
                if target.startswith(("http://", "https://", "mailto:")):
                    continue
                path, _, anchor = target.partition("#")
                with self.subTest(name=name, target=target):
                    if path.startswith("docs/screenshots/") and not screenshots_captured():
                        continue  # the pictures only exist once Scripts/screenshots.sh ran on a Mac (test_AC_6)
                    if path:
                        self.assertTrue((ROOT / path).exists(), f"{path} is missing")
                    else:
                        self.assertIn(anchor, slugs)

    def test_AC_4_no_dated_test_count_and_no_french_in_the_english_readme(self):
        for name in READMES:
            with self.subTest(name=name):
                body = prose(read(name))
                self.assertIsNone(re.search(r"\b\d[\d ,.]* (unit )?tests\b", body), "a frozen test count")
                self.assertIsNone(re.search(r"\b20\d\d-\d\d-\d\d\b", body), "a dated figure")
        english = prose(read("README.md"))
        self.assertIsNone(re.search(r"[àâçéèêëîïôûùüÿœ]", english))
        self.assertIsNone(re.search(r"\b(les|des|une|pour|avec|dans|sont|est|nous|vous)\b", english, re.I))

    def test_AC_5_readmes_have_the_same_sections_and_images(self):
        en, fr = read("README.md"), read("README.fr.md")
        self.assertEqual([h[0] for h in headings(en)], [h[0] for h in headings(fr)])
        images = lambda t: re.findall(r"!\[[^\]]+\]\(([^)]+)\)", t)
        self.assertEqual(images(en), images(fr))
        self.assertEqual(len(re.findall(r"^- \[", en, re.M)), len(re.findall(r"^- \[", fr, re.M)))
        for name in READMES:
            self.assertTrue(read(name).count("```") % 2 == 0, f"{name}: an unclosed code fence")
        self.assertEqual(len(re.findall(r"^```", en, re.M)), len(re.findall(r"^```", fr, re.M)))

    def test_AC_20_backticked_paths_and_types_exist(self):
        files = tracked_files()
        roots = {f.split("/")[0] for f in files}
        components = {part for f in files for part in f.split("/")}
        declared = swift_declarations() | EXTERNAL_NAMES | components
        declared |= set(re.findall(r"^  (\w+):\s*$", read("project.yml"), re.M))
        for name in READMES:
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
        for name in READMES:
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
                            self.assertIn(head, {"xcodegen", "open", "git", "svc.sh"})
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
        for name in READMES:
            embedded = re.findall(r"!\[([^\]]*)\]\((docs/screenshots/[^)]+)\)", read(name))
            self.assertEqual(sorted(Path(p).stem for _, p in embedded), sorted(SCREENSHOTS), name)
            for alt, _ in embedded:
                self.assertGreater(len(alt.strip()), 10, f"{name}: alternative text too short")

    def test_AC_6_five_screenshots_are_versioned_with_alt_text(self):
        if not screenshots_captured():
            self.skipTest("docs/screenshots/*.png are not captured yet: run Scripts/screenshots.sh on a Mac and commit them")
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
        for name in READMES:
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
        for name in READMES:
            self.assertIsNone(re.search(r"\b(?!127\.0\.0\.1\b)\d{1,3}(\.\d{1,3}){3}\b", prose(read(name))), name)


if __name__ == "__main__":
    unittest.main()
