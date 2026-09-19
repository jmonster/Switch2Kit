"""Failure-oriented package-supervisor tests, without a Swift or Bluetooth substitute."""
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('relocation', Path(__file__).resolve().parents[1] / 'c-consumer/relocate-windows.py')
relocation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(relocation)


class Tests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='relocation [fixture] ')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.windows = self.root / 'Windows'
        (self.windows / 'System32').mkdir(parents=True)
        self.c, self.sdl, self.work = self.root / 'C build', self.root / 'SDL build', self.root / 'work'
        for build, names in ((self.c, ('c-consumer.exe',)), (self.sdl, ('sdl-inprocess.exe', 'sdl-motion.exe'))):
            build.mkdir()
            for name in (*names, 'Switch2KitC.dll', 'swiftCore.dll'):
                (build / name).write_bytes(b'package fixture only: ' + name.encode())
            for name in relocation.NOTICES:
                path = build / 'Switch2KitNotices' / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('complete fixture license\n')
        self.work.mkdir()

    def test_missing_binary_and_empty_notice_fail_before_launch(self):
        (self.c / 'swiftCore.dll').unlink()
        with self.assertRaises(RuntimeError):
            relocation.stage(self.c, self.root / 'missing', ('c-consumer.exe',))
        (self.sdl / 'Switch2KitNotices' / relocation.NOTICES[0]).write_bytes(b'')
        with self.assertRaises(RuntimeError):
            relocation.stage(self.sdl, self.root / 'empty', ('sdl-motion.exe',))

    def test_environment_has_only_os_paths_and_private_user_directories(self):
        environment = relocation.child_environment(self.work, {'SystemRoot': str(self.windows), 'PATH': '/compiler/bin',
            'SWIFT_RUNTIME_PATH': '/compiler/runtime', 'SDKROOT': '/compiler/sdk', 'APPDATA': '/real-user/config',
            'LD_LIBRARY_PATH': '/developer/runtime', 'SDL_GAMECONTROLLERCONFIG': 'do not inherit'})
        self.assertEqual(set(environment), {'SystemRoot', 'WINDIR', 'PATH', 'COMSPEC', 'USERPROFILE', 'HOME',
                                           'APPDATA', 'LOCALAPPDATA', 'TEMP', 'TMP'})
        self.assertEqual(environment['PATH'], str(self.windows / 'System32') + ';' + str(self.windows))
        for key in ('USERPROFILE', 'HOME', 'APPDATA', 'LOCALAPPDATA', 'TEMP', 'TMP'):
            self.assertTrue(Path(environment[key]).is_relative_to(self.work))
            self.assertTrue(Path(environment[key]).is_dir())

    def test_invalid_system_root_fails_closed(self):
        for inherited in ({}, {'SystemRoot': str(self.root / 'not Windows')}):
            with self.assertRaises(RuntimeError):
                relocation.child_environment(self.work, inherited)

    def invoke(self, failure=None):
        report = {}
        self.calls = []
        def execute(exe, env):
            self.assertTrue(exe.is_relative_to(self.work / 'extracted package'))
            self.assertFalse((self.work / 'staged package').exists())
            self.assertEqual(exe.read_bytes(), b'package fixture only: ' + exe.name.encode())
            self.calls.append(exe)
            missing = any(not (exe.parent / name).exists() for name in ('Switch2KitC.dll', 'swiftCore.dll'))
            code = (failure if failure is not None else -1073741515) if missing else 0
            return {'executable': str(exe), 'exit_code': code, 'output': ''}
        with patch.dict(os.environ, {'SystemRoot': str(self.windows)}, clear=True), patch.object(relocation, 'execute', execute):
            relocation.qualify(self.c, self.sdl, self.work, report)
        return report

    def test_exact_archive_is_extracted_and_all_consumers_and_negative_controls_run(self):
        report = self.invoke()
        self.assertEqual(len(report['runs']), 3)
        self.assertEqual(len(report['negative_controls']), 6)
        self.assertEqual(len(self.calls), 9)
        for name in ('Switch2KitC.dll', 'swiftCore.dll'):
            self.assertTrue((self.work / 'extracted package/c' / name).is_file())
            self.assertTrue((self.c / name).is_file())
        self.assertIn('c/Switch2KitNotices/SwiftRuntime/ICU.txt', report['files'])

    def test_a_global_runtime_rescuing_missing_dll_cannot_pass(self):
        with self.assertRaises(RuntimeError):
            self.invoke(failure=0)
        self.assertTrue((self.work / 'extracted package/c/Switch2KitC.dll').exists())

    def test_arbitrary_crash_is_not_a_missing_library_pass(self):
        with self.assertRaises(RuntimeError):
            self.invoke(failure=-1073740791)  # Fast-fail assertion, not DLL-not-found.

    def test_nonzero_consumer_execution_fails_and_keeps_diagnostics(self):
        report = {}
        with patch.dict(os.environ, {'SystemRoot': str(self.windows)}, clear=True), patch.object(relocation, 'execute',
            return_value={'exit_code': 23, 'output': 'consumer failed'}):
            with self.assertRaises(RuntimeError):
                relocation.qualify(self.c, self.sdl, self.work, report)
        self.assertEqual(report['runs'], [{'exit_code': 23, 'output': 'consumer failed'}])

    def test_timeout_kills_and_reaps_only_owned_process(self):
        from unittest.mock import Mock
        process = Mock()
        process.communicate.side_effect = [subprocess.TimeoutExpired('child', 0.1), ('timed out output', None)]
        with patch.object(subprocess, 'Popen', return_value=process) as spawn:
            with self.assertRaises(RuntimeError):
                relocation.execute(self.c / 'c-consumer.exe', {'PATH': 'OS only'}, timeout=0.1)
        process.kill.assert_called_once_with()
        self.assertEqual(process.communicate.call_count, 2)
        self.assertEqual(spawn.call_args.args[0], [str(self.c / 'c-consumer.exe')])
        self.assertEqual(spawn.call_args.kwargs['env'], {'PATH': 'OS only'})
        self.assertNotIn('shell', spawn.call_args.kwargs)

    def test_real_subprocess_uses_its_executable_without_a_shell(self):
        # No fixture is passed off as a native consumer: this checks the supervisor only.
        environment = dict(os.environ, PYTHONINSPECT='')
        result = relocation.execute(Path(sys.executable), environment)
        self.assertEqual(result['exit_code'], 0, result)


if __name__ == '__main__':
    unittest.main()
