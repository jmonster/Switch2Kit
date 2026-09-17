# Switch2Kit

Nintendo Switch 2 controller support for applications and emulators. Embed the controller engine through Swift or C/C++, use the in-process SDL3 integrations for Dolphin and Cemu, or run the optional Switch2Kit dashboard for controller setup and game output.

**Live Bluetooth controller support currently requires macOS 15+.** Switch2Kit is not limited to Swift applications or the dashboard, but its live controller backend is not yet cross-platform.

## Platform support

| Platform | Current Switch2Kit support |
| --- | --- |
| macOS 15+ (Apple Silicon and Intel) | Live Bluetooth controller engine, Swift and C/C++ hosts, Dolphin/Cemu integrations, and dashboard. |
| Linux | Portable library components, C ABI, and synthetic integration tests. No live Bluetooth controller backend. |
| Windows and Android | No supported Switch2Kit controller backend or host build. |

Dolphin is [cross-platform](https://dolphin-emu.org/docs/faq/); its optional Switch2Kit backend requires macOS with SDL and Qt. Without CoreBluetooth, `s2k_create` reports `S2K_UNSUPPORTED_PLATFORM`. Additional platforms need their own Bluetooth transport and host integration.

## C/C++ integration

Embed the engine through the [C ABI and CMake integration](docs/switch2kit/cpp.md); no Swift host or dashboard is required.

```cmake
add_subdirectory(/path/to/Switch2Kit/Integrations/CMake switch2kit)
target_link_libraries(your_emulator PRIVATE Switch2Kit::C)
# For a macOS application bundle:
switch2kit_embed(your_emulator)
```

The [Dolphin and Cemu integrations](Integrations/Emulators/README.md) use each emulator's existing SDL3 input backend. The emulator owns discovery, Bluetooth permissions and controller lifecycle; no network bridge, second SDL instance or system virtual controller is required. These optional source integrations are maintained here, not included in unmodified upstream emulators. Disabled builds retain upstream platforms and deployment targets.

## Library

Requires macOS 15+, Swift 6.2+, and Xcode 26+.

Add `.package(url: "https://github.com/jmonster/Switch2Kit.git", branch: "main")` and `.product(name: "Switch2Kit", package: "Switch2Kit")` to your package and target dependencies. For a local checkout, use `.package(path: "/path/to/Switch2Kit")`.

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
| NSO GameCube | Buttons, two sticks, analog trigger travel and digital clicks, motion, battery | On/off motor; separate firmware clips |

[Library guide](docs/switch2kit/README.md) · [API](docs/switch2kit/api.md) · [SwiftUI](docs/switch2kit/swiftui.md) · [AppKit](docs/switch2kit/appkit.md) · [Bluetooth lifecycle](docs/switch2kit/bluetooth-lifecycle.md) · [Application actions](docs/switch2kit/actions.md)

## Dashboard

```sh
bash scripts/build-app.sh
open build/Switch2Kit.app
```

The dashboard displays live input and manages multiple controllers, Joy-Con pairs, player indicators, rumble, and mappings. Choose an output for the intended game: [SDL](sdl/README.md), [browser](browser/README.md), or [RetroArch](docs/retroarch-integration.md). Keyboard, mouse, gestures, and optional virtual HID are application features, not library dependencies.

[Setup](docs/quick-start.md) · [Rumble](docs/rumble.md) · [Application configuration](docs/app-identity.md) · [Troubleshooting](docs/switch2kit/troubleshooting.md)

## Examples and builds

Run package and regression checks, or build the macOS example and source consumer:

```sh
swift build
swift test
bash tests/run.sh
# macOS:
bash scripts/build-switch2kit-demo.sh
bash scripts/verify-switch2kit-consumer.sh
```

The [standalone demo](Examples/README.md) shows live input and semantic navigation. Swift consumers integrate through SwiftPM source; [native C/C++ packaging](docs/switch2kit/xcframework.md) remains available. Linux tests cover portable code and fixtures, not live Bluetooth.

[Architecture](docs/switch2kit/architecture.md) · [Protocol](docs/protocol.md) · [Contributors](CREDITS.md)
