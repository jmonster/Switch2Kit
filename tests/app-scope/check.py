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
assert (root / "Examples/NavigationSupport/NavigationRouter.swift").is_file()
print("Application scope checks passed")
