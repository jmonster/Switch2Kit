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
    env = {"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"}
    linked = run(["ldd", str(executable)], env=env)
    print(linked, end="")
    require("not found" not in linked, "Installed executable has unresolved dependencies")
    paths = re.findall(r"^\s*libSwitch2KitC\.so\s+=>\s+(.+?)\s+\(0x[0-9a-f]+\)",
                       linked, flags=re.MULTILINE)
    require(len(paths) == 1, "Expected exactly one loaded Switch2Kit facade")
    facade = Path(paths[0]).resolve(strict=True)
    require(facade.is_relative_to(prefix), f"Facade is outside installed prefix: {facade}")
    require(tags(facade, "SONAME") == ["libSwitch2KitC.so"], "Incorrect installed facade SONAME")
    for name, path in re.findall(r"^\s*(\S+)\s+=>\s+(.+?)\s+\(0x[0-9a-f]+\)", linked, flags=re.MULTILINE):
        if name.startswith(("libswift", "libFoundation", "lib_Foundation", "libdispatch", "libBlocksRuntime")):
            require(Path(path).resolve(strict=True).is_relative_to(prefix),
                    f"Swift runtime dependency escapes installed prefix: {name}: {path}")
    require(tags(facade, "RUNPATH") == ["$ORIGIN"], "Facade runtime search path is not relocatable")
    print(f"PASS: {executable} resolves installed facade {facade}")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.TimeoutExpired, OSError, KeyError, ValueError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
