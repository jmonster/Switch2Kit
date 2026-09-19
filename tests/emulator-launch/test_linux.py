"""Linux observer startup prerequisites; no fixture replaces an emulator GUI."""
import importlib.util
from pathlib import Path
import subprocess
import unittest
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location("linux_launch", Path(__file__).with_name("linux.py"))
linux = importlib.util.module_from_spec(spec)
spec.loader.exec_module(linux)


class Clock:
    def __init__(self):
        self.value = 0.0
    def now(self):
        return self.value
    def sleep(self, seconds):
        self.value += seconds


class WindowManagerReadiness(unittest.TestCase):
    def setUp(self):
        self.clock = Clock()
        self.manager = Mock()
        self.manager.poll.return_value = None

    def wait(self):
        linux.wait_window_manager(self.manager, {}, self.clock.now, self.clock.sleep)

    def test_identity_before_client_list_waits_for_the_actual_observer(self):
        queries = []
        def probe(arguments, **kwargs):
            queries.append(arguments[1])
            code = int(arguments[1] == "-lp" and queries.count("-lp") < 3)
            return subprocess.CompletedProcess(arguments, code, b"", b"")
        with patch.object(linux.subprocess, "run", side_effect=probe):
            self.wait()
        self.assertEqual(queries, ["-m", "-lp"] * 3)
        self.assertGreaterEqual(self.clock.value, 0.2)

    def test_an_available_empty_client_list_is_ready_without_a_dummy_window(self):
        with patch.object(linux.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, b"", b"")) as probe:
            self.wait()
        self.assertEqual([call.args[0] for call in probe.call_args_list], [["wmctrl", "-m"], ["wmctrl", "-lp"]])
        self.assertEqual(self.clock.value, 0)

    def test_permanently_missing_client_list_is_bounded_and_fails(self):
        def probe(arguments, **kwargs):
            return subprocess.CompletedProcess(arguments, int(arguments[1] == "-lp"))
        with patch.object(linux.subprocess, "run", side_effect=probe):
            with self.assertRaises(linux.LaunchFailure):
                self.wait()
        self.assertEqual(self.clock.value, 5)

    def test_exited_window_manager_is_fatal_without_querying_other_processes(self):
        self.manager.poll.return_value = 1
        with patch.object(linux.subprocess, "run") as probe:
            with self.assertRaises(linux.LaunchFailure):
                self.wait()
        probe.assert_not_called()

    def test_probe_timeouts_count_against_the_same_deadline(self):
        def probe(arguments, **kwargs):
            self.clock.sleep(kwargs["timeout"])
            raise subprocess.TimeoutExpired(arguments, kwargs["timeout"])
        with patch.object(linux.subprocess, "run", side_effect=probe):
            with self.assertRaises(linux.LaunchFailure):
                self.wait()
        self.assertEqual(self.clock.value, 5)

    def test_missing_observer_executable_is_not_treated_as_ready(self):
        with patch.object(linux.subprocess, "run", side_effect=FileNotFoundError("wmctrl")):
            with self.assertRaises(FileNotFoundError):
                self.wait()

    def test_observer_failure_after_readiness_is_still_fatal(self):
        with patch.object(linux.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, "", "display failed")):
            with self.assertRaises(linux.LaunchFailure):
                linux.windows(123, {})


if __name__ == "__main__":
    unittest.main(verbosity=2)
