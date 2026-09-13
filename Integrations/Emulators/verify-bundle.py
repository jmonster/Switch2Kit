#!/usr/bin/env python3
"""Inspect the built emulator's native integration, without opening Bluetooth."""
import json
from pathlib import Path
import plistlib
import subprocess
import sys

emulator, source, build = sys.argv[1], Path(sys.argv[2]).resolve(), Path(sys.argv[3]).resolve()
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
for path in (exe, lib):
    subprocess.run(["file", str(path)], check=True)
    subprocess.run(["xcrun", "lipo", "-verify_arch", subprocess.check_output(["uname", "-m"], text=True).strip(), str(path)], check=True)
links = subprocess.check_output(["xcrun", "otool", "-L", str(exe)], text=True)
print(links, flush=True)
assert "libSwitch2KitC.dylib" in links, "App is not linked to the C facade"
assert "CoreHID" not in subprocess.check_output(["xcrun", "otool", "-L", str(lib)], text=True)
subprocess.run(["plutil", "-lint", str(app / "Contents/Info.plist")], check=True)
commands = json.loads((build / "compile_commands.json").read_text())
required = ("SDL.cpp", "SDLGamepad.cpp", "ControllersPane.cpp") if emulator == "dolphin" else ("SDLControllerProvider.cpp", "SDLController.cpp", "ControllerFactory.cpp", "InputAPIAddWindow.cpp")
for filename in required:
    assert any(Path(row["file"]).name == filename and "HAVE_SWITCH2KIT" in row["command"] for row in commands), f"Missing enabled integration: {filename}"
subprocess.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(build / "integration-app.zip")], check=True)
print(f"PASS {emulator}: full app, host permissions, native linkage, embedded library and enabled source hooks")
