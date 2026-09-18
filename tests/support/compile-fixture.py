"""Compile a test-only Swift module with the built library's package identity.

SwiftPM derives -package-name from the checkout identity, not Package.name.
Use its actual build description rather than duplicating its name mangling.
Nothing from this helper or the fixtures is linked into the distributed library.
"""
import argparse
import json
from pathlib import Path
import subprocess
import sys


def package_name(description):
    commands = description.get("swiftCommands")
    if not isinstance(commands, dict):
        raise ValueError("SwiftPM build description has no swiftCommands map")
    names = {}
    for command in commands.values():
        if not isinstance(command, dict):
            continue
        module = command.get("moduleName")
        if module not in ("Switch2Kit", "Switch2KitC"):
            continue
        arguments = command.get("otherArguments", [])
        if not isinstance(arguments, list) or arguments.count("-package-name") != 1:
            raise ValueError(f"{module}: expected one -package-name in SwiftPM arguments")
        index = arguments.index("-package-name") + 1
        name = arguments[index] if index < len(arguments) else None
        if not isinstance(name, str) or not name or name.startswith("-"):
            raise ValueError(f"{module}: missing SwiftPM package name")
        if module in names and names[module] != name:
            raise ValueError(f"{module}: conflicting SwiftPM package names")
        names[module] = name
    if set(names) != {"Switch2Kit", "Switch2KitC"} or len(set(names.values())) != 1:
        raise ValueError("Build Switch2Kit and Switch2KitC with the same SwiftPM package identity first")
    return names["Switch2Kit"]


def clang_modules(description):
    """Carry SwiftPM's Clang module maps into the separately built fixture.

    The library's Linux radio target is a private transitive Clang module. Its
    map uses absolute header paths, so no production SDK flags or arbitrary
    compiler options need to be copied into the fixture invocation.
    """
    maps = set()
    for command in description.get("swiftCommands", {}).values():
        if not isinstance(command, dict) or command.get("moduleName") not in ("Switch2Kit", "Switch2KitC"):
            continue
        arguments = command.get("otherArguments", [])
        for index, argument in enumerate(arguments):
            if index and arguments[index - 1] == "-Xcc" and isinstance(argument, str) and argument.startswith("-fmodule-map-file="):
                maps.add(argument)
    return [item for module in sorted(maps) for item in ("-Xcc", module)]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--description", type=Path, required=True)
    parser.add_argument("--compiler", required=True)
    parser.add_argument("arguments", nargs=argparse.REMAINDER)
    options = parser.parse_args(argv)
    arguments = options.arguments
    if arguments[:1] == ["--"]:
        arguments = arguments[1:]
    try:
        if "-package-name" in arguments:
            raise ValueError("Fixture arguments must not override SwiftPM's package identity")
        description = json.loads(options.description.read_text())
        name = package_name(description)
        return subprocess.run([options.compiler, "-package-name", name, *clang_modules(description), *arguments], check=False).returncode
    except (OSError, ValueError, AttributeError) as error:
        print(f"Cannot compile Swift fixture: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
