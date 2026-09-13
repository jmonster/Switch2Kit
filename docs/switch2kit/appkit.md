# AppKit integration

AppKit does not need SwiftUI or the dashboard to use Switch2Kit. Keep one coordinator owned by the app delegate. The manager's observable surface is optional: a retained bounded observation can drive an NSTableView, a custom input router, or a non-UI worker.

```swift
import AppKit
import Switch2Kit

@MainActor
final class ControllerCoordinator {
    let manager = Switch2ControllerManager()
    private var observation: Switch2ControllerObservation?
    private(set) var controllers: [Switch2Controller] = []

    func start() throws {
        guard observation == nil else { return }
        observation = try manager.observe(on: .main, bufferingNewest: 256) { [weak self] event in
            MainActor.assumeIsolated { self?.receive(event) }
        }
        manager.start()
        try manager.discover(for: 60)
    }

    private func receive(_ event: Switch2ControllerEvent) {
        switch event {
        case .snapshot(let snapshot), .status(let snapshot):
            controllers = snapshot.controllers
        case .connected(let controller), .input(let controller):
            controllers.removeAll { $0.id == controller.id }
            controllers.append(controller)
        case .disconnected(let id, _):
            controllers.removeAll { $0.id == id }
        default: break
        }
        // Update a table or navigation model here; this callback is on .main.
    }

    func stop(completion: @escaping @Sendable () -> Void) {
        observation?.cancel(); observation = nil; controllers = []
        manager.stop(completion: completion)
    }
}
```

For termination, call the coordinator's stop method from `applicationShouldTerminate`, return `.terminateLater`, and call `NSApp.reply(toApplicationShouldTerminate: true)` on the main actor inside completion. The complete demo contains this implementation. Never synchronously wait on the main queue for a callback that needs the main queue.

The example intentionally performs UI work on the selected `.main` observation queue. For a simulation or input processor, choose a dedicated serial queue, protect its own mutable state there, and do not read main-actor presentation properties from it. `manager.currentSnapshot` is the immediate thread-safe immutable view when needed. Library callbacks never execute arbitrary host work on the Bluetooth queue.

Install observations once and cancel them explicitly when their owner stops. Token deallocation cancels too. The library bounds each observer and serializes delivery even when supplied a concurrent queue; it does not serialize *different observers' host state* with each other. Choose one owner for shared mutable routing data.

Provide Bluetooth permission/error UI in AppKit rather than silently treating `.unauthorized` or `.poweredOff` as no devices. The host's Info.plist contains the usage string, its sandbox entitlements contain the Bluetooth capability where needed, and its own lifecycle determines sleep and inactivity behavior. Neither CoreHID nor Accessibility approval is required for this in-process flow.
