#!/usr/bin/env python3
"""Qualify an exact development archive: extracted GUI, normal quit and relaunch.

Requires Xvfb (or another isolated X11 display), Openbox, wmctrl and xprop.
No controller, gameplay, first-use wizard or clean-distribution acceptance is implied.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile
import time

from verify import LaunchFailure, seed_startup_settings, supervise


def command(arguments, env):
    result = subprocess.run(arguments, env=env, text=True, capture_output=True, timeout=10)
    if result.returncode:
        raise LaunchFailure(f"Command failed: {arguments}: {result.stderr[:512]}")
    return result.stdout


def environment(root):
    env = {"PATH": "/usr/bin:/bin", "HOME": str(root / "home"),
           "XDG_CONFIG_HOME": str(root / "config"), "XDG_DATA_HOME": str(root / "data"),
           "XDG_CACHE_HOME": str(root / "cache"), "XDG_RUNTIME_DIR": str(root / "runtime"),
           "TMPDIR": str(root / "tmp"), "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8",
           "QT_QPA_PLATFORM": "xcb", "GDK_BACKEND": "x11"}
    for name in ("DISPLAY", "XAUTHORITY", "DBUS_SESSION_BUS_ADDRESS"):
        if os.environ.get(name):
            env[name] = os.environ[name]
    if "DISPLAY" not in env:
        raise LaunchFailure("Use xvfb-run on an isolated X11 display")
    for name in ("HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "XDG_RUNTIME_DIR", "TMPDIR"):
        Path(env[name]).mkdir(mode=0o700)
    return env


def windows(pid, env):
    result = []
    for line in command(["wmctrl", "-lp"], env).splitlines():
        fields = line.split(None, 4)
        if len(fields) < 4 or fields[2] != str(pid):
            continue
        types = command(["xprop", "-id", fields[0], "_NET_WM_WINDOW_TYPE"], env)
        if "_NET_WM_WINDOW_TYPE_NORMAL" in types:
            result.append(fields[0])
    return result


def loaded_libraries(pid, prefix, forbidden):
    paths = set()
    for line in Path(f"/proc/{pid}/maps").read_text().splitlines():
        fields = line.split(None, 5)
        if len(fields) == 6 and fields[5].startswith("/"):
            paths.add(Path(fields[5]).resolve())
    for path in paths:
        if any(path.is_relative_to(root) for root in forbidden):
            raise LaunchFailure(f"Application loaded a build/developer dependency: {path}")
    runtime = [p for p in paths if p.name.startswith(("libSwitch2KitC", "libswift", "libFoundation",
                                                     "lib_Foundation", "libdispatch", "libBlocksRuntime"))]
    if not any(p.name == "libSwitch2KitC.so" for p in runtime) or not any(p.name == "libswiftCore.so" for p in runtime):
        raise LaunchFailure("The GUI did not load the real controller engine and Swift runtime")
    if any(not p.is_relative_to(prefix) for p in runtime):
        raise LaunchFailure(f"Runtime dependency outside extracted application: {runtime}")
    return sorted(str(p.relative_to(prefix)) for p in runtime)


def qualify(emulator, archive, report, forbidden):
    record = {"version": 1, "emulator": emulator, "archive_sha256": hashlib.sha256(archive.read_bytes()).hexdigest(),
              "tested_revision": os.environ.get("GITHUB_SHA"), "physical_controller_tested": False,
              "pristine_first_run_tested": False, "runs": [], "status": "failed"}
    report.parent.mkdir(parents=True, exist_ok=True)
    manager = None
    try:
        with tempfile.TemporaryDirectory(prefix="s2k extracted GUI ") as directory:
            root = Path(directory).resolve()
            env = environment(root)
            unpack = root / "unpacked"
            unpack.mkdir()
            with tarfile.open(archive) as package:
                package.extractall(unpack, filter="data")
            entries = list(unpack.iterdir())
            if len(entries) != 1 or not entries[0].is_dir():
                raise LaunchFailure("Expected one application prefix in the archive")
            prefix = entries[0]
            exe = prefix / "bin" / {"dolphin": "dolphin-emu", "cemu": "Cemu_release"}[emulator]
            if not exe.is_file() or not os.access(exe, os.X_OK):
                raise LaunchFailure("Missing executable or executable permission")
            for name in ("CREDITS.md", "LICENSES/MIT-trevlars.txt", "LICENSES/SDL-zlib.txt", "SwiftRuntime/LICENSE.txt", "SwiftRuntime/ICU.txt"):
                path = prefix / "share/Switch2KitNotices" / name
                if not path.is_file() or not path.stat().st_size:
                    raise LaunchFailure(f"Missing distributed license/attribution: {name}")
            resource = prefix / ("bin/Sys/Profiles/GCPad/Switch2Kit GameCube.ini" if emulator == "dolphin" else "share/Cemu/resources")
            if not resource.exists() or not resource.resolve().is_relative_to(prefix):
                raise LaunchFailure("Packaged resources are missing or refer outside the extracted prefix")
            dependencies = command(["ldd", str(exe)], env)
            if "not found" in dependencies:
                raise LaunchFailure(dependencies)
            record["dependencies"] = dependencies
            profile = root / "user" if emulator == "dolphin" else root / "config/Cemu"
            profile.mkdir()
            record["startup_settings"] = seed_startup_settings(emulator, profile)
            arguments = [str(exe)] + (["--user", str(profile)] if emulator == "dolphin" else [])
            with (report.parent / "linux-window-manager.log").open("w") as log:
                manager = subprocess.Popen(["openbox", "--sm-disable"], env=env, stdout=log, stderr=subprocess.STDOUT)
                try:
                    for _ in range(50):
                        if manager.poll() is not None:
                            raise LaunchFailure("The isolated window manager exited")
                        probe = subprocess.run(["wmctrl", "-m"], env=env, capture_output=True, timeout=5)
                        if probe.returncode == 0:
                            break
                        time.sleep(0.1)
                    else:
                        raise LaunchFailure("No isolated X11 window manager")
                    for attempt in (1, 2):
                        with (report.parent / f"linux-gui-{attempt}.log").open("w") as output:
                            process = subprocess.Popen(arguments, env=env, cwd=root, stdout=output, stderr=subprocess.STDOUT)
                            observed = []
                            runtime = []
                            def inspect():
                                observed[:] = windows(process.pid, env)
                                if observed:
                                    runtime[:] = loaded_libraries(process.pid, prefix, forbidden)
                                return {"matched": bool(observed), "finished": bool(observed), "windows": len(observed)}
                            def close():
                                command(["wmctrl", "-ic", observed[0]], env)
                                return {"quit_requested": True}
                            result = supervise(process, inspect, close)
                            result.update(attempt=attempt, runtime_libraries=runtime)
                            record["runs"].append(result)
                            if result["status"] != "passed":
                                raise LaunchFailure(result["reason"])
                finally:
                    if manager.poll() is None:
                        manager.terminate()
                        manager.wait(timeout=10)
                    manager = None
            record["status"] = "passed"
    except (OSError, ValueError, subprocess.SubprocessError, tarfile.TarError, LaunchFailure) as error:
        record["reason"] = str(error)
        raise
    finally:
        report.write_text(json.dumps(record, indent=2) + "\n")
    print("PASS exact extracted archive: GUI window, packaged runtime, normal quit and relaunch; no hardware claim")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("emulator", choices=("dolphin", "cemu"))
    parser.add_argument("archive", type=Path)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--forbidden-root", type=Path, action="append", default=[])
    args = parser.parse_args()
    qualify(args.emulator, args.archive.resolve(strict=True), args.report.resolve(),
            [p.resolve() for p in args.forbidden_root])
