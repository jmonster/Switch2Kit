#!/usr/bin/env python3
"""Inspect the built emulator's native integration, without opening Bluetooth."""
import argparse
import json
from pathlib import Path
import plistlib
import re
import subprocess

def dependencies(output):
    """Read only otool's indented load entries, never its filename headers."""
    return {line.strip().split(" (compatibility version", 1)[0]
            for line in output.splitlines() if line.startswith(("\t", " "))}


def version_tuple(value):
    assert re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", value), "Invalid macOS version"
    parts = tuple(map(int, value.split(".")))
    return parts + (0,) * (3 - len(parts))


def load_metadata(output):
    """Parse actual load-command blocks, not paths or text from file headers."""
    versions, rpaths = [], []
    for block in re.split(r"(?m)^Load command [0-9]+\s*$", output):
        command = re.search(r"(?m)^\s*cmd (LC_[A-Z0-9_]+)\s*$", block)
        if not command:
            continue
        kind = command[1]
        if kind in ("LC_BUILD_VERSION", "LC_VERSION_MIN_MACOSX"):
            if kind == "LC_BUILD_VERSION":
                platform = re.search(r"(?m)^\s*platform (\S+)\s*$", block)
                assert platform and platform[1].lower() in ("1", "macos"), "Not a macOS binary"
            field = "minos" if kind == "LC_BUILD_VERSION" else "version"
            value = re.search(r"(?m)^\s*" + field + r" ([0-9.]+)\s*$", block)
            assert value, "Missing Mach-O deployment target"
            version_tuple(value[1])
            versions.append(value[1])
        elif kind == "LC_RPATH":
            value = re.search(r"(?m)^\s*path (.+) \(offset [0-9]+\)\s*$", block)
            assert value, "Malformed runtime search path"
            rpaths.append(value[1])
    assert versions, "Missing Mach-O macOS deployment target"
    return {"minimum_macos_versions": versions, "runtime_search_paths": sorted(set(rpaths))}


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("emulator", choices=("dolphin", "cemu"))
parser.add_argument("source", type=Path)
parser.add_argument("build", type=Path)
parser.add_argument("--architecture", choices=("arm64", "x86_64"))
options = parser.parse_args()
emulator, source, build = options.emulator, options.source.resolve(), options.build.resolve()
# A failed repeat inspection must not leave an earlier success record or archive.
for output in ("integration-inspection.json", "integration-app.zip"):
    (build / output).unlink(missing_ok=True)
candidates = list((build / "Binaries").glob("*.app")) if emulator == "dolphin" else list((source / "bin").glob("Cemu*.app"))
apps = [a for a in candidates if (a / "Contents/Frameworks/libSwitch2KitC.dylib").exists()]
assert len(apps) == 1, f"Expected one integrated app, got {apps}"
app = apps[0]
plist = plistlib.loads((app / "Contents/Info.plist").read_bytes())
assert plist.get("NSBluetoothAlwaysUsageDescription"), "Missing host Bluetooth description"
minimum = version_tuple(plist.get("LSMinimumSystemVersion", "0"))
assert minimum >= (15, 0, 0), "Incorrect enabled-backend minimum"
expected_id = "org.dolphin-emu.dolphin" if emulator == "dolphin" else "info.cemu.Cemu"
assert plist.get("CFBundleIdentifier") == expected_id, "Changed emulator bundle identifier"
exe = app / "Contents/MacOS" / plist["CFBundleExecutable"]
lib = app / "Contents/Frameworks/libSwitch2KitC.dylib"
# Resolve Mach-O inspection through the selected Xcode toolchain, not PATH.
# Preserve load commands and symbol bindings even when a check fails.
diag = build / "integration-native-diagnostics.txt"
with diag.open("w") as report:
    for path in (exe, lib):
        for arguments in (["xcrun", "otool", "-L", str(path)], ["xcrun", "otool", "-l", str(path)],
                          ["xcrun", "nm", "-m", str(path)]):
            result = subprocess.run(arguments, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            report.write("$ " + " ".join(arguments) + "\n" + result.stdout + "\n")
            report.flush()
host_architecture = subprocess.check_output(["uname", "-m"], text=True).strip()
architecture = options.architecture or host_architecture
assert architecture == host_architecture, "Native qualification requires a matching runner architecture"
binaries = []
for path in (exe, lib):
    subprocess.run(["file", str(path)], check=True)
    architectures = subprocess.check_output(["xcrun", "lipo", "-archs", str(path)], text=True).split()
    with diag.open("a") as report:
        report.write(f"$ xcrun lipo -archs {path}\n{' '.join(architectures)}\n")
    assert architecture in architectures, f"{path.name}: missing {architecture}; found {architectures}"
    metadata = load_metadata(subprocess.check_output(["xcrun", "otool", "-l", str(path)], text=True))
    assert all((15, 0, 0) <= version_tuple(v) <= minimum for v in metadata["minimum_macos_versions"]), \
        f"{path.name}: Mach-O deployment target disagrees with the host plist"
    if path == lib:
        assert all(not p.startswith("/") or any(p == root or p.startswith(root + "/")
                   for root in ("/usr/lib", "/System/Library"))
                   for p in metadata["runtime_search_paths"]), "C facade retains a build-machine runtime path"
    binaries.append({"path": str(path.relative_to(app)), "architectures": architectures, **metadata})
links = subprocess.check_output(["xcrun", "otool", "-L", str(exe)], text=True)
print(links, flush=True)
sdk_links = {"@rpath/libSwitch2KitC.dylib", "@executable_path/../Frameworks/libSwitch2KitC.dylib"}
assert dependencies(links) & sdk_links, "App is not linked to the bundled C facade"
native_links = dependencies(subprocess.check_output(["xcrun", "otool", "-L", str(lib)], text=True))
assert not any("CoreHID.framework" in link for link in native_links), "C facade links CoreHID"
assert not any("Switch2KitApp" in link for link in native_links), "C facade links the dashboard"
subprocess.run(["plutil", "-lint", str(app / "Contents/Info.plist")], check=True)
commands = json.loads((build / "compile_commands.json").read_text())
required = ("SDL.cpp", "SDLGamepad.cpp", "ControllersPane.cpp", "Dynamics.cpp", "WiimoteEmu.cpp") if emulator == "dolphin" else (
    "SDLControllerProvider.cpp", "SDLController.cpp", "ControllerFactory.cpp", "InputAPIAddWindow.cpp",
    "DefaultControllerSettings.cpp", "VPADController.cpp", "WPADController.cpp")
for filename in required:
    assert any(Path(row["file"]).name == filename and "HAVE_SWITCH2KIT" in row["command"] for row in commands), f"Missing enabled integration: {filename}"
subprocess.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(build / "integration-app.zip")], check=True)
(build / "integration-inspection.json").write_text(json.dumps({
    "version": 1,
    "emulator": emulator,
    "native_architecture": host_architecture,
    "binaries": binaries,
    "bundle_identifier": plist.get("CFBundleIdentifier"),
    "minimum_system_version": plist["LSMinimumSystemVersion"],
    "bluetooth_description_present": bool(plist["NSBluetoothAlwaysUsageDescription"]),
    "executable_dependencies": sorted(dependencies(links)),
    "sdk_dependencies": sorted(native_links),
}, indent=2) + "\n")
print(f"PASS {emulator} ({architecture}): full app, host permissions, native linkage, embedded library and enabled source hooks")
