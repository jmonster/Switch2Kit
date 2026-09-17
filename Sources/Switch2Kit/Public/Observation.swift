import Foundation
import Synchronization

/// A cancellable, bounded event observation. Retain it for as long as events are needed.
/// Cancellation is idempotent; queued work is discarded. A handler already executing
/// may finish, but no new handler invocation is started after cancellation is observed.
/// Delivery is serialized on the requested queue, including when that queue is concurrent.
public final class Switch2ControllerObservation: Sendable {
    private let mailbox: EventMailbox
    private let remove: @Sendable () -> Void
    package init(mailbox: EventMailbox, remove: @escaping @Sendable () -> Void) {
        self.mailbox = mailbox; self.remove = remove
    }
    /// Stops delivery and discards queued events without blocking on caller work.
    public func cancel() { mailbox.cancel(); remove() }
    deinit { cancel() }
}

// A token belongs to exactly one attempt. Retirement is terminal; a reconnect gets a NEW token.
package final class SessionLifetime: Sendable {
    package init() {}
    package let id = UUID()
    private let active = Mutex(true)
    package var isActive: Bool { active.withLock { $0 } }
    package func retire() { active.withLock { $0 = false } }
}

package struct EventEnvelope: Sendable {
    package let sequence: UInt64
    package let event: Switch2ControllerEvent
    package let lifetime: SessionLifetime?
    // Only snapshots carry this bounded ready-set token list. No session objects escape.
    package var snapshotLifetimes: [SessionLifetime] = []
}

// Every mutable field is mutex-protected; handler calls are serialized by a single scheduled drain.
// The Bluetooth producer never invokes a handler, waits for a handler, or enqueues one task per report.
package protocol EventSink: Sendable {
    func enqueue(_ event: EventEnvelope)
    func cancel()
}

// FIFO specialized for the hub's monotonically numbered envelopes. Storage grows
// lazily up to the observation's existing bound. Popping releases the envelope
// immediately without shifting the rest of the backlog under a producer lock.
struct PendingControllerEvents: Sendable {
    private let capacity: Int
    private var storage: [EventEnvelope?] = []
    private var head = 0
    private(set) var count = 0
    var isEmpty: Bool { count == 0 }
    var allocatedCount: Int { storage.count }

    init(capacity: Int) {
        precondition((1...4096).contains(capacity))
        self.capacity = capacity
    }
    mutating func append(_ event: EventEnvelope) {
        precondition(count < capacity)
        if count == storage.count {
            var grown = [EventEnvelope?](repeating: nil,
                count: min(capacity, max(1, storage.count * 2)))
            for index in 0..<count { grown[index] = storage[(head + index) % storage.count] }
            storage = grown; head = 0
        }
        storage[(head + count) % storage.count] = event
        count += 1
    }
    mutating func popFirst() -> EventEnvelope? {
        guard count != 0 else { return nil }
        let event = storage[head]
        storage[head] = nil
        head = (head + 1) % storage.count
        count -= 1
        return event
    }
    mutating func takeFirst(_ maximum: Int) -> [EventEnvelope] {
        var result: [EventEnvelope] = []
        result.reserveCapacity(min(maximum, count))
        for _ in 0..<min(maximum, count) {
            if let event = popFirst() { result.append(event) }
        }
        return result
    }
    mutating func discard(through sequence: UInt64) {
        // Only resynchronization may advance past queued input. Since the hub
        // publishes in order, obsolete envelopes form a prefix, not a full scan.
        while count != 0, let first = storage[head], first.sequence <= sequence {
            _ = popFirst()
        }
    }
    mutating func removeAll(keepingCapacity: Bool = false) {
        if keepingCapacity {
            while popFirst() != nil {}
        } else {
            storage.removeAll(); count = 0
        }
        head = 0
    }
}

