"""Repository layout, documentation links, and application identity."""
from pathlib import Path
import json
import plistlib
import re
import subprocess
import unittest
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parents[2]

class RepositoryTests(unittest.TestCase):
    def test_application_identity(self):
        info = plistlib.loads((ROOT / "Resources/Info.plist").read_bytes())
        self.assertEqual(info["CFBundleName"], "Switch2Kit")
        self.assertEqual(info["CFBundleDisplayName"], "Switch2Kit")
        self.assertEqual(info["CFBundleExecutable"], "Switch2KitApp")
        self.assertEqual(info["CFBundleIdentifier"], "wabisabi.ware.gamecubed")
        self.assertTrue((ROOT / "Sources/Switch2KitApp/Switch2KitApp.swift").is_file())
        self.assertIn('name: "Switch2KitApp"', (ROOT / "Package.swift").read_text())
        self.assertIn('APP_NAME="Switch2Kit"', (ROOT / "scripts/build-app.sh").read_text())
        self.assertIn('EXE=Switch2KitApp', (ROOT / "scripts/build-app.sh").read_text())

    def test_browser_identity(self):
        manifest = json.loads((ROOT / "browser/extension/manifest.json").read_text())
        self.assertTrue(manifest["name"].startswith("Switch2Kit"))
        self.assertIn("Switch2Kit", manifest["description"])

    def test_documentation_links(self):
        roots = [ROOT / "docs", ROOT / "Examples", ROOT / "sdl", ROOT / "browser"]
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

    def test_source_only_tree(self):
        tracked = subprocess.check_output(["git", "ls-files", "-z"], cwd=ROOT).decode().split("\0")
        for path in filter(None, tracked):
            self.assertFalse(path.endswith((".dylib", ".xcframework.zip")), path)
        self.assertLess(len((ROOT / "README.md").read_text().splitlines()), 100)

if __name__ == "__main__":
    unittest.main()
