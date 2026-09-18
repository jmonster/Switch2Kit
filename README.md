# Switch2Kit

Nintendo Switch 2 controller support for applications and emulators. Embed the controller engine through Swift or C/C++, use the in-process SDL3 integrations for Dolphin and Cemu, or run the optional Switch2Kit dashboard for controller setup and game output.

**Live Bluetooth backends: macOS 15+ and experimental Linux/BlueZ.** Swift and C/C++ hosts share the same controller engine; the dashboard is optional and remains macOS-only.

## Platform support

| Platform | Current Switch2Kit support |
| --- | --- |
| macOS 15+ (Apple Silicon and Intel) | Live Bluetooth controller engine, Swift and C/C++ hosts, Dolphin/Cemu integrations, and dashboard. |
| Linux / BlueZ (experimental) | Live Bluetooth backend, Swift and C/C++ hosts, and optional native SDL3/emulator integration. See [requirements and qualification limits](docs/switch2kit/linux.md). |
| Windows and Android | No supported Switch2Kit controller backend or host build. |

Dolphin itself is [cross-platform](https://dolphin-emu.org/docs/faq/). Switch2Kit's optional backend supports macOS through CoreBluetooth and Linux through BlueZ's native D-Bus GATT API. Linux reuses the existing session/protocol engine, not a dashboard bridge. Windows and Android still require their own transports and host integration. Automated Linux radio tests use an isolated synthetic BlueZ service; physical-controller and gameplay qualification remain separate.

## C/C++ integration

Use the [C ABI and CMake integration](docs/switch2kit/cpp.md) to embed the same controller engine in a native host. The host does not need to be written in Swift and does not require the dashboard.

The [Dolphin and Cemu integrations](Integrations/Emulators/README.md) connect Switch2Kit to each emulator's existing SDL3 input backend, in process. The emulator owns discovery, Bluetooth permissions, and controller lifecycle; no network bridge, second SDL instance, or system virtual controller is required. The guide covers pinned source patches, builds, controller bindings, and motion-profile configuration. These optional patches are maintained here, not supplied by unmodified upstream emulators; disabled builds retain upstream platforms and deployment targets.

## Library

Requires Swift 6.2+. macOS hosts require macOS 15+ and Xcode 26+; Linux hosts use [BlueZ and the native Swift toolchain](docs/switch2kit/linux.md).

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

On macOS, the host provides `NSBluetoothAlwaysUsageDescription` and, when sandboxed, `com.apple.security.device.bluetooth`. In-process input needs neither Accessibility permission nor CoreHID. Hold the controller's Sync button while discovery is active.

| Controller | Input | Rumble |
| --- | --- | --- |
| Switch 2 Pro Controller | Buttons, two sticks, raw motion, battery | Independent HD motors |
| Joy-Con 2, left or right | Buttons, stick, raw motion, optical counters, battery | Single HD motor per unit |
| NSO GameCube | Buttons, two sticks, analog trigger travel and digital clicks, raw motion, battery | On/off motor and soft/strong firmware clips |

Calibrated SDL motion requires an explicitly selected [physical motion profile](docs/switch2kit/motion-profiles.md); no measured built-in profiles are supplied. See [controller and feature coverage](docs/switch2kit/coverage.md) for transport, output and physical-qualification boundaries.

[Library guide](docs/switch2kit/README.md) · [API](docs/switch2kit/api.md) · [SwiftUI](docs/switch2kit/swiftui.md) · [AppKit](docs/switch2kit/appkit.md) · [Bluetooth lifecycle](docs/switch2kit/bluetooth-lifecycle.md) · [Application actions](docs/switch2kit/actions.md)

## Dashboard

```sh
bash scripts/build-app.sh
open build/Switch2Kit.app
```

The dashboard displays live input and manages multiple controllers, Joy-Con pairs, player indicators, rumble, and mappings. Choose an output for the intended game: [SDL](sdl/README.md), [browser](browser/README.md), or [RetroArch](docs/retroarch-integration.md). Keyboard, mouse, gestures, and optional virtual HID are application features, not library dependencies.

[Setup](docs/quick-start.md) · [Rumble](docs/rumble.md) · [Application configuration](docs/app-identity.md) · [Troubleshooting](docs/switch2kit/troubleshooting.md)

## Examples and builds

Package and regression checks (automated tests do not establish physical radio or gameplay acceptance):

```sh
swift build
swift test
bash tests/run.sh
# Linux radio integration tests:
bash tests/linux-bluez/run.sh
# macOS application and independent Swift consumer checks:
bash scripts/build-switch2kit-demo.sh
bash scripts/verify-switch2kit-consumer.sh
```

The [standalone demo](Examples/README.md) shows live controller input and local semantic navigation. Swift consumers use SwiftPM source integration; the independent consumer check needs no prebuilt framework. The [distribution note](docs/switch2kit/xcframework.md) covers migration from the standalone Swift XCFramework. The optional C/C++ integration retains its native library build and validation.

[Architecture](docs/switch2kit/architecture.md) · [Protocol](docs/protocol.md) · [Contributors](CREDITS.md)
