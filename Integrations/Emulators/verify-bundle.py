#!/usr/bin/env python3
"""Inspect the built emulator's native integration, without opening Bluetooth."""
import argparse
import json
from pathlib import Path
import plistlib
import subprocess

def dependencies(output):
    """Read only otool's indented load entries, never its filename headers."""
    return {line.strip().split(" (compatibility version", 1)[0]
            for line in output.splitlines() if line.startswith(("\t", " "))}


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
assert float(plist.get("LSMinimumSystemVersion", "0")) >= 15, "Incorrect enabled-backend minimum"
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
    binaries.append({"path": str(path.relative_to(app)), "architectures": architectures})
links = subprocess.check_output(["xcrun", "otool", "-L", str(exe)], text=True)
print(links, flush=True)
sdk_links = {"@rpath/libSwitch2KitC.dylib", "@executable_path/../Frameworks/libSwitch2KitC.dylib"}
assert dependencies(links) & sdk_links, "App is not linked to the bundled C facade"
native_links = dependencies(subprocess.check_output(["xcrun", "otool", "-L", str(lib)], text=True))
assert not any("CoreHID.framework" in link for link in native_links), "C facade links CoreHID"
subprocess.run(["plutil", "-lint", str(app / "Contents/Info.plist")], check=True)
commands = json.loads((build / "compile_commands.json").read_text())
required = ("SDL.cpp", "SDLGamepad.cpp", "ControllersPane.cpp") if emulator == "dolphin" else ("SDLControllerProvider.cpp", "SDLController.cpp", "ControllerFactory.cpp", "InputAPIAddWindow.cpp")
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
