import Foundation
import Synchronization

// Reference storage avoids copying noncopyable Mutex captures in nested
// DispatchQueue closures on Apple Swift. Synchronization and assertions stay intact.
private final class IngressCounters: Sendable {
    let executed = Mutex(0)
    let overflow = Mutex(false)
}

@main enum ControlIngressTests {
    static func main() {
        let engine = BridgeEngine.fixture()
        let counters = IngressCounters()
        let queue = DispatchQueue(label: "control-test.events")
        let observation = try! engine.hub.observe(queue: queue, capacity: 256) { event in
            if case .failure(_, .operationQueueFull) = event { counters.overflow.withLock { $0 = true } }
        }
        var id = Switch2ControllerID(rawValue: UUID())
        engine.btQueue.sync {
            let peripheral = CBPeripheral(); id = .init(rawValue: peripheral.identifier)
            let session = ControllerSession(peripheral: peripheral, slot: 0, wasPairingMode: false,
                queue: engine.btQueue, delegate: engine)
            engine.connecting[peripheral.identifier] = (session, 0)
            engine.sessionReady(session)
        }
        engine.btQueue.suspend()
        for _ in 0..<10_000 {
            engine.withSession(id) { _ in counters.executed.withLock { $0 += 1 } }
            precondition(engine.controlInbox.withLock { $0.pending.count } <= 128)
        }
        engine.btQueue.resume()
        for _ in 0..<10 { engine.btQueue.sync {}; queue.sync {} }
        precondition(counters.executed.withLock { $0 } == 128 && counters.overflow.withLock { $0 })
        print("PASS operation ingress stays at 128, drains in batches and reports typed backpressure")
        engine.btQueue.sync {
            let old = engine.sessions[0]!
            engine.withSession(id) { _ in counters.executed.withLock { $0 += 1 } }
            engine.retire(old, cancel: false)
            let peripheral = CBPeripheral(); peripheral.identifier = id.rawValue
            let replacement = ControllerSession(peripheral: peripheral, slot: 0, wasPairingMode: false,
                queue: engine.btQueue, delegate: engine)
            engine.connecting[id.rawValue] = (replacement, 0)
            engine.sessionReady(replacement)
        }
        engine.btQueue.sync {}
        precondition(counters.executed.withLock { $0 } == 128, "An old operation reached a replacement session")
        engine.withSession(id) { _ in counters.executed.withLock { $0 += 1 } }
        engine.btQueue.sync {}
        precondition(counters.executed.withLock { $0 } == 129)
        engine.btQueue.sync {
            let current = engine.sessions[0]!, oldConnection = UUID()
            engine.submitRumble(id, strong: 0.3, weak: 0, duration: nil, expectedConnection: current.lifetime.id)
            engine.submitRumble(id, strong: 1, weak: 0, duration: nil, expectedConnection: oldConnection)
            precondition(engine.rumbleInbox.withLock { $0.pending[id]?.strong } == 0.3,
                         "An old caller must not overwrite a current connection's pending effect")
            engine.withSession(id, expectedConnection: oldConnection) { _ in counters.executed.withLock { $0 += 1 } }
            engine.disconnect(id, forget: true, expectedConnection: oldConnection)
        }
        engine.btQueue.sync {}
        precondition(counters.executed.withLock { $0 } == 129)
        engine.btQueue.sync { precondition(engine.sessions[0] != nil) }
        print("PASS caller-supplied connection tokens fence controls, disconnect and rumble coalescing")
        engine.stop(); engine.btQueue.sync {}
        engine.withSession(id) { _ in counters.executed.withLock { $0 += 1 } }
        engine.btQueue.sync {}
        precondition(counters.executed.withLock { $0 } == 129)
        observation.cancel()
        print("PASS queued controls cannot cross reconnect or post-stop generation boundaries")
    }
}
