#!/usr/bin/env python3
"""Build the real facade and prove installed C++ hosts resolve its relocated copy."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile


def run(arguments: list[str], *, env: dict[str, str] | None = None,
        timeout: int = 180) -> str:
    result = subprocess.run(arguments, env=env, check=False, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            timeout=timeout)
    if result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}): {arguments}\n{result.stdout}")
    return result.stdout


def tags(binary: Path, tag: str) -> list[str]:
    dynamic = run(["readelf", "-d", str(binary)])
    return re.findall(r"\(" + re.escape(tag) + r"\).*?\[(.*?)\]", dynamic)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--libdir", default="lib",
                        help="Relative GNUInstallDirs library destination")
    args = parser.parse_args()
    if sys.platform != "linux":
        print("SKIP: Linux installed-runtime regression")
        return
    library_dir = Path(args.libdir)
    require(not library_dir.is_absolute() and ".." not in library_dir.parts,
            "--libdir must be a relative installation directory without '..'")
    for program in ("cmake", "ninja", "swift", "readelf"):
        require(shutil.which(program) is not None, f"Missing prerequisite: {program}")
    source = Path(__file__).resolve().parent
    swift = shutil.which("swift")
    assert swift is not None
    info = json.loads(run([swift, "-print-target-info"]))
    runtime_paths = info["paths"]["runtimeLibraryPaths"]
    require(bool(runtime_paths) and all(Path(p).is_absolute() for p in runtime_paths),
            "Swift did not identify its runtime library paths")
    # Keep Swift runtime deployment explicit; never inherit a build-tree library
    # path or injected preload from the developer's shell.
    runtime_env = {"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C",
                   "LD_LIBRARY_PATH": os.pathsep.join(runtime_paths)}
    with tempfile.TemporaryDirectory(prefix="Switch2Kit loader ") as temporary:
        root = Path(temporary)
        build = root / "build"
        install = root / "installed"
        relocated = root / "relocated prefix"
        run(["cmake", "-S", str(source), "-B", str(build), "-G", "Ninja",
             "-DCMAKE_BUILD_TYPE=Release", f"-DCMAKE_INSTALL_PREFIX={install}",
             "-DCMAKE_INSTALL_BINDIR=bin", f"-DCMAKE_INSTALL_LIBDIR={library_dir}",
             "-DCMAKE_INSTALL_DATADIR=share"])
        run(["cmake", "--build", str(build), "--parallel", "2"], timeout=300)
        run(["cmake", "--install", str(build)])
        facade = install / library_dir / "libSwitch2KitC.so"
        soname = tags(facade, "SONAME")
        require(soname == ["libSwitch2KitC.so"],
                f"The actual Swift facade must have SONAME libSwitch2KitC.so, got {soname}")
        for name in ("imported_consumer", "absolute_consumer"):
            needed = [value for value in tags(install / "bin" / name, "NEEDED")
                      if "Switch2KitC" in value]
            require(needed == ["libSwitch2KitC.so"],
                    f"{name}: unexpected facade DT_NEEDED: {needed}")
        install.rename(relocated)
        # Remove the exact original build location before running either host.
        # All modifications are within this test's private temporary directory.
        build.rename(root / "unavailable original build")
        facade = relocated / library_dir / "libSwitch2KitC.so"
        for name in ("imported_consumer", "absolute_consumer"):
            loaded = run([str(relocated / "bin" / name)], env=runtime_env).strip()
            require(loaded == str(facade.resolve()),
                    f"{name} loaded {loaded!r}, not the installed facade")
            run([sys.executable, str(source / "inspect.py"),
                 str(relocated / "bin" / name), str(relocated)])
        require((relocated / "share/Switch2KitNotices/CREDITS.md").is_file(),
                "Installed source attribution is missing")
        require((relocated / "share/Switch2KitNotices/LICENSES/README.md").is_file(),
                "Installed third-party notices are missing")
        hidden = facade.with_suffix(".unavailable")
        facade.rename(hidden)
        try:
            for name in ("imported_consumer", "absolute_consumer"):
                result = subprocess.run([str(relocated / "bin" / name)], env=runtime_env,
                                        text=True, stdout=subprocess.PIPE,
                                        stderr=subprocess.STDOUT, timeout=10)
                require(result.returncode != 0 and "libSwitch2KitC.so" in result.stdout,
                        f"{name}: missing-library negative control did not fail at the loader")
        finally:
            hidden.rename(facade)
        print(f"PASS: {library_dir}; two real C++ consumers, relocated facade, "
              "unavailable build tree, and two missing-library negative controls")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.TimeoutExpired, OSError, KeyError, ValueError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
