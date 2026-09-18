#!/usr/bin/env python3
"""Execute archived native consumers with only packaged DLLs and Windows prerequisites."""
from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import zipfile

CONSUMERS = ("c/c-consumer.exe", "sdl/sdl-inprocess.exe", "sdl/sdl-motion.exe")
NOTICES = ("LICENSES/MIT-trevlars.txt", "LICENSES/SDL-zlib.txt",
           "SwiftRuntime/LICENSE.txt", "SwiftRuntime/ICU.txt")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def stage(build: Path, destination: Path, executable_names: tuple[str, ...]) -> None:
    require(build.is_dir(), f"Build directory does not exist: {build}")
    destination.mkdir()
    for name in (*executable_names, "Switch2KitC.dll", "swiftCore.dll"):
        require((build / name).is_file(), f"Missing packaged consumer dependency: {build / name}")
    for path in build.iterdir():
        if path.suffix.lower() in (".exe", ".dll"):
            require(path.is_file() and not path.is_symlink(), f"Not a regular binary: {path}")
            shutil.copy2(path, destination / path.name)
    notices = build / "Switch2KitNotices"
    for name in NOTICES:
        path = notices / name
        require(path.is_file() and path.stat().st_size > 0, f"Missing or empty license: {path}")
    require(not notices.is_symlink() and all(not path.is_symlink() for path in notices.rglob("*")),
            "Package notices must not reference files outside the package")
    shutil.copytree(notices, destination / notices.name)


def child_environment(root: Path, inherited: dict[str, str]) -> dict[str, str]:
    # Do not inherit the compiler, loader overrides or real user configuration.
    windows = inherited.get("SystemRoot", inherited.get("SYSTEMROOT", ""))
    require(bool(windows) and (Path(windows) / "System32").is_dir(), "A valid Windows SystemRoot is required")
    home, temporary = root / "private profile", root / "private temporary files"
    home.mkdir()
    temporary.mkdir()
    roaming, local = home / "AppData/Roaming", home / "AppData/Local"
    roaming.mkdir(parents=True)
    local.mkdir(parents=True)
    return {"SystemRoot": windows, "WINDIR": windows,
            "PATH": str(Path(windows) / "System32") + ";" + windows,
            "COMSPEC": str(Path(windows) / "System32/cmd.exe"),
            "USERPROFILE": str(home), "HOME": str(home),
            "APPDATA": str(roaming), "LOCALAPPDATA": str(local),
            "TEMP": str(temporary), "TMP": str(temporary)}


def execute(executable: Path, environment: dict[str, str], timeout: float = 30.0) -> dict:
    # No command shell or string quoting: paths containing spaces stay one argument.
    process = subprocess.Popen([str(executable)], cwd=executable.parent, env=environment,
                               stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                               encoding="utf-8", errors="replace")
    try:
        output, _ = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        process.kill()
        output, _ = process.communicate()
        raise RuntimeError(f"Consumer timed out: {executable}\n{output}")
    return {"executable": str(executable), "exit_code": process.returncode, "output": output}


def qualify(c_build: Path, sdl_build: Path, root: Path, report: dict) -> None:
    staged, extracted = root / "staged package", root / "extracted package"
    staged.mkdir()
    stage(c_build, staged / "c", ("c-consumer.exe",))
    stage(sdl_build, staged / "sdl", ("sdl-inprocess.exe", "sdl-motion.exe"))
    manifest = {path.relative_to(staged).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
                for path in staged.rglob("*") if path.is_file()}
    archive = root / "consumers.zip"
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as package:
        for name in manifest:
            package.write(staged / name, name)
    report["archive_sha256"] = hashlib.sha256(archive.read_bytes()).hexdigest()
    report["files"] = manifest
    shutil.rmtree(staged)
    # The archive was just created from regular files with relative paths above.
    with zipfile.ZipFile(archive) as package:
        package.extractall(extracted)
    for name, digest in manifest.items():
        require(hashlib.sha256((extracted / name).read_bytes()).hexdigest() == digest,
                f"Extracted file differs from the staged package: {name}")
    environment = child_environment(root, dict(os.environ))
    report["runs"] = []
    for relative in CONSUMERS:
        result = execute(extracted / relative, environment)
        report["runs"].append(result)
        require(result["exit_code"] == 0, f"Relocated consumer failed: {relative}\n{result}")
    # A system or developer copy must not rescue missing application-owned DLLs.
    # STATUS_DLL_NOT_FOUND is a loader failure, not an arbitrary assertion/crash.
    report["negative_controls"] = []
    for name in ("Switch2KitC.dll", "swiftCore.dll"):
        moved = []
        try:
            for directory in ("c", "sdl"):
                source = extracted / directory / name
                hidden = source.with_suffix(".unavailable")
                source.rename(hidden)
                moved.append((source, hidden))
            for relative in CONSUMERS:
                result = execute(extracted / relative, environment)
                report["negative_controls"].append({"removed": name, **result})
                require(result["exit_code"] & 0xffffffff == 0xc0000135,
                        f"Removing {name} must fail at the loader: {relative}\n{result}")
        finally:
            for source, hidden in moved:
                hidden.rename(source)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--c-build", type=Path, default=Path("build-c"))
    parser.add_argument("--sdl-build", type=Path, default=Path("build-sdl"))
    parser.add_argument("--report", type=Path, default=Path("windows-relocation.json"))
    args = parser.parse_args()
    report = {"status": "failed"}
    try:
        require(sys.platform == "win32", "This check executes native Windows consumers")
        # Loader negative controls must return an exit status rather than a modal
        # error dialog. This applies only to this test process and its children.
        ctypes.windll.kernel32.SetErrorMode(0x0001 | 0x0002 | 0x8000)
        with tempfile.TemporaryDirectory(prefix="Switch2Kit relocated consumers ") as temporary:
            qualify(args.c_build.resolve(strict=True), args.sdl_build.resolve(strict=True),
                    Path(temporary), report)
        report["status"] = "passed"
        print("PASS: extracted real C/SDL consumers, OS-only PATH, isolated profiles, and missing-DLL negative controls")
        return 0
    except (OSError, RuntimeError, zipfile.BadZipFile) as error:
        report["error"] = str(error)
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    finally:
        args.report.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    sys.exit(main())
