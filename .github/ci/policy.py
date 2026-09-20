"""Conservative PR change selection and an always-reporting, fail-closed gate."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
from typing import Any, Iterable

NATIVE_JOBS = ("macos", "linux", "windows")
DOC_FILES = frozenset({"README.md", "CONTRIBUTING.md", "CHANGELOG.md", ".github/CI.md", "LICENSES/README.md"})
DOC_ROOTS = frozenset({"docs", "Examples", "sdl", "browser"})


def documentation_only(path: str) -> bool:
    """Allow only known prose locations, never arbitrary *.md build/test inputs."""
    p = PurePosixPath(path)
    if not path or p.is_absolute() or ".." in p.parts:
        return False
    return path in DOC_FILES or (
        len(p.parts) > 1 and p.parts[0] in DOC_ROOTS and p.suffix == ".md"
    )


def requires_native(paths: Iterable[str]) -> bool:
    changed = tuple(paths)
    # Missing/empty evidence is not permission to skip tests.
    return not changed or any(not documentation_only(p) for p in changed)


def changed_paths(base: str, head: str, root: Path = Path("."), *, pr_diff: bool = True) -> list[str]:
    """Use the whole PR's merge-base diff, without API pagination/300-file limits."""
    if not all(re.fullmatch(r"[0-9a-fA-F]{40}", ref) for ref in (base, head)):
        raise ValueError("Expected immutable base and head commit SHAs")
    start = base
    if pr_diff:
        start = subprocess.check_output(
            ["git", "merge-base", base, head], cwd=root, timeout=20
        ).decode("ascii").strip()
    data = subprocess.check_output(
        # Treat renames as delete+add: moving source into a docs path must not skip CI.
        ["git", "diff", "--name-only", "--no-renames", "-z", start, head, "--"],
        cwd=root, timeout=20,
    )
    return [p.decode("utf-8", errors="surrogateescape") for p in data.split(b"\0") if p]


def plan(event: str, base: str, head: str, root: Path = Path(".")) -> bool:
    # Manual and merge-queue runs always execute all native lanes.
    if event not in ("pull_request", "push"):
        return True
    try:
        return requires_native(changed_paths(base, head, root, pr_diff=event == "pull_request"))
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        print(f"Cannot establish a docs-only change ({type(exc).__name__}); running native checks.")
        return True


def gate_ok(needs: Any) -> bool:
    if not isinstance(needs, dict):
        return False
    preflight = needs.get("preflight", {})
    if not isinstance(preflight, dict) or preflight.get("result") != "success":
        return False
    outputs = preflight.get("outputs", {})
    if not isinstance(outputs, dict) or outputs.get("native") not in ("true", "false"):
        return False
    expected = "success" if outputs["native"] == "true" else "skipped"
    return all(
        isinstance(needs.get(job), dict) and needs[job].get("result") == expected
        for job in NATIVE_JOBS
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("plan", "gate"))
    args = parser.parse_args()
    if args.command == "plan":
        native = plan(os.getenv("EVENT_NAME", ""), os.getenv("BASE_SHA", ""), os.getenv("HEAD_SHA", ""))
        output = f"native={str(native).lower()}\n"
        if os.getenv("GITHUB_OUTPUT"):
            with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as target:
                target.write(output)
        print(output, end="")
        return 0
    try:
        passed = gate_ok(json.loads(os.environ["NEEDS_JSON"]))
    except (KeyError, ValueError):
        passed = False
    print("PASS CI gate" if passed else "FAIL CI gate: a required result is missing or unsuccessful")
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
