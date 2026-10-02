# iOS package integration

The `Switch2Kit` library product can be imported directly by iOS/iPadOS 18+
applications built with Swift 6.2 or newer. No replacement manifest, copied
sources, SDL adapter, or macOS application target is required. Add this
repository as a Swift package dependency and select its `Switch2Kit` product.
Apple-SDK builds use Xcode 26 or newer. This is **experimental,
compile-supported integration**, not physical pairing/gameplay qualification.

## Configure the host app

1. Set the iOS application target's deployment minimum to **iOS 18** or newer.
2. In Xcode, use **File → Add Package Dependencies**, add
   `https://github.com/jmonster/Switch2Kit.git`, and select the **Switch2Kit**
   library product for that app target. Use a pinned revision for reproducible
   builds. See the [source package guide](README.md) for dependency declarations.
3. Add `NSBluetoothAlwaysUsageDescription` to the app's Info.plist, with a reason
   such as “Connect Nintendo controllers for input in this application.” The
   macOS `com.apple.security.device.bluetooth` sandbox entitlement is not an iOS
   setup step. Do not copy the dashboard's entitlements or signing identity.
4. Keep one main-actor-owned `Switch2ControllerManager` for the intended radio
   owner. Register and retain an observation before calling `start()` and
   `discover(for:)`; hold the controller's **Sync** button during discovery.
   Present Bluetooth permission/power states separately from the controller list.

The [minimal input example](README.md#minimal-discovery-and-input) uses the same
public API. [SwiftUI presentation](swiftui.md) is sampled; use a retained
observation for button edges and reconcile authoritative `.snapshot` events.
Switch2Kit does not register a system `GCController` or grant other apps input.

## Scene lifecycle and reconnection

The host owns foreground/background policy. When input becomes inactive, release
its held actions and cancel repeat timers immediately. For a foreground-only
host, cancel its input observation and call `await manager.stop()` as it leaves
active use. Serialize this teardown with later restarts; do not launch overlapping
stop/start tasks on every view appearance. On return, reinstall the observation,
start support, and open a fresh discovery window when the user requests it.
Coordinate at the application level when multiple scenes share one manager.

Importing the package does not configure background Bluetooth modes or state
restoration, and this integration does not promise background input or discovery.
See [the public API](api.md), [Bluetooth lifecycle](bluetooth-lifecycle.md), and
[delivery contract](concurrency-and-logging.md).

CoreBluetooth on iOS does not expose the local Bluetooth adapter address.
Address lookup therefore returns `nil`; the existing handshake skips the
address-dependent protocol bond rather than inventing one. Use explicit
`start()` / `discover(for:)` and the controller's Sync button. Automatic
button-wake reconnection is not promised. A successful compile or a ready session
does not establish that new bond material was written to the controller.

## Compile checks

From the repository root on macOS with Xcode installed:

```sh
xcodebuild -scheme Switch2Kit -destination 'generic/platform=iOS Simulator' -derivedDataPath build/ios-simulator CODE_SIGNING_ALLOWED=NO build
xcodebuild -scheme Switch2Kit -destination 'generic/platform=iOS' -derivedDataPath build/ios-device CODE_SIGNING_ALLOWED=NO build
```

The normal [macOS CI lane](../../.github/workflows/ci.yml) runs these actual
library builds for the iOS Simulator and device SDKs. These are unsigned compile
checks, not an installable iOS app, simulator Bluetooth tests, or proof of a
successful run for a particular revision. The [standalone demo](../../Examples/README.md)
and dashboard remain macOS applications; there is no bundled iOS sample app.

Physical acceptance requires an iOS host app on a real device. Record the device,
iOS version, controller model/firmware, source revision, Sync discovery, input,
rumble, disconnect/reconnect, permission handling and scene transitions. Do not
reuse desktop acceptance records as evidence for iOS.
