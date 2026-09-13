# SwiftUI integration

## Own the manager above controller views

Create one main-actor-owned manager for the application's intended radio owner. `@StateObject` at the app or coordinator level provides stable lifetime. Pass that same instance to windows/rows as `@ObservedObject`; do not construct managers in `body`, one per row, or one per duplicate dashboard window.

```swift
import SwiftUI
import Switch2Kit

@main
struct MyApp: App {
    @StateObject private var manager = Switch2ControllerManager()
    var body: some Scene {
        WindowGroup { ControllersView(manager: manager) }
    }
}

struct ControllersView: View {
    @ObservedObject var manager: Switch2ControllerManager
    @State private var errorMessage: String?

    var body: some View {
        VStack {
            Text("Bluetooth: \(manager.bluetoothState.rawValue)")
            Text("Discovery: \(String(describing: manager.discoveryState))")
            Button("Find Controllers") {
                manager.start()
                do { try manager.discover(for: 60) }
                catch { errorMessage = String(describing: error) }
            }
            List(manager.controllers) { controller in
                HStack {
                    Text(controller.name)
                    Text(String(controller.state.buttons.rawValue, radix: 16))
                    Button("Disconnect") { manager.disconnect(controller.id) }
                }
            }
            if let errorMessage { Text(errorMessage) }
            Button("Stop") { Task { await manager.stop() } }
        }
    }
}
```

The host still supplies Info.plist/entitlements; importing a package does not create those settings. The ready-controller list is not a passive catalogue of every nearby Bluetooth device. Admission automatically connects supported advertisements during allowed discovery, and connection-progress events can drive a separate connecting indicator. Do not display arbitrary advertisement names as recognized models.

## Presentation versus input

The manager publishes `snapshot` on the main actor at approximately 10 Hz. Its convenience properties (`controllers`, `bluetoothState`, `discoveryState`, `isRunning`) read that snapshot. This is suitable for a live visualizer and status UI without scheduling a SwiftUI update for every radio report.

Use `observe(on:bufferingNewest:handler:)` for input-driven interaction that must see faster press/release edges. Retain its token in your coordinator, use `.main` for UI work, and assert the main actor only inside that explicitly main-queue callback. Avoid launching one `Task` per report: that would recreate an unbounded queue outside the library. A worker consumer can instead choose its own serial queue and pass only immutable, coalesced UI results to the main actor.

For application commands, feed the full observation to the public [action router](actions.md). It owns controller generation/gap recovery and emits semantic presses, releases and optional repeats. The host owns the active view/context and handles the returned actions.

Do not rely on the observable list's sampling rate to detect very short taps. On event overflow, reconcile `.snapshot`; on a controller's connection token or sequence gap, neutralize edge/repeat state before rearming. A slow consumer is not a lossless input recorder.

## Application lifecycle

A `WindowGroup` can invoke appearance callbacks more than once. Library `start()` is idempotent, but observation installation and host timers should also be idempotent. Do not stop the application's shared manager merely because one secondary window disappears.

Own sleep/wake and quit handling in an application delegate/coordinator. The full [demo](../../Examples/Switch2KitDemo) illustrates workspace observers, explicit user enablement, cancellation of its input observation/local keyboard monitor/repeat timer, and deferred AppKit termination until transport stop completes. Inactivity suppresses semantic UI navigation immediately; it does not silently rewrite the user's choice about controller support.

The manager's `stop()` async overload updates presentation before it returns. Its completion overload signals transport teardown on a background queue, so marshal UI changes back to the main actor. Returning a SwiftUI `View` or retaining a snapshot does not retain a live Bluetooth session independently of its manager.

## Identity and grouping

Use `controller.id` for lists and routing. `controller.connectionID` changes for each connection attempt and protects against stale state; do not persist it. A Joy-Con pair remains two rows unless your host deliberately groups them. The library's physical limit is a resource bound, not a player numbering rule. Custom names, mapping persistence and logical-player policy belong to your coordinator or model layer.
