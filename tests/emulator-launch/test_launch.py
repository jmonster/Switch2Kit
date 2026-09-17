"""Failure-oriented tests at the process/window boundary, without GUI or Bluetooth."""
import importlib.util
import configparser
import hashlib
import stat
import tempfile
import xml.etree.ElementTree as ET
import json
from pathlib import Path
import subprocess
import unittest

spec = importlib.util.spec_from_file_location("launch", Path(__file__).with_name("verify.py"))
launch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(launch)


class Clock:
    def __init__(self):
        self.value = 0.0
    def now(self):
        return self.value
    def sleep(self, interval):
        self.value += interval


class Process:
    def __init__(self, clock, exit_at=None, exit_code=0, quit_timeout=False):
        self.clock, self.exit_at, self.exit_code = clock, exit_at, exit_code
        self.quit_timeout, self.code, self.killed = quit_timeout, None, False
    def poll(self):
        if self.exit_at is not None and self.clock.value >= self.exit_at:
            self.code = self.exit_code
        return self.code
    def wait(self, timeout):
        if self.quit_timeout and not self.killed:
            raise subprocess.TimeoutExpired("owned child", timeout)
        self.code = -9 if self.killed else self.exit_code
        return self.code
    def kill(self):
        self.killed = True
        self.code = -9


