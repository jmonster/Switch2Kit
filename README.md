# Switch2Kit

Nintendo Switch 2 controllers for macOS. Use the Swift library in your own application, or run the Switch2Kit dashboard for controller setup and game output.

## Library

Requires macOS 15+, Swift 6.2+, and Xcode 26+.

```swift
.package(url: "https://github.com/jmonster/Switch2Kit.git", branch: "main")
```

Add `.product(name: "Switch2Kit", package: "Switch2Kit")` to your target dependencies. For a local checkout, use `.package(path: "/path/to/Switch2Kit")`.

```swift
import Switch2Kit

@MainActor
final class ControllerInput {
    let manager = Switch2ControllerManager()
    private var observation: Switch2ControllerObservation?

    func start() throws {
        observation = try manager.observe(on: .main) { event in
            if case .input(let controller) = event {
                print(controller.state.buttons)
            }
        }
        manager.start()
        try manager.discover(for: 60)
    }

    func stop() async {
        await manager.stop()
        observation?.cancel()
        observation = nil
    }
}
```

The host provides `NSBluetoothAlwaysUsageDescription` and, when sandboxed, `com.apple.security.device.bluetooth`. In-process input needs neither Accessibility permission nor CoreHID. Hold the controller's Sync button while discovery is active.

| Controller | Input | Rumble |
| --- | --- | --- |
| Switch 2 Pro Controller | Buttons, two sticks, motion, battery | Independent HD motors |
| Joy-Con 2, left or right | Buttons, stick, motion, optical sensor, battery | Single HD motor per unit |
| NSO GameCube | Buttons, two sticks, analog trigger travel and digital clicks, motion, battery | Soft/strong firmware clips |

[Library guide](docs/switch2kit/README.md) · [API](docs/switch2kit/api.md) · [SwiftUI](docs/switch2kit/swiftui.md) · [AppKit](docs/switch2kit/appkit.md) · [Bluetooth lifecycle](docs/switch2kit/bluetooth-lifecycle.md)

## C/C++ integration

Use the optional [C ABI and CMake integration](docs/switch2kit/cpp.md) for in-process emulator backends. It shares the Swift controller engine and does not require the dashboard.

## Dashboard

```sh
bash scripts/build-app.sh
open build/Switch2Kit.app
```

The dashboard displays live input and manages multiple controllers, Joy-Con pairs, player indicators, rumble, and mappings. Choose an output for the intended game: [SDL](sdl/README.md), [browser](browser/README.md), or [RetroArch](docs/retroarch-integration.md). Keyboard, mouse, gestures, and optional virtual HID are application features, not library dependencies.

[Setup](docs/quick-start.md) · [Rumble](docs/rumble.md) · [Application configuration](docs/app-identity.md) · [Troubleshooting](docs/switch2kit/troubleshooting.md)

## Examples and builds

```sh
swift build
swift test
bash tests/run.sh
bash scripts/build-switch2kit-demo.sh
bash scripts/verify-switch2kit-consumer.sh
```

The [standalone demo](Examples/README.md) shows live controller input and local semantic navigation. Swift consumers use SwiftPM source integration; the independent consumer check needs no prebuilt framework. The [distribution note](docs/switch2kit/xcframework.md) covers migration from the standalone Swift XCFramework. The optional C/C++ integration retains its native library build and validation.

[Architecture](docs/switch2kit/architecture.md) · [Protocol](docs/protocol.md) · [Contributors](CREDITS.md)
