import Foundation
import Synchronization
import Switch2Kit

// Injectable boundary for ABI tests. Implementations only enqueue library work;
// stop completion MUST be asynchronous. No caller work runs under a context lock.
package protocol ControllerSource: Sendable {
    var hub: ControllerEventHub { get }
    func start()
    func stop(completion: @escaping @Sendable () -> Void)
    func discover(seconds: Double)
    func disconnect(id: Switch2ControllerID, connection: UUID, forget: Bool)
    func rumble(id: Switch2ControllerID, connection: UUID, strong: Double, weak: Double, duration: Double?, feedback: Bool)
    func player(id: Switch2ControllerID, connection: UUID, number: Int)
}

// All mutable ownership/lifecycle state is mutex protected. Read has a single
// logical host reader; start/stop/control calls can arrive from other threads.
package final class CContext: Sendable {
    private struct Lifecycle: Sendable { var running = false; var stopping = false; var closed = false }
    private let lifecycle = Mutex(Lifecycle())
    package let source: any ControllerSource
    private let reader: ControllerEventReader
    package init(source: any ControllerSource, capacity: Int) throws {
        self.source = source; reader = try source.hub.makeReader(capacity: capacity)
    }
    package func start() -> Int32 {
        lifecycle.withLock { value in
            guard !value.closed else { return 1 }
            guard !value.stopping else { return 5 }
            guard !value.running else { return 0 }
            value.running = true; reader.reset(); source.start(); return 0
        }
    }
    package func stop() -> Int32 {
        lifecycle.withLock { value in
            guard !value.closed else { return 1 }
            guard value.running else { return 0 }
            value.running = false; value.stopping = true; reader.reset()
            source.stop { [weak self] in self?.lifecycle.withLock { $0.stopping = false } }
            return 0
        }
    }
    package func close() {
        _ = stop()
        lifecycle.withLock { $0.closed = true }
        reader.cancel()
    }
    deinit { reader.cancel() }
    package func discover(_ seconds: Double) -> Int32 {
        guard seconds.isFinite, (0.1...300).contains(seconds) else { return 1 }
        return lifecycle.withLock { value in
            guard value.running, !value.closed else { return 6 }
            source.discover(seconds: seconds); return 0
        }
    }
    package func read(maximum: Int) -> (events: [Switch2ControllerEvent], snapshot: Switch2ManagerSnapshot, resync: Bool, more: Bool, stopping: Bool) {
        lifecycle.withLock { value in
            let batch = reader.read(maximum: maximum)
            if !value.running || value.closed {
                let snapshot = Switch2ManagerSnapshot(isRunning: false, bluetooth: batch.snapshot.bluetooth,
                    discovery: .stopped, controllers: [])
                return ([], snapshot, true, false, value.stopping)
            }
            let snapshot = Switch2ManagerSnapshot(isRunning: true, bluetooth: batch.snapshot.bluetooth,
                discovery: batch.snapshot.discovery, controllers: batch.snapshot.controllers)
            return (batch.events, snapshot, batch.resync, batch.more, value.stopping)
        }
    }
    package func withController(id: UUID, connection: UUID,
                                operation: (Switch2Controller, any ControllerSource) -> Int32) -> Int32 {
        lifecycle.withLock { value in
            guard value.running, !value.closed,
                  let controller = source.hub.snapshot.controllers.first(where: {
                      $0.id.rawValue == id && $0.connectionID == connection
                  }) else { return 6 }
            return operation(controller, source)
        }
    }
}
