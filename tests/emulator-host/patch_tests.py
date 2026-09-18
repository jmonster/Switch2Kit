import contextlib
import difflib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

root = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("integration_apply", root / "Integrations/Emulators/apply.py")
apply = importlib.util.module_from_spec(spec)
spec.loader.exec_module(apply)


class PatchTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.here = Path(self.temp.name)
        self.source = self.here / "source"
        self.source.mkdir()
        self.before, self.after = "controller\n", "controller with native input\n"
        (self.source / "input.cpp").write_text(self.before)
        self.git("init", "-q")
        self.git("add", "input.cpp")
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "Fixture")
        revision = self.git("rev-parse", "HEAD")
        digest = lambda text: hashlib.sha256(text.encode()).hexdigest()
        (self.here / "revisions.json").write_text(json.dumps({"dolphin": {
            "repository": "fixture/emulator", "revision": revision,
            "files": {"input.cpp": {"before": digest(self.before), "after": digest(self.after)}}}}))
        (self.here / "dolphin.patch").write_text("".join(difflib.unified_diff(
            self.before.splitlines(True), self.after.splitlines(True),
            fromfile="a/input.cpp", tofile="b/input.cpp")))

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.source), *args], text=True).strip()

    def invoke(self, *args):
        with patch.object(apply, "HERE", self.here), patch.object(sys, "argv", [
            "apply.py", "dolphin", str(self.source), *args]), contextlib.redirect_stdout(io.StringIO()):
            apply.main()

    def test_check_apply_and_verify(self):
        self.invoke("--check")
        self.assertEqual((self.source / "input.cpp").read_text(), self.before)
        self.assertEqual(self.git("status", "--porcelain"), "")
        self.invoke()
        self.assertEqual((self.source / "input.cpp").read_text(), self.after)
        self.invoke("--verify")

    def test_modified_file_is_preserved(self):
        (self.source / "input.cpp").write_text("user changes\n")
        with self.assertRaisesRegex(ValueError, "contains changes"):
            self.invoke()
        self.assertEqual((self.source / "input.cpp").read_text(), "user changes\n")

    def test_untracked_file_is_preserved(self):
        (self.source / "notes").write_text("user notes\n")
        with self.assertRaisesRegex(ValueError, "untracked"):
            self.invoke()
        self.assertEqual((self.source / "notes").read_text(), "user notes\n")
        self.assertEqual((self.source / "input.cpp").read_text(), self.before)

    def test_wrong_revision_is_rejected(self):
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-qm", "Other")
        with self.assertRaisesRegex(ValueError, "Expected fixture/emulator"):
            self.invoke()
        self.assertEqual((self.source / "input.cpp").read_text(), self.before)

    def test_wrong_patch_is_atomic(self):
        (self.here / "dolphin.patch").write_text("not a patch\n")
        with self.assertRaises(subprocess.CalledProcessError):
            self.invoke()
        self.assertEqual((self.source / "input.cpp").read_text(), self.before)
        self.assertEqual(self.git("status", "--porcelain"), "")

    def test_verify_rejects_modified_integration_without_repairing_it(self):
        self.invoke()
        (self.source / "input.cpp").write_text("local change after applying\n")
        with self.assertRaisesRegex(ValueError, "Unexpected after content"):
            self.invoke("--verify")
        self.assertEqual((self.source / "input.cpp").read_text(), "local change after applying\n")

    def sdl_lookup(self, native, sdl=True):
        # Execute the actual SDL-selection block delivered by the Cemu patch.
        # Only package discovery is replaced; CMake evaluates the conditions.
        text = (root / "Integrations/Emulators/cemu.patch").read_text()
        first_file = text.split("diff --git a/src/CMakeLists.txt", 1)[0]
        lines = [line[1:] for line in first_file.splitlines()
                 if line.startswith(("+", " ")) and not line.startswith("+++")]
        start = lines.index("if(ENABLE_SDL)")
        block, depth = [], 0
        for line in lines[start:]:
            block.append(line)
            if line.strip().startswith("if("):
                depth += 1
            elif line.strip() == "endif()":
                depth -= 1
                if depth == 0:
                    break
        self.assertEqual(depth, 0)
        source = self.here / ("policy-" + str(native) + "-" + str(sdl))
        source.mkdir()
        (source / "CMakeLists.txt").write_text(
            'cmake_minimum_required(VERSION 3.24)\n'
            'project(SDLSelection LANGUAGES NONE)\n'
            'macro(find_package)\n'
            '  file(WRITE "${CMAKE_BINARY_DIR}/lookup.txt" "${ARGV}")\n'
            'endmacro()\n' + "\n".join(block) + "\n")
        build = source / "build"
        subprocess.run(["cmake", "-S", str(source), "-B", str(build),
                        "-DENABLE_SWITCH2KIT=" + ("ON" if native else "OFF"),
                        "-DENABLE_SDL=" + ("ON" if sdl else "OFF")],
                       check=True, capture_output=True, text=True, timeout=20)
        result = build / "lookup.txt"
        return result.read_text().split(";") if result.exists() else None

    def test_cemu_disabled_backend_preserves_system_sdl_discovery(self):
        self.assertEqual(self.sdl_lookup(False),
                         ["SDL3", "REQUIRED", "CONFIG", "COMPONENTS", "SDL3"])
        enabled = self.sdl_lookup(True)
        self.assertEqual(enabled[0], "SDL3")
        self.assertRegex(enabled[1], r"^3\.[0-9]+\.[0-9]+$")
        self.assertEqual(enabled[2:], ["REQUIRED", "CONFIG", "COMPONENTS", "SDL3"])

    def test_cemu_without_sdl_does_not_discover_it(self):
        self.assertIsNone(self.sdl_lookup(False, sdl=False))

    def test_pins_and_patch_paths_match(self):
        directory = root / "Integrations/Emulators"
        revisions = json.loads((directory / "revisions.json").read_text())
        for emulator, data in revisions.items():
            self.assertEqual(len(data["revision"]), 40)
            paths = {line[6:] for line in (directory / f"{emulator}.patch").read_text().splitlines() if line.startswith("+++ b/")}
            self.assertEqual(paths, set(data["files"]))
            for digests in data["files"].values():
                self.assertEqual(set(digests), {"before", "after"})
                self.assertTrue(all(len(value) == 64 for value in digests.values()))


if __name__ == "__main__":
    unittest.main()
