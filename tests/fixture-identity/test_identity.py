"""Test fixture compilation follows SwiftPM, including renamed checkouts."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "support/compile-fixture.py"
spec = importlib.util.spec_from_file_location("compile_fixture", SCRIPT)
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)
prepare_spec = importlib.util.spec_from_file_location("prepare_sources", SCRIPT.with_name("prepare-sources.py"))
prepare = importlib.util.module_from_spec(prepare_spec)
prepare_spec.loader.exec_module(prepare)


def description(name):
    return {"swiftCommands": {module: {
        "moduleName": module, "otherArguments": ["-swift-version", "6", "-package-name", name]
    } for module in ("Switch2Kit", "Switch2KitC")}}


class FixtureIdentityTests(unittest.TestCase):
    def test_actual_package_identity_is_preserved(self):
        for name in ("switch2kit", "work_switch2kit", "native_sdk_checkout", "sdk_123", "ки́т"):
            with self.subTest(name=name):
                self.assertEqual(helper.package_name(description(name)), name)

    def test_other_modules_are_ignored(self):
        data = description("test_checkout")
        data["swiftCommands"]["Consumer"] = {"moduleName": "Consumer", "otherArguments": []}
        self.assertEqual(helper.package_name(data), "test_checkout")

    def test_missing_build_data_is_rejected(self):
        for data in ({}, {"swiftCommands": []}, {"swiftCommands": {}},
                     {"swiftCommands": {"Kit": description("kit")["swiftCommands"]["Switch2Kit"]}}):
            with self.subTest(data=data), self.assertRaises(ValueError):
                helper.package_name(data)

    def test_missing_duplicate_or_malformed_package_option_is_rejected(self):
        for arguments in ([], ["-package-name"], ["-package-name", ""], ["-package-name", "-Onone"],
                          ["-package-name", "one", "-package-name", "two"], ["-package-name", 1]):
            data = description("kit")
            data["swiftCommands"]["Switch2Kit"]["otherArguments"] = arguments
            with self.subTest(arguments=arguments), self.assertRaises(ValueError):
                helper.package_name(data)

    def test_mismatching_modules_are_rejected(self):
        data = description("kit")
        data["swiftCommands"]["Switch2KitC"]["otherArguments"][-1] = "other"
        with self.assertRaises(ValueError):
            helper.package_name(data)
        data = description("kit")
        data["swiftCommands"]["other-kit"] = {"moduleName": "Switch2Kit", "otherArguments": ["-package-name", "other"]}
        with self.assertRaises(ValueError):
            helper.package_name(data)

    def test_compiler_argv_and_exit_status_are_preserved(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "description.json"
            path.write_text(json.dumps(description("sdk_checkout")))
            with patch.object(subprocess, "run", return_value=subprocess.CompletedProcess([], 7)) as run:
                result = helper.main(["--description", str(path), "--compiler", "/tools with spaces/swiftc",
                                      "--", "-emit-library", "source with spaces.swift", "-o", "fixture.so"])
            self.assertEqual(result, 7)
            run.assert_called_once_with(["/tools with spaces/swiftc", "-package-name", "sdk_checkout",
                                         "-emit-library", "source with spaces.swift", "-o", "fixture.so"], check=False)

    def test_invalid_description_and_identity_override_do_not_run_compiler(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "description.json"
            for contents, arguments in (("not json", []), ("[]", []), ("{}", []),
                                        (json.dumps(description("kit")), ["-package-name", "other"])):
                path.write_text(contents)
                with patch.object(subprocess, "run") as run, contextlib.redirect_stderr(io.StringIO()) as error:
                    self.assertEqual(helper.main(["--description", str(path), "--compiler", "swiftc", "--", *arguments]), 2)
                    self.assertIn("Cannot compile Swift fixture:", error.getvalue())
                    run.assert_not_called()


class ClangModuleTests(unittest.TestCase):
    def testTransitiveModuleMapsAreDeduplicatedWithoutCopyingOtherFlags(self):
        data = description("native_sdk")
        for command in data["swiftCommands"].values():
            command["otherArguments"] += ["-Xcc", "-fmodule-map-file=/path with spaces/Radio/module.modulemap", "-Xcc", "-fPIC"]
        self.assertEqual(helper.clang_modules(data), ["-Xcc", "-fmodule-map-file=/path with spaces/Radio/module.modulemap"])


class FixturePlatformTests(unittest.TestCase):
    def test_fake_host_address_path_is_available_without_apple_frameworks(self):
        body = "return IOBluetoothHostController.default()?.addressAsString()"
        source = "#if canImport(IOBluetooth)\nimport IOBluetooth\n#endif\n" + \
            "func address() -> String? {\n    #if canImport(IOBluetooth)\n" + body + "\n#else\nreturn nil\n#endif\n}"
        result = prepare.fixture(source)
        self.assertNotIn("import IOBluetooth", result)
        self.assertEqual(result.count("#if canImport(IOBluetooth) || S2K_RADIO_FIXTURE"), 2)
        self.assertIn(body, result)
        self.assertIn("#else\nreturn nil\n#endif", result)


if __name__ == "__main__":
    unittest.main()
