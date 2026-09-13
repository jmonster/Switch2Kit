#!/usr/bin/env python3
"""Apply a pinned emulator integration to a clean source checkout."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

HERE = Path(__file__).resolve().parent


def run(source: Path, *args: str) -> str:
    return subprocess.check_output(["git", "-C", str(source), *args], text=True).strip()


def check_files(source: Path, files: dict, phase: str) -> None:
    for name, hashes in files.items():
        path = source / name
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != hashes[phase]:
            raise ValueError(f"Unexpected {phase} content: {name}. Use the pinned clean checkout.")


def main() -> None:
    revisions = json.loads((HERE / "revisions.json").read_text())
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("emulator", choices=sorted(revisions))
    parser.add_argument("source", type=Path)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true", help="Check without changing files")
    mode.add_argument("--verify", action="store_true", help="Verify an already applied integration")
    args = parser.parse_args()
    source = args.source.resolve()
    spec = revisions[args.emulator]
    if run(source, "rev-parse", "HEAD") != spec["revision"]:
        raise ValueError(f"Expected {spec['repository']} at {spec['revision']}")
    if args.verify:
        check_files(source, spec["files"], "after")
        print(f"Verified {args.emulator} integration")
        return
    if run(source, "status", "--porcelain", "--untracked-files=normal"):
        raise ValueError("Checkout contains changes or untracked files. No files were changed.")
    check_files(source, spec["files"], "before")
    patch = HERE / f"{args.emulator}.patch"
    run(source, "apply", "--check", str(patch))
    if not args.check:
        run(source, "apply", str(patch))
        check_files(source, spec["files"], "after")
    print(f"{'Checked' if args.check else 'Applied'} {args.emulator} integration")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