package final class EventMailbox: EventSink {
    private struct State: Sendable {
        var pending: PendingControllerEvents
        var overflow = false
        var scheduled = false
        var cancelled = false
        var delivered: UInt64 = 0
    }
    private let state: Mutex<State>
    private let capacity: Int
    private let queue: DispatchQueue
    private let interval: TimeInterval
    private let current: @Sendable () -> EventEnvelope
    private let handler: @Sendable (Switch2ControllerEvent) -> Void
    package init(capacity: Int, queue: DispatchQueue, interval: TimeInterval = 0,
                 current: @escaping @Sendable () -> EventEnvelope,
                 handler: @escaping @Sendable (Switch2ControllerEvent) -> Void) {
        self.capacity = min(4096, max(1, capacity)); self.queue = queue
        self.state = Mutex(State(pending: PendingControllerEvents(capacity: self.capacity)))
        self.interval = interval; self.current = current; self.handler = handler
    }
    package func enqueue(_ event: EventEnvelope) {
        let schedule = state.withLock { value in
            guard !value.cancelled, event.sequence > value.delivered else { return false }
            if value.pending.count >= capacity { value.pending.removeAll(keepingCapacity: true); value.overflow = true }
            if !value.overflow { value.pending.append(event) }
            guard !value.scheduled else { return false }
            value.scheduled = true; return true
        }
        if schedule { scheduleDrain() }
    }
    private func scheduleDrain() {
        queue.asyncAfter(deadline: .now() + interval) { [weak self] in self?.drain() }
    }
    private func drain() {
        for _ in 0..<32 {
            let next: (Bool, EventEnvelope?) = state.withLock { value in
                guard !value.cancelled else { return (false, nil) }
                if value.overflow { value.overflow = false; return (true, nil) }
                guard !value.pending.isEmpty else { return (false, nil) }
                return (false, value.pending.popFirst())
            }
            var envelope: EventEnvelope
            if next.0 { envelope = current() }
            else if let item = next.1 { envelope = item }
            else { break }
            // Preserve FIFO delivery at full rate. Refresh a historical snapshot only
            // when one of its attempts retired; refreshing every status used to jump
            // the sequence watermark over valid queued input even without overflow.
            if envelope.snapshotLifetimes.contains(where: { !$0.isActive }) { envelope = current() }
            guard envelope.lifetime?.isActive != false else { continue }
            let deliver = state.withLock { value in
                guard !value.cancelled, envelope.sequence > value.delivered else { return false }
                value.delivered = envelope.sequence
                value.pending.discard(through: value.delivered)
                return true
            }
            if deliver { handler(envelope.event) }
        }
        let again = state.withLock { value in
            if value.cancelled || (!value.overflow && value.pending.isEmpty) {
                value.scheduled = false; return false
            }
            return true
        }
        if again { scheduleDrain() }
    }
    package func cancel() {
        state.withLock { $0.cancelled = true; $0.pending.removeAll(); $0.overflow = false }
    }
    package var pendingCount: Int { state.withLock { $0.pending.count } }
}

package final class ControllerEventHub: Sendable {
    package init() {}
    private struct State: Sendable {
        var snapshot = Switch2ManagerSnapshot()
        var sequence: UInt64 = 1
        var nextObserver: UInt64 = 0
        var observers: [UInt64: any EventSink] = [:]
        var lifetimes: [Switch2ControllerID: SessionLifetime] = [:]
    }
    private let state = Mutex(State())

    // Session teardown retires its token before the transport publishes removal.
    // Project through those tokens so reads and resynchronization cannot expose
    // retired controllers during that interval. The hub mutex guards the map;
    // each token independently guards its terminal state. No host work runs here.
    private static func snapshotForDelivery(_ value: State)
        -> (snapshot: Switch2ManagerSnapshot, lifetimes: [SessionLifetime]) {
        var controllers: [Switch2Controller] = []
        var lifetimes: [SessionLifetime] = []
        for controller in value.snapshot.controllers {
            guard let lifetime = value.lifetimes[controller.id],
                  lifetime.id == controller.sessionGeneration, lifetime.isActive else { continue }
            controllers.append(controller)
            lifetimes.append(lifetime)
        }
        let snapshot = Switch2ManagerSnapshot(isRunning: value.snapshot.isRunning,
            bluetooth: value.snapshot.bluetooth, discovery: value.snapshot.discovery,
            controllers: controllers, rememberedControllers: value.snapshot.rememberedControllers)
        return (snapshot, lifetimes)
    }

    package var snapshot: Switch2ManagerSnapshot {
        state.withLock { Self.snapshotForDelivery($0).snapshot }
    }
    package func current() -> EventEnvelope {
        state.withLock { value in
            let current = Self.snapshotForDelivery(value)
            return EventEnvelope(sequence: value.sequence, event: .snapshot(current.snapshot), lifetime: nil,
                                 snapshotLifetimes: current.lifetimes)
        }
    }
    package func observe(queue: DispatchQueue, capacity: Int, interval: TimeInterval = 0,
                         handler: @escaping @Sendable (Switch2ControllerEvent) -> Void) throws -> Switch2ControllerObservation {
        guard (1...4096).contains(capacity), interval.isFinite, interval >= 0 else { throw Switch2KitError.invalidParameter }
        let mailbox = EventMailbox(capacity: capacity, queue: queue, interval: interval, current: { [weak self] in
            self?.current() ?? EventEnvelope(sequence: .max, event: .snapshot(.init()), lifetime: nil)
        }, handler: handler)
        let id = try state.withLock { value in
            guard value.observers.count < 32 else { throw Switch2KitError.observerLimitReached }
            value.nextObserver &+= 1
            let id = value.nextObserver; value.observers[id] = mailbox
            let current = Self.snapshotForDelivery(value)
            mailbox.enqueue(EventEnvelope(sequence: value.sequence, event: .snapshot(current.snapshot), lifetime: nil,
                                          snapshotLifetimes: current.lifetimes))
            return id
        }
        return Switch2ControllerObservation(mailbox: mailbox) { [weak self] in
            _ = self?.state.withLock { $0.observers.removeValue(forKey: id) }
        }
    }
    // Called only on the transport queue. Immutable snapshots leave that queue through this hub.
    package func publish(_ snapshot: Switch2ManagerSnapshot, event: Switch2ControllerEvent,
                         lifetime: SessionLifetime? = nil) {
        state.withLock { value in
            value.snapshot = snapshot; value.sequence &+= 1
            if let lifetime {
                switch event {
                case .connected(let controller), .input(let controller): value.lifetimes[controller.id] = lifetime
                default: break
                }
            }
            let readyIDs = Set(snapshot.controllers.map(\.id))
            value.lifetimes = value.lifetimes.filter { readyIDs.contains($0.key) }
            var envelope = EventEnvelope(sequence: value.sequence, event: event, lifetime: lifetime)
            switch event {
            case .snapshot, .status: envelope.snapshotLifetimes = Array(value.lifetimes.values)
            default: break
            }
            for mailbox in value.observers.values { mailbox.enqueue(envelope) }
        }
    }
    package func cancelAll() {
        let observers = state.withLock { value in
            let observers = Array(value.observers.values)
            value.observers.removeAll()
            value.lifetimes.removeAll()
            return observers
        }
        for observer in observers { observer.cancel() }
    }
}


