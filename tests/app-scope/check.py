"""Guard the app-control product boundary without opening Bluetooth or UI."""
from pathlib import Path

root = Path(__file__).resolve().parents[2]
app = root / "Sources/Switch2KitApp"
for name in ("ReactionGame.swift", "ChallengeGames.swift"):
    assert not (app / "UI" / name).exists(), f"Embedded game returned: {name}"

removed = ("ReactionGame", "ReactionGameView", "ChallengeCoordinator", "ChallengeView",
           '"reaction-game"', '"challenges"')
for path in app.rglob("*.swift"):
    source = path.read_text()
    for symbol in removed:
        assert symbol not in source, f"Stale game dependency {symbol}: {path}"

# Games are removed, not the product's controller-to-app adapters.
for name in ("GestureRecognizer.swift", "KeyboardMapper.swift", "MouseController.swift"):
    assert (app / "Output" / name).is_file(), f"App-control adapter missing: {name}"
# Public promotion may remove the example-only module; the demo must still use routing.
demo = (root / "Examples/Switch2KitDemo/DemoModel.swift").read_text()
routers = (("Examples/NavigationSupport/NavigationRouter.swift", "NavigationRouter"),
           ("Sources/Switch2Kit/Public/ActionRouting.swift", "Switch2ActionRouter"))
assert any((root / path).is_file() and symbol in demo for path, symbol in routers), "Demo action router missing"
assert "router.receive(" in demo and "router.tick(" in demo, "Demo does not consume routed input"
print("Application scope checks passed")
