import Foundation

/// Input ownership within one host context. Reuse an external ID until that source disconnects.
public enum Switch2ActionSource: Hashable, Sendable {
    case controller(Switch2ControllerID)
    case keyboard
    case external(UUID)
}

/// Normalized axes that can drive discrete actions. Trigger travel does not include digital clicks.
public enum Switch2ActionAxis: Sendable {
    case leftX, leftY, rightX, rightY, primaryX, primaryY, leftTrigger, rightTrigger

    fileprivate func value(in state: Switch2ControllerState) -> Double {
        let primary = state.leftStick ?? state.rightStick
        switch self {
        case .leftX: return state.leftStick?.x ?? 0
        case .leftY: return state.leftStick?.y ?? 0
        case .rightX: return state.rightStick?.x ?? 0
        case .rightY: return state.rightStick?.y ?? 0
        case .primaryX: return primary?.x ?? 0
        case .primaryY: return primary?.y ?? 0
        case .leftTrigger: return state.leftTrigger.travel ?? 0
        case .rightTrigger: return state.rightTrigger.travel ?? 0
        }
    }
}

/// A digital chord (all bits required), or one signed half of a normalized axis.
public enum Switch2ActionControl: Sendable {
    case buttons(Switch2Buttons)
    case axis(Switch2ActionAxis, positive: Bool)
}

/// Multiple bindings may produce the same host-defined action. No mapping is persisted.
public struct Switch2ActionBinding<Action: Hashable & Sendable>: Sendable {
    public let action: Action
    public let control: Switch2ActionControl
    public init(_ action: Action, from control: Switch2ActionControl) {
        self.action = action; self.control = control
    }
}

/// Aggregate action transitions, not raw button transitions. Repeats never imply another press.
public struct Switch2ActionEvent<Action: Hashable & Sendable>: Equatable, Sendable {
    public enum Phase: Sendable { case pressed, released, repeated }
    public let action: Action
    public let phase: Phase
    public init(_ action: Action, phase: Phase) { self.action = action; self.phase = phase }
}

/// Caller-confined action routing. Own one value per active host context, on one executor.
/// No timers, global events, preferences or controller ownership are created here.
/// Feed full-rate observation events, apply EVERY returned release, and call `tick` from
/// the host loop for repeats. Bindings and input ownership are bounded independently.
public struct Switch2ActionRouter<Action: Hashable & Sendable>: Sendable {
    private struct SourceState: Sendable {
        var armed = false
        var analog: Set<Int> = []
        var held: Set<Action> = []
        var connection: UUID?
        var sequence: UInt64?
    }
    private let actions: [Action]
    private let supported: Set<Action>
    private var bindings: [Switch2ActionBinding<Action>]
    private let repeating: Set<Action>
    private let opposing: [Set<Action>]
    private let repeatDelay: TimeInterval
    private let repeatInterval: TimeInterval
    private let activationThreshold: Double
    private let releaseThreshold: Double
    private let maximumSources: Int
    private var sources: [Switch2ActionSource: SourceState] = [:]
    private var repeatAt: [Action: TimeInterval] = [:]
    private var lastTime: TimeInterval?
    public private(set) var isActive = false
    public private(set) var heldActions: Set<Action> = []
    /// Includes unarmed sources. Extra sources are ignored until one is removed.
    public var sourceCount: Int { sources.count }

