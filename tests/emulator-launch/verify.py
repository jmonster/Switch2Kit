#!/usr/bin/env python3
"""Launch a complete emulator GUI in a fresh, dependency-restricted macOS CI job.

This is not a physical-controller, first-run-setup, signing, or stock-Mac acceptance
result. No controller discovery, input injection, privacy bypass, or screenshots.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import resource
import subprocess
import tempfile
import time


class LaunchFailure(RuntimeError):
    pass


def supervise(process, inspect, quit_app, now=time.monotonic, sleep=time.sleep):
    """Require real GUI registration/window, continued life, then a normal exit."""
    result = {"window_observed": False, "stable_seconds": 0, "quit_requested": False,
              "normal_exit": False, "forced_cleanup": False}
    try:
        deadline = now() + 30
        while now() < deadline:
            if process.poll() is not None:
                raise LaunchFailure("Application exited before a usable GUI appeared")
            state = inspect()
            if state.get("matched") and state.get("finished") and state.get("windows", 0) > 0:
                result["window_observed"] = True
                break
            sleep(0.2)
        if not result["window_observed"]:
            raise LaunchFailure("No registered application window within 30 seconds")
        deadline = now() + 5
        while now() < deadline:
            if process.poll() is not None:
                raise LaunchFailure("Application exited during the GUI observation interval")
            state = inspect()
            if not (state.get("matched") and state.get("finished") and state.get("windows", 0) > 0):
                raise LaunchFailure("Application lost its window during observation")
            sleep(0.2)
        state = inspect()
        if not (state.get("matched") and state.get("finished") and state.get("windows", 0) > 0):
            raise LaunchFailure("Application lost its window during observation")
        result["stable_seconds"] = 5
        if process.poll() is not None:
            raise LaunchFailure("Application exited before the quit request")
        result["quit_requested"] = bool(quit_app().get("quit_requested"))
        if not result["quit_requested"]:
            raise LaunchFailure("Application refused the ordinary quit request")
        try:
            code = process.wait(timeout=10)
        except subprocess.TimeoutExpired as error:
            raise LaunchFailure("Application did not quit within 10 seconds") from error
        if code != 0:
            raise LaunchFailure("Application did not exit normally")
        result["normal_exit"] = True
        result["status"] = "passed"
    except (LaunchFailure, OSError, ValueError, subprocess.SubprocessError) as error:
        result["status"] = "failed"
        result["reason"] = str(error)[:512]
    finally:
        # Only our unreaped child is eligible for cleanup; never kill by app name.
        if process.poll() is None:
            result["forced_cleanup"] = True
            process.kill()
            process.wait(timeout=5)
    return result


def child_environment(home, tmp):
    # Do not inherit GitHub tokens, DYLD overrides, QT plugins, or build settings.
    return {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(home),
            "TMPDIR": str(tmp) + "/", "LANG": "en_US.UTF-8"}


def seed_startup_settings(emulator, user):
    """Use empty, offline CI settings instead of unattended first-use dialogs.

    These are host settings, not motion profiles or macOS privacy grants. Only a
    just-created disposable user directory is accepted; existing files survive.
    Keys match the pinned upstream Cemu/Dolphin configuration readers.
    """
    if user.is_symlink() or not user.is_dir() or any(user.iterdir()):
        raise LaunchFailure("Startup settings require an empty owned user directory")
    if emulator == "dolphin":
        config = user / "Config"
        config.mkdir(exist_ok=False)
        path = config / "Dolphin.ini"
        content = "[Analytics]\nEnabled = False\nPermissionAsked = True\n"
    elif emulator == "cemu":
        path = user / "settings.xml"
        content = ("<?xml version=\"1.0\"?>\n<content>\n"
                   "  <check_update>false</check_update>\n"
                   "  <use_discord_presence>false</use_discord_presence>\n"
                   "</content>\n")
    else:
        raise LaunchFailure("Unknown startup settings fixture")
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        stream.write(content)
    return {"fixture": "empty-offline-v1", "sha256": hashlib.sha256(content.encode()).hexdigest()}


def sandbox_profile(blocked):
    # Quoted JSON strings are also valid SBPL strings; no shell/Scheme interpolation.
    if not blocked or any(not str(p).startswith("/") for p in blocked):
        raise ValueError("Blocked roots must be absolute")
    return "(version 1)\n(allow default)\n(deny network*)\n(deny file-read*\n" + "".join(
        "  (subpath " + json.dumps(str(p)) + ")\n" for p in blocked) + ")\n"


def run(emulator, original, helper, output):
    if platform.system() != "Darwin" or os.environ.get("GITHUB_ACTIONS") != "true" or \
            os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted":
        raise LaunchFailure("This unattended launcher only runs on disposable GitHub-hosted macOS runners")
    if original.is_symlink() or not original.is_dir() or original.suffix != ".app":
        raise LaunchFailure("Expected an extracted application bundle")
    info = plistlib.loads((original / "Contents/Info.plist").read_bytes())
    expected_id = {"dolphin": "org.dolphin-emu.dolphin", "cemu": "info.cemu.Cemu"}[emulator]
    name = info.get("CFBundleExecutable", "")
    if not name or Path(name).name != name or info.get("CFBundleIdentifier") != expected_id:
        raise LaunchFailure("Unexpected application identity")
    if not info.get("NSBluetoothAlwaysUsageDescription"):
        raise LaunchFailure("Missing Bluetooth usage description")
    output.mkdir(parents=True, exist_ok=False)
    record = {"version": 1, "emulator": emulator, "architecture": platform.machine(),
              "macos": platform.mac_ver()[0], "source_revision": os.environ.get("GITHUB_SHA"),
              "scope": "fresh-CI full-GUI launch with build-dependency reads denied",
              "physical_controller_tested": False, "stock_clean_mac_tested": False,
              "pristine_first_run_tested": False,
              "runs": [], "status": "failed"}
    try:
        with tempfile.TemporaryDirectory(prefix="s2k launch ") as temporary:
            root = Path(temporary).resolve()
            app = root / original.name
            subprocess.run(["/usr/bin/ditto", str(original), str(app)], check=True, timeout=60)
            executable = app / "Contents/MacOS" / name
            native = app / "Contents/Frameworks/libSwitch2KitC.dylib"
            record["executable_sha256"] = hashlib.sha256(executable.read_bytes()).hexdigest()
            record["sdk_sha256"] = hashlib.sha256(native.read_bytes()).hexdigest()
            # Cemu's pinned macOS path policy uses a sibling portable directory.
            # Dolphin has an explicit --user option. Neither writes to a real profile.
            user = root / ("portable" if emulator == "cemu" else "user")
            home, tmp = root / "home", root / "tmp"
            for directory in (user, home, tmp):
                directory.mkdir()
            record["startup_settings"] = seed_startup_settings(emulator, user)
            blocked = [Path("/Applications"), Path("/Library/Developer"), Path("/opt/homebrew"),
                       Path("/usr/local"), Path(os.environ["GITHUB_WORKSPACE"]).resolve()]
            if any(root == p or p in root.parents for p in blocked):
                raise LaunchFailure("Staged app must be outside blocked dependency roots")
            profile = root / "launch.sb"
            profile.write_text(sandbox_profile(blocked))
            sandbox = ["/usr/bin/sandbox-exec", "-f", str(profile)]
            # Negative controls: an existing blocked directory must not even be stat'ed.
            checked = []
            for path in blocked:
                if path.exists():
                    denial = subprocess.run(sandbox + ["/bin/ls", "-d", str(path)],
                                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                            timeout=5)
                    if denial.returncode == 0:
                        raise LaunchFailure("Build-dependency restriction is not effective")
                    checked.append(str(path))
            record["blocked_roots_checked"] = checked
            if not checked:
                raise LaunchFailure("No dependency restriction negative control ran")
            args = [str(executable)] + (["--user", str(user)] if emulator == "dolphin" else [])
            env = child_environment(home, tmp)
            for phase in ("configured-launch", "repeat-launch"):
                # Bound CI-only startup logging. An excessive writer fails, not truncates to success.
                def limit_log():
                    resource.setrlimit(resource.RLIMIT_FSIZE, (1024 * 1024, 1024 * 1024))
                with (output / (phase + ".log")).open("xb") as log:
                    process = subprocess.Popen(sandbox + args, cwd=root, env=env,
                                               stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                                               preexec_fn=limit_log)
                    def query(action):
                        text = subprocess.check_output([str(helper), action, str(process.pid),
                                                        str(executable)], text=True, timeout=5)
                        if len(text) > 4096:
                            raise LaunchFailure("Observer response exceeds bounds")
                        return json.loads(text)
                    result = supervise(process, lambda: query("inspect"), lambda: query("quit"))
                result["phase"] = phase
                record["runs"].append(result)
                if result["status"] != "passed":
                    raise LaunchFailure(result["reason"])
            record["status"] = "passed"
    except (LaunchFailure, OSError, ValueError, subprocess.SubprocessError) as error:
        record["reason"] = str(error)[:512]
    finally:
        (output / "launch.json").write_text(json.dumps(record, indent=2) + "\n")
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("emulator", choices=("dolphin", "cemu"))
    parser.add_argument("app", type=Path)
    parser.add_argument("observer", type=Path)
    parser.add_argument("output", type=Path)
    options = parser.parse_args()
    try:
        result = run(options.emulator, options.app.resolve(), options.observer.resolve(),
                     options.output.resolve())
        print(json.dumps(result, indent=2))
        return 0 if result["status"] == "passed" else 1
    except (LaunchFailure, OSError, ValueError) as error:
        print(str(error)[:512])
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
