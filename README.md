# Switch2Kit

**Use your Nintendo Switch Online GameCube controller, Nintendo Switch 2 Pro Controller, and Joy-Con 2 in apps and games.**

Switch2Kit provides controller support that any app can integrate on a supported platform. Our [Dolphin](https://github.com/jmonster/dolphin/blob/041a158aea44abb8b9625ce3359b8c231ad931da/Readme.md#quick-start) and [Cemu](https://github.com/jmonster/Cemu/blob/9a8a563c93791634bc2a5288fde885a25fbcddd4/README.md#quick-start) forks are maintained reference apps with Switch2Kit already built in: get the app, connect your controller, and play. You do not need to install or run Switch2Kit separately.

## Start playing

Choose the emulator for your games. The maintained forks embed Switch2Kit on **macOS 15+, Linux, and Windows x64**. Linux and Windows support is experimental; their setup guides identify the required runtime and Bluetooth dependencies.

| Your games | App with Switch2Kit built in | Get started |
| --- | --- | --- |
| GameCube and Wii | [Dolphin fork](https://github.com/jmonster/dolphin) | [Download, connect, and play](https://github.com/jmonster/dolphin/blob/041a158aea44abb8b9625ce3359b8c231ad931da/Readme.md#quick-start) |
| Wii U | [Cemu fork](https://github.com/jmonster/Cemu) | [Download, connect, and play](https://github.com/jmonster/Cemu/blob/9a8a563c93791634bc2a5288fde885a25fbcddd4/README.md#quick-start) |

The linked setup guides describe the reviewed desktop builds. While [Dolphin #5](https://github.com/jmonster/dolphin/pull/5) or [Cemu #3](https://github.com/jmonster/Cemu/pull/3) is unmerged, select application artifacts from `feature/switch2kit-desktop-platforms`; the forks’ default-branch READMEs may still describe older macOS-only builds. The guides include the exact artifact names, extraction paths, and source-build fallbacks.

1. **Get a controller-enabled app** from the linked fork's README. Use the platform-specific **Switch2Kit** GitHub Actions build linked in that README; downloading artifacts requires signing in to GitHub. Only successful runs with an application artifact provide a download. These are development builds, not published releases. Each README also includes build-and-launch instructions when a download is unavailable.
2. **Connect over Bluetooth.** Open **Controllers** in Dolphin or **Options > Input settings** in Cemu, click **Find Switch 2 Controllers**, allow Bluetooth access, and hold the controller's **Sync** button. Close other apps managing the same controller first.
3. **Select your controller and play.** For GameCube games in Dolphin, select the GameCube or Pro controller beside the desired GameCube port. In Cemu, select it beside **Emulated controller**. The forks apply the recommended button and stick mappings automatically. Their guides cover rumble, reconnecting, and controller-specific limitations; Wii Remote setup in Dolphin remains separate.

Use the linked **fork builds**, not the ordinary upstream downloads: these forks include the Switch2Kit integration. No separate dashboard or controller driver is needed. Individual Joy-Con 2 halves use the emulators' normal input configuration rather than the GameCube/Pro quick-setup dropdowns.

## Use it with other apps

Switch2Kit is not limited to Dolphin and Cemu. Apps can embed the same support directly, and the optional macOS [Switch2Kit dashboard](#dashboard) provides output paths for compatible [SDL3 games](sdl/README.md), [Chromium browser games](browser/README.md), and [RetroArch](docs/retroarch-integration.md).

For an app without built-in support, follow the [dashboard setup guide](docs/quick-start.md) and the instructions for its output path. Installing Switch2Kit alone does not make a controller appear in every app: it is not a universal system-wide controller driver.

## Supported controllers

| Controller | Controls | Rumble |
| --- | --- | --- |
| Nintendo Switch Online GameCube controller | Buttons, two sticks, analog L/R trigger travel and separate full-click buttons | On/off motor |
| Nintendo Switch 2 Pro Controller | Buttons and two sticks; ZL/ZR are digital, not analog GameCube triggers | Independent HD motors |
| Joy-Con 2, left or right | Buttons and one stick per half | Single HD motor per half |

This is support for the **wireless NSO GameCube controller**, not an original wired GameCube controller or USB adapter. Feature availability also depends on the app and its mappings. See [controller and feature coverage](docs/switch2kit/coverage.md) for battery, raw motion, Joy-Con optical counters, output details, and physical-testing limits.

## Platform support

| Platform | Current Switch2Kit support |
| --- | --- |
| macOS 15+ (Apple Silicon and Intel) | Live Bluetooth controller support, the maintained Dolphin/Cemu reference forks, Swift and C/C++ hosts, and the optional dashboard. |
| Linux / BlueZ (experimental) | Native Bluetooth controller engine, Swift/C/C++ hosts, and the maintained Dolphin/Cemu forks. [Requirements and setup](docs/switch2kit/linux.md). |
| Windows x64 / WinRT (experimental) | Native Bluetooth LE controller engine, Swift/C/C++ hosts, and the maintained Dolphin/Cemu forks. [Requirements and setup](docs/switch2kit/windows.md). |
| Android | No Switch2Kit controller backend. |

A controller-enabled build is required on every platform. The emulators' ordinary upstream builds do not include this integration. Automated tests cover native code and controlled transport boundaries; physical-controller pairing, reconnect, rumble, and gameplay qualification remain separate. The dashboard is macOS-only, but the controller engine is not.

## Developer integration

The sections below cover adding Switch2Kit to an app, building the optional dashboard, and working on the library. To use an existing controller-enabled emulator, start with [Start playing](#start-playing).

### C/C++ integration

Use the [C ABI and CMake integration](docs/switch2kit/cpp.md) to embed the same controller engine in a native host. The host does not need to be written in Swift and does not require the dashboard.

The maintained [Dolphin](https://github.com/jmonster/dolphin) and [Cemu](https://github.com/jmonster/Cemu) forks demonstrate complete app integrations. The separate [emulator integration guide](Integrations/Emulators/README.md) documents pinned source patches, builds, controller bindings, and motion-profile configuration for the SDK's reference integrations. Those patches and the maintained forks can differ in UI, supported platforms, and features; use each fork's README for its end-user setup.

The SDL3 integrations run in the emulator's existing input backend. The emulator owns discovery, Bluetooth permissions, and controller lifecycle; no network bridge, second SDL instance, or system virtual controller is required. Disabled builds retain the emulator's upstream platforms and deployment targets.

### Library

Requires Swift 6.2+. macOS hosts require macOS 15+ and Xcode 26+; Linux hosts use [BlueZ and the native Swift toolchain](docs/switch2kit/linux.md); Windows hosts use [WinRT and the x64 Swift toolchain](docs/switch2kit/windows.md).

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

Raw motion telemetry is available through the library. Calibrated SDL motion requires an explicitly selected [physical motion profile](docs/switch2kit/motion-profiles.md); no measured built-in profiles are supplied. NSO GameCube's soft/strong firmware feedback clips are separate from its on/off game rumble. See [controller and feature coverage](docs/switch2kit/coverage.md) for transport, output, and physical-qualification boundaries.

[Library guide](docs/switch2kit/README.md) · [API](docs/switch2kit/api.md) · [SwiftUI](docs/switch2kit/swiftui.md) · [AppKit](docs/switch2kit/appkit.md) · [Bluetooth lifecycle](docs/switch2kit/bluetooth-lifecycle.md) · [Application actions](docs/switch2kit/actions.md)

## Dashboard

The optional macOS dashboard displays live input and manages multiple controllers, Joy-Con pairs, player indicators, rumble, and mappings. It is not needed by the Dolphin and Cemu forks above.

### Build

With the macOS/Xcode requirements above installed, clone this repository and run:

```sh
git clone https://github.com/jmonster/Switch2Kit.git
cd Switch2Kit
bash scripts/build-app.sh
open build/Switch2Kit.app
```

Choose an output for the intended game: [SDL](sdl/README.md), [browser](browser/README.md), or [RetroArch](docs/retroarch-integration.md). Keyboard, mouse, gestures, and optional virtual HID are application features, not library dependencies. Follow the output-specific requirements rather than enabling every output.

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
