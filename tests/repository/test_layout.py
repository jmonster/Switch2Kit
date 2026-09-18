"""Repository integrity, documentation links, and executable identity."""
from pathlib import Path
import plistlib
import re
import subprocess
import unittest
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parents[2]

class RepositoryTests(unittest.TestCase):
    def test_application_identity(self):
        info = plistlib.loads((ROOT / "Resources/Info.plist").read_bytes())
        self.assertEqual(info["CFBundleExecutable"], "Switch2KitApp")
        self.assertEqual(info["CFBundleIdentifier"], "wabisabi.ware.gamecubed")

    def test_documentation_links(self):
        roots = [ROOT / "docs", ROOT / "Examples", ROOT / "sdl", ROOT / "browser", ROOT / "LICENSES"]
        files = [ROOT / "README.md", ROOT / "CREDITS.md"]
        for root in roots:
            files.extend(root.rglob("*.md"))
        for file in files:
            for match in re.finditer(r"(?<!!)\[[^\]\n]+\]\(([^)\s]+)\)", file.read_text()):
                link = match.group(1).split("#", 1)[0]
                if not link or ":" in link:
                    continue
                with self.subTest(file=str(file.relative_to(ROOT)), link=link):
                    self.assertTrue((file.parent / unquote(link)).exists(), f"Missing link: {link}")

    def test_documented_rail_bits_match_public_api(self):
        source = (ROOT / "Sources/Switch2Kit/Public/ControllerTypes.swift").read_text()
        bits = {name: int(value.replace("_", ""), 16) for name, value in re.findall(
            r"public static let (s[rl][LR]) = Self\(rawValue: (0x[0-9a-fA-F_]+)\)", source)}
        notes = (ROOT / "docs/protocol.md").read_text()
        documented = {label: int(value, 16) for value, label in re.findall(
            r"(0x[0-9a-fA-F]{8})\s+(S[LR] \([LR]\))", notes)}
        self.assertEqual(documented, {"SL (L)": bits["slL"], "SR (L)": bits["srL"],
                                      "SL (R)": bits["slR"], "SR (R)": bits["srR"]})

    def test_readme_navigation(self):
        readme = (ROOT / "README.md").read_text()
        # Protect the landing-page route to usable apps, not an arbitrary line
        # count that makes documentation-only PRs fail native build jobs.
        introduction = readme.split("```", 1)[0]
        for repository in ("dolphin", "Cemu"):
            with self.subTest(repository=repository):
                self.assertIn(f"https://github.com/jmonster/{repository}", introduction)
        headings = set()
        for heading in re.findall(r"^#{1,6} (.+)$", readme, re.MULTILINE):
            slug = re.sub(r"[^\w -]", "", heading.lower()).replace(" ", "-")
            suffix = 0
            unique = slug
            while unique in headings:
                suffix += 1
                unique = f"{slug}-{suffix}"
            headings.add(unique)
        for fragment in re.findall(r"\]\(#([^)]+)\)", readme):
            with self.subTest(fragment=fragment):
                self.assertIn(unquote(fragment), headings, f"Missing README heading: {fragment}")

    def test_source_only_tree(self):
        tracked = subprocess.check_output(["git", "ls-files", "-z"], cwd=ROOT).decode().split("\0")
        for path in filter(None, tracked):
            self.assertFalse(path.endswith((".dylib", ".xcframework.zip")), path)

if __name__ == "__main__":
    unittest.main()
