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
    def inspect(self, emulator, defect=None, script=SCRIPT, symlink=False, architecture="arm64", expected_architecture=None):
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
                'CFBundleIdentifier': 'changed' if defect == 'identity' else (
                    'org.dolphin-emu.dolphin' if emulator == 'dolphin' else 'info.cemu.Cemu'),
                'NSBluetoothAlwaysUsageDescription': 'Controller input',
                'LSMinimumSystemVersion': '15.0',
            }))
            filenames = ('SDL.cpp', 'SDLGamepad.cpp', 'ControllersPane.cpp', 'Dynamics.cpp', 'WiimoteEmu.cpp') if emulator == 'dolphin' else (
                'SDLControllerProvider.cpp', 'SDLController.cpp', 'ControllerFactory.cpp', 'InputAPIAddWindow.cpp',
                'DefaultControllerSettings.cpp', 'VPADController.cpp', 'WPADController.cpp')
            (build / 'compile_commands.json').write_text(json.dumps([
                {'file': name, 'command': 'clang++ -DHAVE_SWITCH2KIT=1'} for name in filenames
            ]))

            def output(arguments):
                calls.append(arguments)
                if arguments == ['uname', '-m']:
                    return architecture + '\n'
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
                if arguments[:3] == ['xcrun', 'otool', '-l']:
                    path = Path(arguments[-1]).resolve()
                    self.assertIn(path, (exe, lib))
                    minimum = '16.0' if defect == 'deployment' else '15.0'
                    platform = '2' if defect == 'platform' else '1'
                    commands = ('Load command 0\n      cmd LC_BUILD_VERSION\n  cmdsize 32\n'
                                ' platform ' + platform + '\n    minos ' + minimum + '\n      sdk 26.2\n')
                    if defect == 'missing-deployment':
                        commands = ''
                    search = '/Applications/Xcode Test.app/runtime' if defect == 'build-rpath' else '@loader_path'
                    if defect == 'malformed-rpath':
                        commands += 'Load command 1\n      cmd LC_RPATH\n  cmdsize 32\n'
                    else:
                        commands += 'Load command 1\n      cmd LC_RPATH\n  cmdsize 32\n     path ' + search + ' (offset 12)\n'
                    return str(path) + ':\n' + commands
                if arguments[:2] == ['xcrun', 'lipo']:
                    self.assertEqual(arguments[2], '-archs')
                    self.assertEqual(len(arguments), 4)
                    path = Path(arguments[3]).resolve()
                    self.assertIn(path, (exe, lib))
                    if ((defect == 'exe-architecture' and path == exe)
                            or (defect == 'lib-architecture' and path == lib)):
                        return ('x86_64' if architecture == 'arm64' else 'arm64') + '\n'
                    return 'arm64 x86_64\n'
                return ''

            def run(arguments, **kwargs):
                if arguments[0] == sys.executable:
                    calls.append(arguments)
                    self.assertEqual(arguments[1:3], ['-I', '-c'])
                    self.assertIn('ctypes.CDLL', arguments[3])
                    self.assertEqual(arguments[-1], str(lib))
                    self.assertEqual(kwargs['timeout'], 30)
                    self.assertFalse(any(key.startswith('DYLD_') or key == 'LD_LIBRARY_PATH'
                                         for key in kwargs['env']))
                    return subprocess.CompletedProcess(arguments, 1 if defect == 'sdk-load' else 0,
                                                       'Facade load probe')
                return subprocess.CompletedProcess(arguments, 0, output(arguments))

            if symlink:
                alias = root / 'alias'
                alias.symlink_to(root, target_is_directory=True)
                source_argument, build_argument = alias / 'source', alias / 'build'
            else:
                source_argument, build_argument = source, build
            arguments = [str(script), emulator, str(source_argument), str(build_argument)]
            if expected_architecture is not None:
                arguments += ['--architecture', expected_architecture]
            (build / 'integration-inspection.json').write_text('stale success')
            (build / 'integration-app.zip').touch()
            with patch.object(sys, 'argv', arguments), \
                    patch('subprocess.run', side_effect=run), \
                    patch('subprocess.check_output', side_effect=lambda arguments, **kw: output(arguments)), \
                    contextlib.redirect_stdout(io.StringIO()):
                if defect:
                    expected = subprocess.CalledProcessError if defect in ('tool-failure', 'sdk-load') else AssertionError
                    with self.assertRaises(expected):
                        runpy.run_path(str(script), run_name='__main__')
                    self.assertFalse(any(command[0] == 'ditto' for command in calls))
                    self.assertFalse((build / 'integration-inspection.json').exists())
                    self.assertFalse((build / 'integration-app.zip').exists())
                else:
                    runpy.run_path(str(script), run_name='__main__')
                    self.assertTrue(any(command[0] == 'ditto' for command in calls))
                    self.assertTrue(any(command[:2] == ['xcrun', 'nm'] for command in calls))
                    report = json.loads((build / 'integration-inspection.json').read_text())
                    self.assertEqual(report['native_architecture'], architecture)
                    self.assertEqual(len(report['binaries']), 2)
                    self.assertTrue(report['bundled_sdk_load_checked'])
                    for binary in report['binaries']:
                        self.assertEqual(binary['architectures'], ['arm64', 'x86_64'])
                        self.assertEqual(binary['minimum_macos_versions'], ['15.0'])
                        self.assertEqual(binary['runtime_search_paths'], ['@loader_path'])
                    self.assertIn('lipo -archs', (build / 'integration-native-diagnostics.txt').read_text())
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

    def test_intel_native_inspection_and_missing_slices(self):
        for emulator in ('dolphin', 'cemu'):
            for defect in (None, 'exe-architecture', 'lib-architecture'):
                with self.subTest(emulator=emulator, defect=defect):
                    self.inspect(emulator, defect, architecture='x86_64', expected_architecture='x86_64')

    def test_wrong_native_runner_is_rejected(self):
        self.inspect('dolphin', 'runner-architecture', architecture='arm64', expected_architecture='x86_64')

    def test_corehid_dependency_is_rejected(self):
        self.inspect('cemu', 'corehid')

    def test_binary_deployment_platform_and_bundle_identity_are_checked(self):
        for emulator in ('dolphin', 'cemu'):
            for defect in ('deployment', 'missing-deployment', 'platform', 'identity'):
                with self.subTest(emulator=emulator, defect=defect):
                    self.inspect(emulator, defect)

    def test_build_machine_or_malformed_runtime_paths_are_rejected(self):
        for defect in ('build-rpath', 'malformed-rpath'):
            with self.subTest(defect=defect):
                self.inspect('cemu', defect)

    def test_load_failure_does_not_package_an_app(self):
        for emulator in ('dolphin', 'cemu'):
            with self.subTest(emulator=emulator):
                self.inspect(emulator, 'sdk-load')

    def test_inspection_failure_does_not_package_an_app(self):
        self.inspect('dolphin', 'tool-failure')


if __name__ == '__main__':
    unittest.main()
