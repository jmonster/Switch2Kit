"""Synthetic fixtures for the real Swift fitter/profile parser. No device measurements."""
import math
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest

TOOL = os.environ["S2K_CALIBRATION_TOOL"]
DEVICE = "00112233-4455-6677-8899-AABBCCDDEEFF"
CONNECTION = "11223344-5566-7788-9900-AABBCCDDEEFF"
POSES = ("+X", "-X", "+Y", "-Y", "+Z", "-Z", "zero")
G = 9.80665
ACC_OFFSET = [100, -40, 25]
ACC_GAIN = [G / 4000, G / 8000, G / 16000]
ACC_AXES = [-2, 3, 1]
GYRO_OFFSET = [11, -7, 3]
GYRO_GAIN = [0.0002, 0.0005, 0.001]
GYRO_AXES = [3, -1, -2]


def binding(model=0x2069):
    return [DEVICE, str(model), "bt-report-v1", "0xb7" if model in (0x2066, 0x2067) else "0xa7", "fixture-holding"]


def raw_fixture(body, offsets, gains, axes):
    """Inverse synthetic fixture construction, not a second report decoder/converter."""
    raw = offsets.copy()
    for component, axis in zip(body, axes):
        native = abs(axis) - 1
        raw[native] += component / gains[native] * (1 if axis > 0 else -1)
    return [round(value) for value in raw]


