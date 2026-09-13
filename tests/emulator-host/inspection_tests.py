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
    def inspect(self, emulator, defect=None, script=SCRIPT, symlink=False):
        calls = []
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source, build = root / 'source', root / 'build'
            build.mkdir()
            app = (build / 'Binaries/DolphinQt.app' if emulator == 'dolphin'
                   else source / 'bin/Cemu.app')
            executable = 'DolphinQt' if emulator == 'dolphin' else 'Cemu'
            if defect == 'header-only':
                app = app.parent / ('libSwitch2KitC.dylib-' + app.name)
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
                    path = Path(arguments[-1]).resolve()
                    if path == exe:
                        dependency = '@executable_path/../Frameworks/libSwitch2KitC.dylib'
                        if defect in ('unlinked', 'header-only'):
                            dependency = '/usr/lib/libSystem.B.dylib'
                        elif defect == 'wrong-sdk':
                            dependency = '@rpath/libSwitch2KitC.dylib.backup'
                        elif defect == 'absolute-sdk':
                            dependency = '/build/libSwitch2KitC.dylib'
                        return str(exe) + ':\n\t' + dependency + ' (compatibility version 0.0.0, current version 0.0.0)\n'
                    if path != lib:
                        raise AssertionError('Unexpected Mach-O path: ' + str(path))
                    return str(lib) + ':\n\t' + (
                        '/System/Library/Frameworks/CoreHID.framework/CoreHID' if defect == 'corehid' else
                        '/System/Library/Frameworks/CoreBluetooth.framework/CoreBluetooth') + '\n'
                if arguments[:2] == ['xcrun', 'lipo']:
                    self.assertEqual(arguments[2], '-archs')
                    self.assertEqual(len(arguments), 4)
                    path = Path(arguments[3]).resolve()
                    self.assertIn(path, (exe, lib))
                    if ((defect == 'exe-architecture' and path == exe)
                            or (defect == 'lib-architecture' and path == lib)):
                        return 'x86_64\n'
                    return 'arm64 x86_64\n'
                return ''

            def run(arguments, **kwargs):
                return subprocess.CompletedProcess(arguments, 0, output(arguments))

            if symlink:
                alias = root / 'alias'
                alias.symlink_to(root, target_is_directory=True)
                source_argument, build_argument = alias / 'source', alias / 'build'
            else:
                source_argument, build_argument = source, build
            with patch.object(sys, 'argv', [str(script), emulator, str(source_argument), str(build_argument)]), \
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

    def test_symlinked_build_paths_are_checked(self):
        for emulator in ('dolphin', 'cemu'):
            for defect in (None, 'unlinked'):
                with self.subTest(emulator=emulator, defect=defect):
                    self.inspect(emulator, defect, symlink=True)

    def test_header_or_similar_library_name_is_not_linkage(self):
        for defect in ('header-only', 'wrong-sdk', 'absolute-sdk'):
            with self.subTest(defect=defect):
                self.inspect('dolphin', defect)

    def test_both_binary_architectures_are_checked(self):
        for emulator in ('dolphin', 'cemu'):
            for defect in ('exe-architecture', 'lib-architecture'):
                with self.subTest(emulator=emulator, defect=defect):
                    self.inspect(emulator, defect)

    def test_corehid_dependency_is_rejected(self):
        self.inspect('cemu', 'corehid')

    def test_inspection_failure_does_not_package_an_app(self):
        self.inspect('dolphin', 'tool-failure')


if __name__ == '__main__':
    unittest.main()
