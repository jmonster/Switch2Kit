"""The application must not reinstate research tools or session companions."""
from pathlib import Path
root = Path(__file__).resolve().parents[2]
assert not list((root / "Sources/Switch2KitApp/Tools").glob("*.swift"))
for path in (root / "Sources").rglob("*.swift"):
    source = path.read_text()
    for name in ("ControllerTool", "ControllerCapture", "ControllerSessionCompanion",
                 "installCompanion", "attachCompanion", "nfcTagReadNotification"):
        assert name not in source, f"Removed research dependency {name}: {path}"
engine = (root / "Sources/Switch2KitApp/Bluetooth/BridgeEngine.swift").read_text()
assert "setSensorProfile(ApplicationSensorPolicy.selectedProfile)" in engine
assert engine.index("setSensorProfile(") < engine.index("controllerManager.start()")
print("PASS research boundary; sensor configuration remains before controller startup")
