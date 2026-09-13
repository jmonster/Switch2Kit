# Switch2Kit

A source Swift package for **in-process Nintendo Switch 2 controller input on macOS**. Import `Switch2Kit` to own discovery and connections, receive calibrated physical-controller snapshots, and request supported rumble and player LEDs. The Switch2Kit dashboard uses this library.


## Supported models and platforms

| Physical model | Sticks | Triggers | Rumble | Additional data |
| --- | --- | --- | --- | --- |
| Switch 2 Pro Controller (`0x2069`) | Left and right | Digital | HD rumble, two channels | Battery and raw motion |
| Joy-Con 2 left (`0x2067`) | Left | Digital | Single actuator | Battery, raw motion and optical counters |
| Joy-Con 2 right (`0x2066`) | Right | Digital | Single actuator | Battery, raw motion and optical counters |
| NSO GameCube (`0x2073`) | Left and right | Independent analog travel and digital clicks | Soft/strong firmware clips | Battery and raw motion |

Switch 1 controllers and arbitrary HID devices are not admitted. Nintendo company ID, vendor ID and supported product ID must all validate; names alone never authorize a connection. Joy-Con pairs remain two physical controllers.

The declared deployment minimum is **macOS 15**. Build source with **Swift 6.2 or newer**; the repository's Apple-SDK builds and framework wrapper use **Xcode 26 or newer**. The app's optional CoreHID output has separate availability/entitlement requirements that do not apply to this library.

## Install the source package

For local development, add the repository to your host's `Package.swift`:

```swift
// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "MyControllerApp",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "../Switch2Kit")],
    targets: [.executableTarget(name: "MyControllerApp", dependencies: [
        .product(name: "Switch2Kit", package: "Switch2Kit")
    ])]
)
```

For Git integration, replace the path dependency with:

```swift
.package(url: "https://github.com/jmonster/Switch2Kit.git",
         branch: "main")
```

In Xcode, use **File → Add Package Dependencies**, enter the repository URL, and add the **Switch2Kit** product to your host target. Use `revision:` instead of `branch:` to pin a specific commit.

## Configure the host application

In the **host's** Info.plist, provide a clear reason:

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>Connect Nintendo controllers to navigate and interact with this application.</string>
```

A sandboxed host supplies its own Bluetooth capability where required:

```xml
<key>com.apple.security.device.bluetooth</key>
<true/>
```

Do not copy the dashboard's identity or restricted entitlements. Switch2Kit carries no entitlements, provisioning profile, updater, login registration or signing identity. The host must show useful Bluetooth-off/permission-denied UI, decide whether support continues while inactive, and own any input mappings. A command-line Swift executable is not a substitute for a correctly configured application bundle when validating privacy prompts.

Apple references: [Bluetooth usage description](https://developer.apple.com/documentation/bundleresources/information-property-list/nsbluetoothalwaysusagedescription) and [sandbox Bluetooth entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.bluetooth).

## Minimal discovery and input

Create a manager once on the main actor. Register and **retain** an observation before starting. This host object uses the main queue so its actor assertion is justified:

```swift
import Foundation
import Switch2Kit

@MainActor
final class ControllerInput {
    let manager = Switch2ControllerManager()
    private var observation: Switch2ControllerObservation?
    private(set) var buttons: Switch2Buttons = []

    func start() throws {
        if observation == nil {
            observation = try manager.observe(on: .main, bufferingNewest: 256) { [weak self] event in
                MainActor.assumeIsolated { self?.receive(event) }
            }
        }
        manager.start()
        try manager.discover(for: 60)
    }

    private func receive(_ event: Switch2ControllerEvent) {
        switch event {
        case .input(let controller): buttons = controller.state.buttons
        case .disconnected: buttons = []
        case .snapshot: buttons = [] // Neutralize cached navigation after overflow.
        default: break
        }
    }

    func stop() async {
        observation?.cancel()
        observation = nil
        buttons = []
        await manager.stop()
    }
}
```

This minimal example tracks the most recent controller's buttons; a multiplayer host should retain state **by physical ID**, as the complete demo does. An initial or overflow `.snapshot` is authoritative: reconcile its ready-controller set rather than assuming every intermediate event was retained. A slow consumer never gets an unbounded history.

The default policy is on-demand. `start()` initializes support but does not scan indefinitely. `discover(for:)` opens or replaces a 0.1–300 second window. Hold the controller's **Sync** button until it advertises. Existing sessions continue after scanning stops. See the [lifecycle guide](bluetooth-lifecycle.md) before implementing remembered-device behavior.

## Minimal rumble

Use a ready controller's ID and capabilities, not an application player index:

```swift
func acknowledge(_ controller: Switch2Controller, using manager: Switch2ControllerManager) throws {
    guard controller.capabilities.contains(.rumble) else { return }
    try manager.playRumble(for: controller.id, intensity: 0.4)
}
```

`playRumble` works on every supported model. Pro/Joy-Con play a 400 ms HD pulse; GameCube plays its soft firmware clip below intensity 0.5 or strong clip at 0.5 and above. Zero is mute. The device controls GameCube clip duration; a submitted clip cannot be cancelled.

For amplitude-controlled effects, check `.continuousRumble` and use `setRumble` or `pulseRumble`. Pro strong/weak channels address left/right actuators; Joy-Con mixes them into one actuator. Pulses accept `0.01...0.5` seconds. Continuous intent expires after 500 ms unless renewed; zero stops it. See [rumble](../rumble.md).

## Run the independent sample

```sh
bash scripts/build-switch2kit-demo.sh
open build/Switch2KitDemo.app
```

Quit other processes that could own the same controller. The demo displays Bluetooth/discovery state, ready models, buttons, both sticks where available, independent trigger travel/clicks and battery. It provides a 60-second discovery window, disconnect and short rumble. Its grid demonstrates local keyboard, native GameController.framework and Switch2Kit adapters feeding one semantic router, without global event posting or Accessibility permission.

## Non-goals

Switch2Kit does **not** make its devices appear as system `GCController` instances, install a controller driver, create virtual HID devices, or give unrelated applications controller access. It does not post keyboard/mouse events, request Accessibility permission, map logical players, combine Joy-Cons, persist preferences, expose raw CoreBluetooth objects, create files, implement network/browser/SDL outputs, or manage app identity/signing. Those remain host choices. The dashboard retains its existing adapters separately.

## Guides

[SwiftUI](swiftui.md) · [AppKit](appkit.md) · [Bluetooth lifecycle](bluetooth-lifecycle.md) · [Navigation](navigation.md) · [API](api.md) · [Concurrency and logging](concurrency-and-logging.md) · [Troubleshooting](troubleshooting.md) · [XCFramework](xcframework.md) · [Architecture](architecture.md)