    /// `actions` defines deterministic event order and must contain 1...128 unique values.
    /// Bind at most 256 controls; declare at most 64 opposing pairs and 1...64 sources.
    /// Unknown actions, empty button chords, invalid thresholds/timing or bounds throw
    /// `Switch2KitError.invalidParameter`. Analog thresholds satisfy 0 < release < activation <= 1.
    public init(actions: [Action], bindings: [Switch2ActionBinding<Action>] = [],
                repeating: Set<Action> = [], opposing: [Set<Action>] = [],
                repeatDelay: TimeInterval = 0.4, repeatInterval: TimeInterval = 0.09,
                activationThreshold: Double = 0.55, releaseThreshold: Double = 0.35,
                maximumSources: Int = 64) throws {
        let supported = Set(actions)
        guard (1...128).contains(actions.count), supported.count == actions.count,
              repeating.isSubset(of: supported), opposing.count <= 64,
              opposing.allSatisfy({ $0.count == 2 && $0.isSubset(of: supported) }),
              repeatDelay.isFinite, repeatDelay > 0, repeatInterval.isFinite, repeatInterval > 0,
              activationThreshold.isFinite, releaseThreshold.isFinite,
              releaseThreshold > 0, activationThreshold > releaseThreshold, activationThreshold <= 1,
              (1...64).contains(maximumSources), Self.valid(bindings, supported: supported) else {
            throw Switch2KitError.invalidParameter
        }
        self.actions = actions; self.supported = supported; self.bindings = bindings
        self.repeating = repeating; self.opposing = opposing
        self.repeatDelay = repeatDelay; self.repeatInterval = repeatInterval
        self.activationThreshold = activationThreshold; self.releaseThreshold = releaseThreshold
        self.maximumSources = maximumSources
    }

    /// Context/focus changes release held actions and require neutral input before rearming.
    @discardableResult
    public mutating func setActive(_ value: Bool) -> [Switch2ActionEvent<Action>] {
        guard value != isActive else { return [] }
        let events = reset(); isActive = value; return events
    }

    /// Stop/reset returns all releases and clears ownership, generation, hysteresis and repeat state.
    /// Activity is unchanged. Replacing an entire router/context should begin with this operation.
    @discardableResult
    public mutating func reset() -> [Switch2ActionEvent<Action>] {
        let events = ordered(heldActions, phase: .released)
        heldActions.removeAll(); sources.removeAll(); repeatAt.removeAll(); lastTime = nil
        return events
    }

    /// Rebinding releases old actions before accepting the new mapping. Invalid changes are atomic.
    @discardableResult
    public mutating func replaceBindings(_ value: [Switch2ActionBinding<Action>]) throws -> [Switch2ActionEvent<Action>] {
        guard Self.valid(value, supported: supported) else { throw Switch2KitError.invalidParameter }
        let events = reset(); bindings = value; return events
    }

    /// Removing a source releases only actions no remaining source owns. It creates no presses.
    @discardableResult
    public mutating func remove(_ source: Switch2ActionSource) -> [Switch2ActionEvent<Action>] {
        sources.removeValue(forKey: source)
        return reconcile(at: lastTime ?? 0, allowPresses: false)
    }

    /// Feed already-mapped actions from local keys, gestures or another input provider.
    /// Unknown actions are ignored. Use a distinct source for each independent provider.
    public mutating func receive(_ input: Set<Action>, from source: Switch2ActionSource,
                                 at now: TimeInterval) -> [Switch2ActionEvent<Action>] {
        guard isActive else { return [] }
        guard advance(to: now) else { return reset() }
        let known = input.intersection(supported)
        return accept(known, neutral: known.isEmpty, analog: [], source: source, at: now)
    }

    /// Map a controller state. For library observations prefer the event overload, which also
    /// handles connection generations, report gaps, disconnects and overflow snapshots.
    public mutating func receive(_ input: Switch2ControllerState, from source: Switch2ActionSource,
                                 at now: TimeInterval) -> [Switch2ActionEvent<Action>] {
        guard isActive else { return [] }
        guard advance(to: now) else { return reset() }
        var mapped: Set<Action> = [], analog: Set<Int> = []
        var neutral = true
        let previous = sources[source]?.analog ?? []
        for (index, binding) in bindings.enumerated() {
            switch binding.control {
            case .buttons(let mask):
                if input.buttons.contains(mask) { mapped.insert(binding.action) }
                if !input.buttons.intersection(mask).isEmpty { neutral = false }
            case .axis(let axis, let positive):
                let magnitude = axis.value(in: input) * (positive ? 1 : -1)
                if magnitude >= releaseThreshold { neutral = false }
                if magnitude >= (previous.contains(index) ? releaseThreshold : activationThreshold) {
                    analog.insert(index); mapped.insert(binding.action)
                }
            }
        }
        return accept(mapped, neutral: neutral, analog: analog, source: source, at: now)
    }

