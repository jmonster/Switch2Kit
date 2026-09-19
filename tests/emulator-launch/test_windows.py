"""Execute the real PowerShell supervisor's preparation and failure paths.

The tiny native executable is deliberately not a GUI or controller substitute:
qualification must fail, but only after the process verifies its private launch
environment. Maintained-fork CI separately qualifies the actual applications.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile

SUPERVISOR = Path(__file__).with_name("windows.ps1")
NOTICES = ("CREDITS.md", "LICENSES/MIT-trevlars.txt", "LICENSES/SDL-zlib.txt",
           "SwiftRuntime/LICENSE.txt", "SwiftRuntime/ICU.txt")
FIXTURE = r'''
#include <windows.h>
#include <filesystem>
#include <string>
std::wstring env(const wchar_t* key) {
    wchar_t buffer[32768];
    DWORD size = GetEnvironmentVariableW(key, buffer, 32768);
    return size && size < 32768 ? std::wstring(buffer, size) : L"";
}
int wmain(int argc, wchar_t** argv) {
    const auto home = env(L"USERPROFILE");
    const auto root = std::filesystem::path(home).parent_path();
    if (home.empty() || home.find(L"s2k extracted GUI ") == std::wstring::npos)
        return 41;
    if (std::filesystem::path(env(L"APPDATA")) != std::filesystem::path(home) / L"AppData" / L"Roaming" ||
        std::filesystem::path(env(L"LOCALAPPDATA")) != std::filesystem::path(home) / L"AppData" / L"Local" ||
        std::filesystem::path(env(L"TEMP")) != root / L"tmp" || env(L"TMP") != env(L"TEMP"))
        return 42;
    if (env(L"PATH") != env(L"SystemRoot") + L"\\System32;" + env(L"SystemRoot") ||
        !env(L"SWIFT_RUNTIME_PATH").empty() || !env(L"SDKROOT").empty())
        return 43;
    if (argc == 3) {
        if (std::wstring(argv[1]) != L"--user" ||
            std::filesystem::path(argv[2]) != root / L"user" ||
            !std::filesystem::is_regular_file(std::filesystem::path(argv[2]) / L"Config" / L"Dolphin.ini"))
            return 44;
    } else if (argc != 1 || !std::filesystem::is_regular_file(L"settings.xml")) {
        return 45;
    }
    // Prove the process was reached, without allowing a console fixture to pass
    // the GUI, runtime-origin, normal-quit or relaunch requirements.
    return 23;
}
'''


@unittest.skipUnless(sys.platform == "win32", "Executes native Windows processes and PowerShell")
class WindowsPreparation(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="s2k supervisor tests ")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.root = Path(cls.temporary.name)
        cls.pwsh = shutil.which("pwsh")
        if not cls.pwsh:
            raise RuntimeError("PowerShell 7 is required")
        (cls.root / "fixture.cpp").write_text(FIXTURE, encoding="utf-8")
        (cls.root / "CMakeLists.txt").write_text('''cmake_minimum_required(VERSION 3.24)
project(SupervisorFixture CXX)
add_executable(fixture fixture.cpp)
target_compile_features(fixture PRIVATE cxx_std_17)
set_property(TARGET fixture PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreaded")
''', encoding="utf-8")
        for command in (["cmake", "-S", str(cls.root), "-B", str(cls.root / "build"),
                         "-G", "Ninja", "-DCMAKE_BUILD_TYPE=Release"],
                        ["cmake", "--build", str(cls.root / "build")]):
            result = subprocess.run(command, capture_output=True, text=True, timeout=120)
            if result.returncode:
                raise RuntimeError(result.stdout + result.stderr)
        cls.executable = cls.root / "build/fixture.exe"

    def run_supervisor(self, emulator, missing_notice=None, existing_settings=False):
        with tempfile.TemporaryDirectory(dir=self.root) as temporary:
            directory = Path(temporary)
            archive, report = directory / "application with spaces.zip", directory / "report.json"
            name = "Dolphin.exe" if emulator == "dolphin" else "Cemu_release.exe"
            with zipfile.ZipFile(archive, "w") as package:
                package.write(self.executable, "application/" + name)
                package.writestr("application/Switch2KitC.dll", b"not loaded by the failing console fixture")
                for notice in NOTICES:
                    if notice != missing_notice:
                        package.writestr("application/Switch2KitNotices/" + notice, b"test fixture notice\n")
                package.writestr("application/Sys/Profiles/GCPad/Switch2Kit GameCube.ini", b"fixture\n")
                package.writestr("application/resources/fixture.txt", b"fixture\n")
                if existing_settings:
                    package.writestr("application/settings.xml", b"do not overwrite\n")
            before = hashlib.sha256(archive.read_bytes()).hexdigest()
            environment = dict(os.environ, SWIFT_RUNTIME_PATH="must not reach the application", SDKROOT="must not leak")
            result = subprocess.run([self.pwsh, "-NoProfile", "-NonInteractive", "-File", str(SUPERVISOR),
                                     "-Emulator", emulator, "-Archive", str(archive), "-Report", str(report)],
                                    env=environment, text=True, capture_output=True, timeout=30)
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(report.is_file(), result.stdout + result.stderr)
            record = json.loads(report.read_text(encoding="utf-8-sig"))
            self.assertEqual(record["status"], "failed")
            self.assertEqual(record["runs"], [])
            self.assertFalse(record["physicalControllerTested"])
            self.assertFalse(record["pristineFirstRunTested"])
            self.assertEqual(record["archiveSHA256"].lower(), before)
            self.assertEqual(hashlib.sha256(archive.read_bytes()).hexdigest(), before)
            return record

    def test_both_profiles_reach_native_process_with_private_environment(self):
        for emulator in ("dolphin", "cemu"):
            with self.subTest(emulator=emulator):
                record = self.run_supervisor(emulator)
                self.assertEqual(record["stage"], "launch")
                self.assertEqual(record["startupExitCode"], 23)

    def test_missing_distributed_notice_is_rejected_before_launch(self):
        for emulator in ("dolphin", "cemu"):
            with self.subTest(emulator=emulator):
                record = self.run_supervisor(emulator, missing_notice=NOTICES[0])
                self.assertEqual(record["stage"], "preparation")
                self.assertNotIn("startupExitCode", record)

    def test_cemu_archive_with_user_settings_is_not_overwritten(self):
        record = self.run_supervisor("cemu", existing_settings=True)
        self.assertEqual(record["stage"], "preparation")
        self.assertNotIn("startupExitCode", record)


if __name__ == "__main__":
    unittest.main(verbosity=2)
