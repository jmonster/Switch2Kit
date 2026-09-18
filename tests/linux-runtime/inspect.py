#!/usr/bin/env python3
"""Inspect a trusted, locally built Linux host and its installed facade."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

from verify import require, run, tags


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("executable", type=Path)
    parser.add_argument("prefix", type=Path)
    args = parser.parse_args()
    executable = args.executable.resolve(strict=True)
    prefix = args.prefix.resolve(strict=True)
    require(executable.is_relative_to(prefix), "Executable must be inside the installed prefix")
    needed = [value for value in tags(executable, "NEEDED") if "Switch2KitC" in value]
    require(needed == ["libSwitch2KitC.so"], f"Unexpected facade DT_NEEDED: {needed}")
    swift = shutil.which("swift")
    require(swift is not None, "Swift is required to identify the runtime deployment paths")
    assert swift is not None
    info = json.loads(run([swift, "-print-target-info"]))
    runtime_paths = info["paths"]["runtimeLibraryPaths"]
    env = {"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C",
           "LD_LIBRARY_PATH": os.pathsep.join(runtime_paths)}
    linked = run(["ldd", str(executable)], env=env)
    print(linked, end="")
    require("not found" not in linked, "Installed executable has unresolved dependencies")
    paths = re.findall(r"^\s*libSwitch2KitC\.so\s+=>\s+(.+?)\s+\(0x[0-9a-f]+\)",
                       linked, flags=re.MULTILINE)
    require(len(paths) == 1, "Expected exactly one loaded Switch2Kit facade")
    facade = Path(paths[0]).resolve(strict=True)
    require(facade.is_relative_to(prefix), f"Facade is outside installed prefix: {facade}")
    require(tags(facade, "SONAME") == ["libSwitch2KitC.so"], "Incorrect installed facade SONAME")
    print(f"PASS: {executable} resolves installed facade {facade}")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.TimeoutExpired, OSError, KeyError, ValueError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