    /// Route ordered manager events. A gap or generation change releases that controller and
    /// requires neutral. An authoritative snapshot resets controller sources only, not local keys.
    /// Snapshot contents never manufacture presses. Forward events without additional reordering.
    public mutating func receive(_ event: Switch2ControllerEvent, at now: TimeInterval) -> [Switch2ActionEvent<Action>] {
        guard isActive else { return [] }
        guard advance(to: now) else { return reset() }
        switch event {
        case .input(let controller):
            let source = Switch2ActionSource.controller(controller.id)
            var events: [Switch2ActionEvent<Action>] = []
            if let old = sources[source], old.connection != controller.connectionID ||
                (old.sequence.map { $0 &+ 1 != controller.state.sequence } ?? false) {
                events += remove(source)
            }
            events += receive(controller.state, from: source, at: now)
            // No metadata is retained for a source rejected by the admission bound.
            sources[source]?.connection = controller.connectionID
            sources[source]?.sequence = controller.state.sequence
            return events
        case .connected(let controller): return remove(.controller(controller.id))
        case .disconnected(let id, _): return remove(.controller(id))
        case .snapshot:
            for source in Array(sources.keys) {
                if case .controller = source { sources.removeValue(forKey: source) }
            }
            return reconcile(at: now, allowPresses: false)
        default: return []
        }
    }

    /// Inject monotonic seconds from the same clock used by `receive`. A late tick produces
    /// at most one repeat per action, never a catch-up burst. Invalid/backward time releases
    /// everything and requires neutral. Repeats stop when the host stops calling this method.
    public mutating func tick(at now: TimeInterval) -> [Switch2ActionEvent<Action>] {
        guard isActive else { return [] }
        guard advance(to: now) else { return reset() }
        return actions.compactMap { action in
            guard let deadline = repeatAt[action], now >= deadline else { return nil }
            repeatAt[action] = now + repeatInterval
            return .init(action, phase: .repeated)
        }
    }

    private static func valid(_ bindings: [Switch2ActionBinding<Action>], supported: Set<Action>) -> Bool {
        bindings.count <= 256 && bindings.allSatisfy { binding in
            guard supported.contains(binding.action) else { return false }
            if case .buttons(let mask) = binding.control { return !mask.isEmpty }
            return true
        }
    }
    private mutating func advance(to now: TimeInterval) -> Bool {
        guard now.isFinite, now >= 0, lastTime.map({ now >= $0 }) ?? true,
              (now + repeatDelay).isFinite, (now + repeatInterval).isFinite,
              now + repeatDelay > now, now + repeatInterval > now else { return false }
        lastTime = now; return true
    }
    private mutating func accept(_ input: Set<Action>, neutral: Bool, analog: Set<Int>,
                                 source: Switch2ActionSource, at now: TimeInterval) -> [Switch2ActionEvent<Action>] {
        guard sources[source] != nil || sources.count < maximumSources else { return [] }
        var state = sources[source] ?? SourceState()
        state.analog = analog
        if !state.armed {
            state.armed = neutral; state.held = []; sources[source] = state
            return []
        }
        state.held = input; sources[source] = state
        return reconcile(at: now, allowPresses: true)
    }
    private func aggregate() -> Set<Action> {
        let all = sources.values.reduce(into: Set<Action>()) { $0.formUnion($1.held) }
        let suppressed = opposing.filter { $0.isSubset(of: all) }.reduce(into: Set<Action>()) { $0.formUnion($1) }
        return all.subtracting(suppressed)
    }
    private mutating func reconcile(at now: TimeInterval, allowPresses: Bool) -> [Switch2ActionEvent<Action>] {
        let current = aggregate()
        let released = heldActions.subtracting(current)
        let pressed = allowPresses ? current.subtracting(heldActions) : []
        repeatAt = repeatAt.filter { current.contains($0.key) }
        for action in pressed where repeating.contains(action) { repeatAt[action] = now + repeatDelay }
        heldActions = allowPresses ? current : heldActions.intersection(current)
        return ordered(released, phase: .released) + ordered(pressed, phase: .pressed)
    }
    private func ordered(_ values: Set<Action>, phase: Switch2ActionEvent<Action>.Phase) -> [Switch2ActionEvent<Action>] {
        actions.compactMap { values.contains($0) ? .init($0, phase: phase) : nil }
    }
}
