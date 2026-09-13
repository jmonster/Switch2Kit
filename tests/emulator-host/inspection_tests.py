"""Exercise bundle validation with fake tool boundaries, not native binaries."""
import contextlib
import io
import json
from pathlib import Path
import plistlib
import runpy
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'Integrations/Emulators/verify-bundle.py'


class InspectionTests(unittest.TestCase):
    def inspect(self, emulator, defect=None, script=SCRIPT):
        calls = []
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, build = root / 'source', root / 'build'
            build.mkdir()
            app = (build / 'Binaries/DolphinQt.app' if emulator == 'dolphin'
                   else source / 'bin/Cemu.app')
            executable = 'DolphinQt' if emulator == 'dolphin' else 'Cemu'
            exe = app / 'Contents/MacOS' / executable
            lib = app / 'Contents/Frameworks/libSwitch2KitC.dylib'
            for path in (exe, lib):
                path.parent.mkdir(parents=True, exist_ok=True)
                path.touch()
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
                'CFBundleExecutable': executable,
                'NSBluetoothAlwaysUsageDescription': 'Controller input',
                'LSMinimumSystemVersion': '15.0',
            }))
            filenames = ('SDL.cpp', 'SDLGamepad.cpp', 'ControllersPane.cpp') if emulator == 'dolphin' else (
                'SDLControllerProvider.cpp', 'SDLController.cpp', 'ControllerFactory.cpp', 'InputAPIAddWindow.cpp')
            (build / 'compile_commands.json').write_text(json.dumps([
                {'file': name, 'command': 'clang++ -DHAVE_SWITCH2KIT=1'} for name in filenames
            ]))

            def output(arguments):
                calls.append(arguments)
                if arguments == ['uname', '-m']:
                    return 'arm64\n'
                if arguments[0] in ('otool', 'nm'):
                    # A PATH-shadowing tool must not be selected for Mach-O inspection.
                    return str(arguments[-1]) + ':\n'
                if arguments[:3] == ['xcrun', 'otool', '-L']:
                    if defect == 'tool-failure':
                        raise subprocess.CalledProcessError(1, arguments)
                    if arguments[-1] == str(exe):
                        return str(exe) + ':\n\t' + (
                            '/usr/lib/libSystem.B.dylib' if defect == 'unlinked' else
                            '@executable_path/../Frameworks/libSwitch2KitC.dylib') + '\n'
                    return str(lib) + ':\n\t' + (
                        '/System/Library/Frameworks/CoreHID.framework/CoreHID' if defect == 'corehid' else
                        '/System/Library/Frameworks/CoreBluetooth.framework/CoreBluetooth') + '\n'
                return ''

            def run(arguments, **kwargs):
                return subprocess.CompletedProcess(arguments, 0, output(arguments))

            with patch.object(sys, 'argv', [str(script), emulator, str(source), str(build)]), \
                    patch('subprocess.run', side_effect=run), \
                    patch('subprocess.check_output', side_effect=lambda arguments, **kw: output(arguments)), \
                    contextlib.redirect_stdout(io.StringIO()):
                if defect:
                    expected = subprocess.CalledProcessError if defect == 'tool-failure' else AssertionError
                    with self.assertRaises(expected):
                        runpy.run_path(str(script), run_name='__main__')
                    self.assertFalse(any(command[0] == 'ditto' for command in calls))
                else:
                    runpy.run_path(str(script), run_name='__main__')
                    self.assertTrue(any(command[0] == 'ditto' for command in calls))
                    self.assertTrue(any(command[:2] == ['xcrun', 'nm'] for command in calls))
                self.assertFalse(any(command[0] in ('otool', 'nm') for command in calls))

    def test_xcode_tools_are_used_for_both_emulators(self):
        for emulator in ('dolphin', 'cemu'):
            with self.subTest(emulator=emulator):
                self.inspect(emulator)

    def test_unlinked_copy_is_rejected(self):
        self.inspect('dolphin', 'unlinked')

    def test_corehid_dependency_is_rejected(self):
        self.inspect('cemu', 'corehid')

    def test_inspection_failure_does_not_package_an_app(self):
        self.inspect('dolphin', 'tool-failure')


if __name__ == '__main__':
    unittest.main()
