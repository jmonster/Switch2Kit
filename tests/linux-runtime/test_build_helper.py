"""Exercise the real build helper with small, installable native host projects."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class BuildHelperTests(unittest.TestCase):
    def check_host(self, emulator, platform):
        with tempfile.TemporaryDirectory(prefix="s2k build helper ") as temporary:
            root = Path(temporary)
            sdk = root / "sdk"
            (sdk / "scripts").mkdir(parents=True)
            (sdk / "Integrations/Emulators").mkdir(parents=True)
            shutil.copyfile(ROOT / "scripts/build-switch2kit-emulator.sh",
                            sdk / "scripts/build-switch2kit-emulator.sh")
            # Only upstream patch verification and macOS notice inspection are
            # isolated here; CMake configures, builds and installs real binaries.
            (sdk / "Integrations/Emulators/apply.py").write_text(
                "import sys\nassert sys.argv[-1] == '--verify'\n")
            (sdk / "scripts/verify-distribution-notices.py").write_text(
                "from pathlib import Path\nimport sys\n"
                "(Path(sys.argv[3]) / 'notices-checked').touch()\n")
            tools = root / "tools"
            tools.mkdir()
            for name, output in (("uname", platform), ("xcodebuild", "Test Xcode")):
                tool = tools / name
                tool.write_text(f"#!/bin/sh\nprintf '%s\\n' '{output}'\n")
                tool.chmod(0o755)
            source = root / "source"
            source.mkdir()
            target = "dolphin-emu" if emulator == "dolphin" else "CemuBin"
            (source / "main.c").write_text("int main(void) { return 0; }\n")
            (source / "CMakeLists.txt").write_text(
                "cmake_minimum_required(VERSION 3.24)\nproject(Host C)\n"
                f"add_executable({target} main.c)\n"
                "add_executable(auxiliary main.c)\n"
                f"install(TARGETS {target} auxiliary RUNTIME DESTINATION bin)\n")
            build = root / "build"
            env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ["PATH"],
                       S2K_BUILD_JOBS="2")
            result = subprocess.run(
                ["bash", str(sdk / "scripts/build-switch2kit-emulator.sh"),
                 emulator, str(source), str(build)], env=env, text=True,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout)
            self.assertTrue((build / target).is_file())
            if platform == "Linux":
                result = subprocess.run(
                    ["cmake", "--install", str(build), "--prefix", str(root / "install")],
                    text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertTrue((root / "install/bin/auxiliary").is_file())
                self.assertFalse((build / "notices-checked").exists())
            else:
                self.assertFalse((build / "auxiliary").exists())
                self.assertTrue((build / "notices-checked").is_file())

    def test_linux_builds_every_enabled_install_target(self):
        for emulator in ("dolphin", "cemu"):
            with self.subTest(emulator=emulator):
                self.check_host(emulator, "Linux")

    def test_apple_retains_targeted_bundle_build(self):
        for emulator in ("dolphin", "cemu"):
            with self.subTest(emulator=emulator):
                self.check_host(emulator, "Darwin")


if __name__ == "__main__":
    unittest.main()
