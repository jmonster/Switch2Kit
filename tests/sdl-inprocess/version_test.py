"""Failure tests for the compiled diagnostic, with only SDL's version queries faked."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class VersionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="SDL version ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "SDL3").mkdir()
        (self.root / "SDL3/SDL_version.h").write_text(
            "#define SDL_VERSION 3004016\n"
            "int SDL_GetVersion(void);\nconst char *SDL_GetRevision(void);\n")
        (self.root / "version.c").write_text(
            '#include <stdlib.h>\n'
            'int SDL_GetVersion(void) { return atoi(getenv("RUNTIME_VERSION")); }\n'
            'const char *SDL_GetRevision(void) { return "test-boundary"; }\n')
        self.binary = self.root / "check"
        subprocess.run([os.environ.get("CC", "cc"), "-std=c11", "-Wall", "-Wextra", "-Werror",
                        "-I", str(self.root), str(ROOT / "Integrations/SDL3/VerifyVersion.c"),
                        str(self.root / "version.c"), "-o", str(self.binary)], check=True)

    def invoke(self, *args, runtime="3004016"):
        return subprocess.run([str(self.binary), *args],
                              env={**os.environ, "RUNTIME_VERSION": runtime},
                              capture_output=True, text=True, timeout=5)

    def test_matching_header_and_runtime(self):
        for args in ((), ("3004016",)):
            with self.subTest(args=args):
                result = self.invoke(*args)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("headers=3004016 runtime=3004016", result.stdout)

    def test_old_library_under_new_headers_is_rejected(self):
        self.assertEqual(self.invoke("3004016", runtime="3004014").returncode, 1)

    def test_matching_but_unexpected_version_is_rejected(self):
        self.assertEqual(self.invoke("3004014").returncode, 1)

    def test_bad_expected_versions_are_rejected(self):
        for value in ("", "0", "-1", "3.4.16", "3004016junk", "999999999999999999999999"):
            with self.subTest(value=value):
                self.assertEqual(self.invoke(value).returncode, 2)
        self.assertEqual(self.invoke("3004016", "extra").returncode, 2)


if __name__ == "__main__":
    unittest.main()