def fixture_capture(model=0x2069, count=128, step=0.01):
    lines = ["switch2kit-capture,1", ",".join(binding(model) + [CONNECTION])]
    sequence, timestamp = 0, 10.0
    for i, pose in enumerate(POSES):
        body = [0.0, 0.0, 0.0]
        body[2 if pose == "zero" else i // 2] = G * (1 if pose == "zero" or i % 2 == 0 else -1)
        raw = raw_fixture(body, ACC_OFFSET, ACC_GAIN, ACC_AXES)
        for _ in range(count):
            sequence += 1
            timestamp += step
            lines.append(",".join(map(str, [pose, sequence, timestamp, *raw, *GYRO_OFFSET])))
        timestamp += 1  # Repositioning is not a sensor integration interval.
    return "\n".join(lines) + "\n"


def fixture_gyro(model=0x2069, known_rate=True):
    lines = ["switch2kit-gyro-reference,1", ",".join(binding(model))]
    if known_rate:
        lines += ["known-rate,Synthetic 1 rad/s body rotations; not hardware measurements", "rate-rad/s,1"]
        for index, pose in enumerate(POSES[:6]):
            body = [0.0, 0.0, 0.0]
            body[index // 2] = 1 if index % 2 == 0 else -1
            raw = raw_fixture(body, GYRO_OFFSET, GYRO_GAIN, GYRO_AXES)
            lines.append(",".join(map(str, [pose, *raw])))
    else:
        lines += ["verified-configuration,Synthetic import-branch test; not a verified controller configuration",
                  "gain-rad/s-per-count," + ",".join(map(str, GYRO_GAIN)), "axes," + ",".join(map(str, GYRO_AXES))]
    return "\n".join(lines) + "\n"


def change_sample(text, index, column, value):
    lines = text.splitlines()
    fields = lines[2 + index].split(",")
    fields[column] = str(value)
    lines[2 + index] = ",".join(fields)
    return "\n".join(lines) + "\n"


class ToolTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="Switch2Kit profile fixtures ")
        self.root = Path(self.temporary.name)
        self.capture = self.root / "capture.csv"
        self.gyro = self.root / "gyro.csv"
        self.output = self.root / "profile.s2kmotion"
        self.capture.write_text(fixture_capture())
        self.gyro.write_text(fixture_gyro())

    def tearDown(self):
        self.temporary.cleanup()

    def run_tool(self, *args):
        return subprocess.run([TOOL, *map(str, args)], text=True, capture_output=True, check=False, timeout=15)

    def fit(self, success=True):
        result = self.run_tool("fit", "--capture", self.capture, "--gyro-reference", self.gyro, "--output", self.output)
        self.assertEqual(result.returncode, 0 if success else 2, result.stdout + result.stderr)
        self.assertNotIn(DEVICE, result.stderr)
        self.assertNotIn(str(self.root), result.stderr)
        if not success:
            return result
        # Inspect fixed records for test assertions; production decoding is exercised by C/Swift.
        lines = [line.split() for line in self.output.read_text().splitlines()]
        self.assertEqual(len(lines), 16)
        return dict(model=int(lines[2][1], 16), accelerationAxes=list(map(int, lines[9][1:])),
                    angularVelocityAxes=list(map(int, lines[14][1:])),
                    accelerationOffset=list(map(float, lines[7][1:])),
                    angularVelocityOffset=list(map(float, lines[12][1:])),
                    accelerationGain=list(map(float, lines[8][1:])), angularVelocityGain=list(map(float, lines[13][1:])))

    def validate(self, **overrides):
        values = dict(zip(("device", "model", "configuration", "features", "holding"), binding()[:5]))
        values.update(overrides)
        args = ["validate", "--profile", self.output]
        for key, value in values.items():
            args.extend(["--" + key, value])
        return self.run_tool(*args)

    def test_known_rate_and_six_pose_fit_use_independent_maps(self):
        profile = self.fit()
        self.assertEqual(profile["accelerationAxes"], ACC_AXES)
        self.assertEqual(profile["angularVelocityAxes"], GYRO_AXES)
        self.assertEqual(profile["accelerationOffset"], ACC_OFFSET)
        self.assertEqual(profile["angularVelocityOffset"], GYRO_OFFSET)
        for key, expected in (("accelerationGain", ACC_GAIN), ("angularVelocityGain", GYRO_GAIN)):
            for actual, reference in zip(profile[key], expected):
                self.assertTrue(math.isclose(actual, reference, rel_tol=1e-12))
        text = self.output.read_text()
        self.assertIn("acceleration m/s2\n", text)
        self.assertIn("angular-velocity rad/s\n", text)
        self.assertNotIn(CONNECTION, text)
        self.assertNotIn("sequence", text)
        self.assertEqual(stat.S_IMODE(self.output.stat().st_mode), 0o600)
        self.assertEqual(self.validate().returncode, 0)  # Numerical validation is NOT measurement certification.

    def test_native_c_profile_loader_and_existing_converter(self):
        self.fit()
        consumer = os.environ.get("S2K_PROFILE_C_CONSUMER")
        self.assertIsNotNone(consumer, "run.sh must build the real linked C consumer")
        result = subprocess.run([consumer, str(self.output)], capture_output=True, text=True, check=False, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_verified_configuration_import_does_not_infer_gyro_gain_from_stationarity(self):
        self.gyro.write_text(fixture_gyro(known_rate=False))
        profile = self.fit()
        self.assertEqual(profile["angularVelocityGain"], GYRO_GAIN)
        self.assertEqual(profile["angularVelocityAxes"], GYRO_AXES)

    def test_all_models_and_binding_rejection(self):
        for model in (0x2066, 0x2067, 0x2069, 0x2073):
            with self.subTest(model=model):
                self.capture.write_text(fixture_capture(model))
                self.gyro.write_text(fixture_gyro(model))
                self.assertEqual(self.fit()["model"], model)
                self.output.unlink()
        self.capture.write_text(fixture_capture(0x2069))
        self.gyro.write_text(fixture_gyro(0x2073))
        self.fit(success=False)
        self.assertFalse(self.output.exists())

    def test_selection_checks_physical_binding_not_measurement_truth(self):
        self.fit()
        self.assertEqual(self.validate().returncode, 0)
        for key, value in (("device", "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"), ("model", "8307"),
                           ("configuration", "other"), ("features", "0x00"), ("holding", "other")):
            self.assertEqual(self.validate(**{key: value}).returncode, 2)

    def test_known_rate_and_stationary_bias_must_agree(self):
        # Synthetic fixture deliberately contradicts the independently obtained rate references.
        lines = fixture_capture().splitlines()
        for i in range(2, len(lines)):
            fields = lines[i].split(",")
            fields[6] = "3000"
            lines[i] = ",".join(fields)
        self.capture.write_text("\n".join(lines))
        self.fit(success=False)
        self.assertFalse(self.output.exists())

    def test_discontinuous_and_malformed_samples_are_rejected(self):
        baseline = fixture_capture()
        cases = [(4, 1, 0), (4, 1, 4), (4, 1, 6), (4, 2, "nan"), (4, 2, 10.04),
                 (4, 2, 1000), (4, 3, 32767), (4, 3, -32768), (4, 3, 32768),
                 (4, 3, "1e3"), (4, 0, "zero"), (4, 0, "unknown")]
        for index, column, value in cases:
            with self.subTest(column=column, value=value):
                self.capture.write_text(change_sample(baseline, index, column, value))
                self.fit(success=False)
                self.assertFalse(self.output.exists())

    def test_moving_acceleration_and_gyro_are_rejected(self):
        for column, value in ((3, 2000), (6, 2000)):
            with self.subTest(column=column):
                self.capture.write_text(change_sample(fixture_capture(), 20, column, value))
                self.fit(success=False)
                self.assertFalse(self.output.exists())

    def test_missing_pose_and_zero_gravity_are_rejected(self):
        self.capture.write_text("\n".join(line for line in fixture_capture().splitlines() if not line.startswith("+Y,")))
        self.fit(success=False)
        lines = fixture_capture().splitlines()
        for index, line in enumerate(lines):
            if line.startswith("zero,"):
                fields = line.split(",")
                fields[3:6] = map(str, ACC_OFFSET)
                lines[index] = ",".join(fields)
        self.capture.write_text("\n".join(lines))
        self.fit(success=False)

    def test_thousands_of_samples_and_fixed_sample_limit(self):
        self.capture.write_text(fixture_capture(count=1281, step=0.001))
        self.fit()
        self.output.unlink()
        self.capture.write_text(fixture_capture(count=2049, step=0.001))
        self.fit(success=False)
        self.assertFalse(self.output.exists())

    def test_bad_gyro_basis_rate_axes_and_configuration(self):
        baseline = fixture_gyro()
        bad = [baseline.replace("known-rate,", "stationary,"), baseline.replace("rate-rad/s,1\n", "rate-rad/s,0\n"),
               baseline.replace("rate-rad/s,1\n", "rate-rad/s,nan\n"), baseline.replace("bt-report-v1", "other"),
               baseline.replace("+Y,", "+X,"), baseline.replace("Synthetic 1 rad/s body rotations; not hardware measurements", "")]
        direct = fixture_gyro(known_rate=False)
        bad += [direct.replace("axes,3,-1,-2", "axes,1,-1,3"), direct.replace("gain-rad/s-per-count,0.0002", "gain-rad/s-per-count,1e999"),
                direct.replace("gain-rad/s-per-count,0.0002", "gain-rad/s-per-count,-1")]
        for record in bad:
            with self.subTest(record=record[:30]):
                self.assertNotEqual(record, baseline if "known-rate," in record else direct)
                self.gyro.write_text(record)
                self.fit(success=False)
                self.assertFalse(self.output.exists())

    def test_sizes_lines_fifo_and_output_overwrite_are_bounded(self):
        valid = self.capture.read_text()
        for contents in ("x" * (4 * 1024 * 1024 + 1), "\n" * 20000, "x" * 513, "", "\ufffd"):
            self.capture.write_text(contents)
            self.fit(success=False)
        self.capture.unlink()
        os.mkfifo(self.capture)
        self.fit(success=False)  # Must reject immediately, not block waiting for a FIFO writer.
        self.capture.unlink()
        self.capture.write_text(valid)
        self.output.write_text("keep existing user data")
        self.fit(success=False)
        self.assertEqual(self.output.read_text(), "keep existing user data")

    def test_unknown_or_duplicate_cli_arguments_do_not_capture(self):
        for args in (("capture",), ("fit", "--capture", self.capture, "--capture", self.capture),
                     ("fit", "--unknown", "x"), ("list", "--capture", "x")):
            self.assertEqual(self.run_tool(*args).returncode, 2)


if __name__ == "__main__":
    unittest.main()