class Tests(unittest.TestCase):
    def supervise(self, state=None, **kwargs):
        self.clock = Clock()
        self.process = Process(self.clock, **kwargs)
        self.quit_calls = 0
        def quit_app():
            self.quit_calls += 1
            return {"quit_requested": True}
        return launch.supervise(self.process, state or (lambda: {
            "matched": True, "finished": True, "windows": 1}), quit_app,
            self.clock.now, self.clock.sleep)

    def test_visible_stable_window_and_observed_normal_exit(self):
        result = self.supervise()
        self.assertEqual(result["status"], "passed")
        self.assertTrue(result["window_observed"] and result["normal_exit"])
        self.assertFalse(result["forced_cleanup"])
        self.assertGreaterEqual(self.clock.value, 5)

    def test_successful_early_process_exit_is_not_gui_acceptance(self):
        result = self.supervise(exit_at=0)
        self.assertEqual(result["status"], "failed")
        self.assertFalse(result["window_observed"])
        self.assertEqual(self.quit_calls, 0)
        self.assertFalse(self.process.killed)

    def test_crash_after_window_is_not_a_pass(self):
        result = self.supervise(exit_at=2, exit_code=-6)
        self.assertEqual(result["status"], "failed")
        self.assertTrue(result["window_observed"])
        self.assertFalse(result["normal_exit"])

    def test_registration_alone_is_not_a_window(self):
        result = self.supervise(lambda: {"matched": True, "finished": True, "windows": 0})
        self.assertEqual(result["status"], "failed")
        self.assertTrue(result["forced_cleanup"])
        self.assertLess(self.clock.value, 31)

    def test_wrong_executable_and_unfinished_registration_cannot_pass(self):
        for state in ({"matched": False, "finished": True, "windows": 1},
                      {"matched": True, "finished": False, "windows": 1}):
            with self.subTest(state=state):
                self.assertEqual(self.supervise(lambda: state)["status"], "failed")

    def test_vanished_window_is_not_stable(self):
        result = self.supervise(lambda: {"matched": True, "finished": True,
                                        "windows": int(self.clock.value < 1)})
        self.assertEqual(result["status"], "failed")
        self.assertTrue(self.process.killed)

    def test_quit_request_does_not_prove_shutdown(self):
        result = self.supervise(quit_timeout=True)
        self.assertEqual(result["status"], "failed")
        self.assertTrue(result["quit_requested"] and result["forced_cleanup"])
        self.assertFalse(result["normal_exit"])

    def test_nonzero_exit_after_quit_is_not_normal(self):
        self.assertEqual(self.supervise(exit_code=1)["status"], "failed")

    def test_observer_failure_reaps_only_the_owned_child(self):
        def broken():
            raise subprocess.CalledProcessError(1, "observer")
        result = self.supervise(broken)
        self.assertEqual(result["status"], "failed")
        self.assertTrue(self.process.killed)

    def test_sensitive_environment_is_not_inherited(self):
        env = launch.child_environment(Path('/new home'), Path('/new tmp'))
        self.assertEqual(set(env), {"HOME", "TMPDIR", "PATH", "LANG"})
        self.assertEqual(env['PATH'], '/usr/bin:/bin:/usr/sbin:/sbin')

    def test_sandbox_paths_are_quoted_not_interpolated(self):
        root = '/tmp/space "quote" \\ tab\t newline\n'
        result = launch.sandbox_profile([root])
        self.assertIn('(subpath ' + json.dumps(root) + ')', result)
        self.assertIn('(deny network*)', result)
        self.assertIn('(deny file-read*', result)
        with self.assertRaises(ValueError):
            launch.sandbox_profile(['relative'])

    def test_transient_window_loss_is_not_a_continuous_startup(self):
        result = self.supervise(lambda: {"matched": True, "finished": True,
                                        "windows": int(not 1 <= self.clock.value < 3)})
        self.assertEqual(result["status"], "failed")
        self.assertTrue(self.process.killed)
        self.assertEqual(self.quit_calls, 0)

    def test_dolphin_fixture_declines_analytics_in_private_host_settings(self):
        with tempfile.TemporaryDirectory() as temporary:
            user = Path(temporary)
            record = launch.seed_startup_settings("dolphin", user)
            path = user / "Config/Dolphin.ini"
            parser = configparser.ConfigParser()
            parser.read(path)
            self.assertFalse(parser.getboolean("Analytics", "Enabled"))
            self.assertTrue(parser.getboolean("Analytics", "PermissionAsked"))
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertEqual(record["sha256"], hashlib.sha256(path.read_bytes()).hexdigest())
            self.assertEqual(parser.sections(), ["Analytics"])

    def test_cemu_fixture_is_valid_offline_empty_library_not_a_motion_profile(self):
        with tempfile.TemporaryDirectory() as temporary:
            user = Path(temporary)
            record = launch.seed_startup_settings("cemu", user)
            path = user / "settings.xml"
            xml = ET.parse(path).getroot()
            self.assertEqual(xml.tag, "content")
            self.assertEqual({node.tag: node.text for node in xml},
                             {"check_update": "false", "use_discord_presence": "false"})
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertEqual(record["sha256"], hashlib.sha256(path.read_bytes()).hexdigest())

    def test_settings_seed_refuses_existing_data_and_does_not_overwrite(self):
        for emulator in ("dolphin", "cemu"):
            with self.subTest(emulator=emulator), tempfile.TemporaryDirectory() as temporary:
                user = Path(temporary)
                sentinel = user / "keep"
                sentinel.write_text("unmodified")
                with self.assertRaises(launch.LaunchFailure):
                    launch.seed_startup_settings(emulator, user)
                self.assertEqual(list(user.iterdir()), [sentinel])
                self.assertEqual(sentinel.read_text(), "unmodified")

    def test_settings_seed_refuses_symlink_and_missing_user_directories(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target = root / "target"
            target.mkdir()
            link = root / "link"
            link.symlink_to(target, target_is_directory=True)
            for emulator in ("dolphin", "cemu"):
                for user in (link, root / "missing"):
                    with self.subTest(emulator=emulator, user=user):
                        with self.assertRaises(launch.LaunchFailure):
                            launch.seed_startup_settings(emulator, user)
            self.assertEqual(list(target.iterdir()), [])

    def test_unknown_settings_fixture_has_no_side_effect(self):
        with tempfile.TemporaryDirectory() as temporary:
            user = Path(temporary)
            with self.assertRaises(launch.LaunchFailure):
                launch.seed_startup_settings("unknown", user)
            self.assertEqual(list(user.iterdir()), [])

    def test_personal_machine_is_not_an_unattended_ci_target(self):
        from unittest.mock import patch
        with patch.dict('os.environ', {}, clear=True):
            with self.assertRaises(launch.LaunchFailure):
                launch.run('dolphin', Path('/unread.app'), Path('/unrun'), Path('/unwritten'))


if __name__ == '__main__':
    unittest.main()