// Bounded pull observation used by non-Swift hosts. No callbacks or delivery tasks.
// The only producer is ControllerEventHub; one host thread drains each reader.
package final class ControllerEventReader: EventSink {
    private struct State: Sendable {
        var pending: PendingControllerEvents
        var overflow = true
        var cancelled = false
        var delivered: UInt64 = 0
    }
    private let state: Mutex<State>
    private let capacity: Int
    private let current: @Sendable () -> EventEnvelope
    private let remove: @Sendable () -> Void
    package init(capacity: Int, current: @escaping @Sendable () -> EventEnvelope,
                 remove: @escaping @Sendable () -> Void) {
        self.capacity = capacity; self.current = current; self.remove = remove
        self.state = Mutex(State(pending: PendingControllerEvents(capacity: capacity)))
    }
    package func enqueue(_ event: EventEnvelope) {
        state.withLock { value in
            guard !value.cancelled, event.sequence > value.delivered else { return }
            if case .snapshot = event.event { value.overflow = true }
            if value.pending.count >= capacity { value.overflow = true }
            if value.overflow { value.pending.removeAll(keepingCapacity: true) }
            else { value.pending.append(event) }
        }
    }
    // Never call current() while holding the reader mutex: the hub acquires them
    // in the opposite order while publishing. This also applies to cancel/remove.
    package func read(maximum: Int) -> (events: [Switch2ControllerEvent], snapshot: Switch2ManagerSnapshot, resync: Bool, more: Bool) {
        let picked: (events: [EventEnvelope], resync: Bool) = state.withLock { value in
            guard !value.cancelled, maximum > 0 else { return ([], false) }
            if value.overflow { value.overflow = false; return ([], true) }
            let events = value.pending.takeFirst(maximum)
            return (events, events.contains { $0.lifetime?.isActive == false || $0.snapshotLifetimes.contains { !$0.isActive } })
        }
        let now = current()
        guard case .snapshot(let snapshot) = now.event else { preconditionFailure("Hub current must be a snapshot") }
        // A second check closes retirement between removal from the inbox and projection.
        let resync = picked.resync || picked.events.contains {
            $0.lifetime?.isActive == false || $0.snapshotLifetimes.contains { !$0.isActive }
        }
        return state.withLock { value in
            guard !value.cancelled else { return ([], snapshot, false, false) }
            if resync {
                value.delivered = max(value.delivered, now.sequence)
                value.pending.discard(through: value.delivered)
                // A concurrent producer may have overflowed after current() was read.
                // Keep that overflow bit, forcing another authoritative snapshot next read.
                return ([], snapshot, true, value.overflow || !value.pending.isEmpty)
            }
            let events = picked.events.filter { $0.sequence > value.delivered }
            if let last = events.last { value.delivered = last.sequence }
            return (events.map(\.event), snapshot, false, value.overflow || !value.pending.isEmpty)
        }
    }
    package func reset() {
        state.withLock { $0.pending.removeAll(keepingCapacity: true); $0.overflow = true }
    }
    package func cancel() {
        state.withLock { $0.cancelled = true; $0.pending.removeAll(); $0.overflow = false }
        remove()
    }
    package var pendingCount: Int { state.withLock { $0.pending.count } }
}

extension ControllerEventHub {
    package func makeReader(capacity: Int) throws -> ControllerEventReader {
        guard (1...256).contains(capacity) else { throw Switch2KitError.invalidParameter }
        return try state.withLock { value in
            guard value.observers.count < 32 else { throw Switch2KitError.observerLimitReached }
            value.nextObserver &+= 1
            let id = value.nextObserver
            let reader = ControllerEventReader(capacity: capacity, current: { [weak self] in
                self?.current() ?? EventEnvelope(sequence: .max, event: .snapshot(.init()), lifetime: nil)
            }, remove: { [weak self] in
                _ = self?.state.withLock { $0.observers.removeValue(forKey: id) }
            })
            value.observers[id] = reader
            return reader
        }
    }
}
