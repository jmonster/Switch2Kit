import AppKit
import GameController
import Switch2Kit

private typealias NavigationCommand = Switch2NavigationAction

// This is HOST application policy, not part of the controller library.
@MainActor
final class DemoModel: ObservableObject {
    let manager = Switch2ControllerManager()
    @Published var selection = 0
    @Published var lastCommand = "Use arrows / Return / Escape, or D-pad / A / B."
    @Published var errorMessage: String?
    private var router = Switch2ActionRouter<Switch2NavigationAction>.navigation()
    private var observation: Switch2ControllerObservation?
    private var timer: Timer?
    private var keyboardMonitor: Any?
    private var keyboard: Set<UInt16> = []
    private var nativeSources: [ObjectIdentifier: UUID] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []
    private var wantsSupport = false
    private var active = false

    func start() {
        wantsSupport = true
        guard observation == nil else { manager.start(); return }
        if workspaceObservers.isEmpty {
            let center = NSWorkspace.shared.notificationCenter
            workspaceObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification,
                object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sleep() }
            })
            workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification,
                object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self, self.wantsSupport { self.start() } }
            })
        }
        do {
            observation = try manager.observe(on: .main, bufferingNewest: 256) { [weak self] event in
                MainActor.assumeIsolated { self?.receive(event) }
            }
        } catch { errorMessage = String(describing: error); return }
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            // Keep NSEvent inside the local AppKit callback. Only a Sendable Bool
            // crosses assumeIsolated's result boundary; NSEvent is not Sendable.
            let consumed = MainActor.assumeIsolated {
                guard let self else { return false }
                return self.key(event) == nil
            }
            return consumed ? nil : event
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        updateActivity()
        manager.start()
    }
    func discover() {
        start()
        do { try manager.discover(for: 60) } catch { errorMessage = String(describing: error) }
    }
    func stop() async {
        wantsSupport = false
        stopPresentation()
        await manager.stop()
    }
    func prepareToQuit(completion: @escaping @Sendable () -> Void) {
        wantsSupport = false
        stopPresentation()
        for token in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        workspaceObservers.removeAll()
        manager.stop(completion: completion)
    }
    private func sleep() {
        stopPresentation()
        manager.stop(completion: {})
    }
    private func stopPresentation() {
        observation?.cancel(); observation = nil
        timer?.invalidate(); timer = nil
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
        keyboardMonitor = nil
        route(router.reset()); route(router.setActive(false)); active = false
        keyboard.removeAll(); nativeSources.removeAll()
    }
    private func updateActivity() {
        let next = NSApp.isActive && NSApp.keyWindow != nil
        guard next != active else { return }
        active = next; route(router.setActive(next)); keyboard.removeAll()
        route(router.receive(Set<NavigationCommand>(), from: .keyboard, at: ProcessInfo.processInfo.systemUptime))
    }
    private func receive(_ event: Switch2ControllerEvent) {
        updateActivity()
        route(router.receive(event, at: ProcessInfo.processInfo.systemUptime))
        if case .failure(_, let error) = event { errorMessage = String(describing: error) }
    }

    private func key(_ event: NSEvent) -> NSEvent? {
        updateActivity()
        let keys: [UInt16: NavigationCommand] = [123: .left, 124: .right, 125: .down, 126: .up, 36: .activate, 49: .activate, 53: .back]
        guard keys[event.keyCode] != nil else { return event }
        // Key-up releases its own key-down even if modifiers or first responder changed.
        if event.type == .keyUp {
            guard keyboard.remove(event.keyCode) != nil else { return event }
        } else {
            guard active, !(NSApp.keyWindow?.firstResponder is NSTextView),
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
            if event.isARepeat { return nil }
            keyboard.insert(event.keyCode)
        }
        let actions = Set(keyboard.compactMap { keys[$0] })
        route(router.receive(actions, from: .keyboard, at: ProcessInfo.processInfo.systemUptime))
        return nil // Only this application's handled keys; no global event posting.
    }
    private func tick() {
        updateActivity()
        guard active else { return }
        let controllers = Array(GCController.controllers().prefix(32))
        let live = Set(controllers.map(ObjectIdentifier.init))
        for key in nativeSources.keys.filter({ !live.contains($0) }) {
            if let id = nativeSources.removeValue(forKey: key) { route(router.remove(.external(id))) }
        }
        let now = ProcessInfo.processInfo.systemUptime
        // Snapshot polling avoids queuing a task per native input callback.
        for controller in controllers {
            guard let pad = controller.extendedGamepad else { continue }
            let key = ObjectIdentifier(controller)
            let id = nativeSources[key] ?? UUID(); nativeSources[key] = id
            var buttons: Switch2Buttons = []
            for (pressed, button) in [(pad.dpad.up.isPressed, Switch2Buttons.dpadUp),
                (pad.dpad.down.isPressed, .dpadDown), (pad.dpad.left.isPressed, .dpadLeft), (pad.dpad.right.isPressed, .dpadRight),
                (pad.buttonA.isPressed, .a), (pad.buttonB.isPressed, .b)] where pressed { buttons.insert(button) }
            let input = Switch2ControllerState(buttons: buttons, leftStick: .init(x: Double(pad.leftThumbstick.xAxis.value),
                                                                       y: Double(pad.leftThumbstick.yAxis.value)))
            route(router.receive(input, from: .external(id), at: now))
        }
        route(router.tick(at: now))
    }
    private func route(_ events: [Switch2ActionEvent<NavigationCommand>]) {
        // This grid uses discrete commands; hosts with held actions must also apply releases.
        for event in events where event.phase != .released {
            let command = event.action
            switch command {
            case .up: selection = max(0, selection - 3)
            case .down: selection = min(8, selection + 3)
            case .left: selection = max(0, selection - 1)
            case .right: selection = min(8, selection + 1)
            case .activate: lastCommand = "Activated item \(selection + 1)"
            case .back: selection = 0; lastCommand = "Back to item 1"
            }
            if command.isDirectional { lastCommand = "\(command.rawValue.capitalized): item \(selection + 1)" }
        }
    }
}
