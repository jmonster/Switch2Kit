from pathlib import Path
import plistlib
import re

root = Path(__file__).resolve().parents[2]
info = plistlib.loads((root / "Resources/Info.plist").read_bytes())
assert info["CFBundleName"] == info["CFBundleDisplayName"] == "Switch2Kit"
assert info["CFBundleExecutable"] == "Switch2KitApp"
assert info["CFBundleIdentifier"] == "wabisabi.ware.gamecubed"
manifest = (root / "Package.swift").read_text()
assert 'dependencies: ["Switch2Kit"]' in manifest
assert (root / "Sources/Switch2KitApp/ControllerTools").is_dir()
assert not list((root / "sdl").glob("*.dylib"))
for source in (root / "Sources/Switch2Kit").rglob("*.swift"):
    assert "ControllerTools" not in source.read_text()
assert set(re.findall(r'\.executable\(name: "([^\"]+)"', manifest)) == {"Switch2KitApp", "Switch2KitDemo"}
assert (root / "Sources/Switch2KitApp/Switch2KitApp.swift").is_file()
print("PASS Switch2Kit application identity, source-only dependencies and repository organization")
