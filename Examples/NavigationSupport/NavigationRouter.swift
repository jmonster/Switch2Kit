import Foundation
import Switch2Kit

/// Example-only semantic commands. This module is not part of Switch2Kit's public product.
package enum NavigationCommand: String, CaseIterable, Hashable, Sendable {
    case up, down, left, right, activate, back
    var repeats: Bool { self != .activate && self != .back }
}

/// Distinguishes input ownership so one device cannot release another device's control.
package enum NavigationSource: Hashable, Sendable {
    case keyboard
    case switch2Kit(Switch2ControllerID)
    case gameController(UUID)
}

/// Host navigation intent, with positive x right and positive y up, in -1...1.
package struct NavigationInput: Sendable {
    package var actions: Set<NavigationCommand>
    package var stick: Switch2Stick
    package init(actions: Set<NavigationCommand> = [], stick: Switch2Stick = .init()) {
        self.actions = actions; self.stick = stick
    }
    package init(_ state: Switch2ControllerState) {
        actions = []
        for (button, command) in [(Switch2Buttons.dpadUp, NavigationCommand.up), (.dpadDown, .down),
            (.dpadLeft, .left), (.dpadRight, .right), (.a, .activate), (.b, .back)] where state.buttons.contains(button) {
            actions.insert(command)
        }
        stick = state.leftStick ?? state.rightStick ?? .init()
    }
}

/// Caller-confined pure example policy. No timers, global events, UI or Bluetooth ownership.
/// Enter a direction at 0.55, leave below 0.35, repeat after 400 ms then every 90 ms.
/// Activate/back are edge-only. After focus, connection or overflow, neutral input is
/// required before arming. A late timer emits at most one repeat per held direction.
package struct NavigationRouter: Sendable {
    private struct SourceState: Sendable {
        var armed = false
        var analog: Set<NavigationCommand> = []
        var held: Set<NavigationCommand> = []
    }
    private var sources: [NavigationSource: SourceState] = [:]
    private var held: Set<NavigationCommand> = []
    private var repeatAt: [NavigationCommand: TimeInterval] = [:]
    private var active = false
    package init() {}

    /// Changing activity clears ownership and requires neutral before accepting input.
    package mutating func setActive(_ value: Bool) {
        guard value != active else { return }
        active = value
        held.removeAll(); repeatAt.removeAll(); sources.removeAll()
    }
    /// Clears a disconnected or resynchronized source without manufacturing a press.
    package mutating func remove(_ source: NavigationSource) {
        sources.removeValue(forKey: source)
        held.formIntersection(aggregate())
        repeatAt = repeatAt.filter { held.contains($0.key) }
    }
    /// Clear all held inputs, for a stop or an authoritative snapshot after overflow.
    package mutating func reset() { sources.removeAll(); held.removeAll(); repeatAt.removeAll() }

    /// Returns edges in deterministic command order. Storage admits at most 64 sources.
    package mutating func receive(_ input: NavigationInput, from source: NavigationSource,
                                  at now: TimeInterval) -> [NavigationCommand] {
        guard active, now.isFinite, sources[source] != nil || sources.count < 64 else { return [] }
        var state = sources[source] ?? SourceState()
        var analog: Set<NavigationCommand> = []
        for (command, magnitude) in [(NavigationCommand.right, input.stick.x), (.left, -input.stick.x),
                                     (.up, input.stick.y), (.down, -input.stick.y)] {
            let threshold = state.analog.contains(command) ? 0.35 : 0.55
            if magnitude >= threshold { analog.insert(command) }
        }
        state.analog = analog
        let commands = input.actions.union(analog)
        if !state.armed {
            // A value inside the release dead zone is required, not merely below engagement.
            state.armed = input.actions.isEmpty && abs(input.stick.x) < 0.35 && abs(input.stick.y) < 0.35
            state.held = []
            sources[source] = state
            return []
        }
        state.held = commands; sources[source] = state
        let current = aggregate()
        let edges = current.subtracting(held)
        repeatAt = repeatAt.filter { current.contains($0.key) }
        for command in edges where command.repeats { repeatAt[command] = now + 0.4 }
        held = current
        return NavigationCommand.allCases.filter { edges.contains($0) }
    }

    /// Inject a monotonic clock; never replay a backlog of repeats after a stall.
    package mutating func tick(at now: TimeInterval) -> [NavigationCommand] {
        guard active, now.isFinite else { return [] }
        return NavigationCommand.allCases.filter { command in
            guard let deadline = repeatAt[command], now >= deadline else { return false }
            repeatAt[command] = now + 0.09
            return true
        }
    }
    private func aggregate() -> Set<NavigationCommand> {
        var result = sources.values.reduce(into: Set<NavigationCommand>()) { $0.formUnion($1.held) }
        for pair in [[NavigationCommand.up, .down], [.left, .right]] where pair.allSatisfy({ result.contains($0) }) {
            result.subtract(pair)
        }
        return result
    }
}
