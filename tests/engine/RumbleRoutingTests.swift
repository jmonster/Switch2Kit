import Foundation
import Synchronization

private final class RumbleErrors: Sendable {
    let values = Mutex<[Switch2KitError]>([])
}

@main enum RumbleRoutingTests {
    static func main() {
        let engine = ControllerTransport.fixture()
        let errors = RumbleErrors()
        let delivery = DispatchQueue(label: "rumble.events")
        let observation = try! engine.hub.observe(queue: delivery, capacity: 256) { event in
            if case .failure(_, let error) = event { errors.values.withLock { $0.append(error) } }
        }
        defer { observation.cancel(); engine.stop(); engine.btQueue.sync {} }
        func drain() { for _ in 0..<3 { engine.btQueue.sync {}; delivery.sync {} } }
        func add(_ model: Switch2.Model, slot: Int, id: UUID = UUID()) -> ControllerSession {
            let radio = CBPeripheral(); radio.identifier = id
            let session = ControllerSession(peripheral: radio, slot: slot, wasPairingMode: false,
                                            queue: engine.btQueue, delegate: engine)
            session.model = model; session.handshakeComplete = true; session.readyReported = true
            session.lastWriteAt = ProcessInfo.processInfo.systemUptime
            for uuid in [Switch2.GATT.commandWrite, Switch2.GATT.commandResponse,
                         Switch2.GATT.inputReport, Switch2.GATT.vibration(for: model)] {
                session.chars[uuid] = CBCharacteristic(uuid)
            }
            engine.connecting[id] = (session, slot)
            engine.sessionReady(session)
            return session
        }
        func ack(_ session: ControllerSession, success: Bool = true) {
            let frame = session.pendingCommand!.frame
            session.handleCommandResponse(Data([frame[0], success ? 1 : 2, frame[2], frame[3], 0, 0, 0, 0]))
        }
        var controllers: [ControllerSession] = []
        engine.btQueue.sync {
            for (slot, model) in Switch2.Model.allCases.enumerated() { controllers.append(add(model, slot: slot)) }
        }
        let ids = engine.hub.snapshot.controllers.map(\.id)
        for id in ids { engine.submitRumble(id, strong: 0.3, weak: 0, duration: nil, feedback: true) }
        drain()
        engine.btQueue.sync {
            for session in controllers {
                let writes = session.peripheral.writes
                precondition(writes.count == 1)
                if session.model == .nsoGameCube {
                    precondition(writes[0].1.uuid.uuidString == Switch2.GATT.commandWrite.uuidString)
                    precondition(writes[0].0 == Data([0x0a, 0x91, 1, 2, 0, 4, 0, 0, 3, 0, 0, 0]))
                    ack(session, success: false)
                } else {
                    precondition(writes[0].1.uuid.uuidString == Switch2.GATT.vibration(for: session.model).uuidString)
                }
            }
        }
        drain()
        precondition(errors.values.withLock { $0.contains(.protocolFailure) })
        print("PASS normal rumble transport routes all four models and reports command rejection")

        let gc = controllers.first { $0.model == .nsoGameCube }!
        let id = Switch2ControllerID(rawValue: gc.peripheral.identifier)
        engine.btQueue.sync { gc.lastRumbleFeedbackAt = -.infinity; gc.peripheral.writes.removeAll() }
        engine.btQueue.suspend()
        for _ in 0..<10_000 {
            engine.submitRumble(id, strong: 0.8, weak: 0, duration: nil, feedback: true)
            precondition(engine.rumbleInbox.withLock { $0.pending.count } == 1)
        }
        engine.btQueue.resume(); drain()
        engine.btQueue.sync {
            precondition(gc.peripheral.writes.count == 1 && gc.queuedCommands.isEmpty)
            precondition(gc.peripheral.writes[0].0.suffix(4) == Data([2, 0, 0, 0])); ack(gc)
        }
        engine.submitRumble(id, strong: 0.2, weak: 0, duration: nil, feedback: true); drain()
        precondition(errors.values.withLock { $0.contains(.operationBusy) })
        engine.btQueue.sync { precondition(gc.peripheral.writes.count == 1) }
        print("PASS 10,000 feedback requests coalesce to one frame with typed rate backpressure")

        engine.btQueue.sync {
            gc.lastRumbleFeedbackAt = -.infinity; gc.peripheral.writes.removeAll()
            engine.submitRumble(id, strong: 1, weak: 0, duration: nil, feedback: true)
            engine.rumbleInbox.withLock { inbox in
                let intent = inbox.pending[id]!
                inbox.pending[id] = .init(strong: intent.strong, weak: intent.weak, duration: intent.duration,
                    feedback: intent.feedback, submittedAt: 0, generation: intent.generation)
            }
        }
        drain()
        engine.btQueue.sync { precondition(gc.peripheral.writes.isEmpty) }
        var replacement: ControllerSession!
        engine.btQueue.sync {
            engine.submitRumble(id, strong: 1, weak: 0, duration: nil, feedback: true)
            engine.retire(gc, cancel: false)
            replacement = add(.nsoGameCube, slot: gc.slot, id: id.rawValue)
        }
        drain()
        engine.btQueue.sync { precondition(replacement.peripheral.writes.isEmpty) }
        engine.stop(); drain()
        engine.submitRumble(id, strong: 1, weak: 0, duration: nil, feedback: true); drain()
        precondition(errors.values.withLock { $0.contains(.controllerNotReady) })
        engine.btQueue.sync { precondition(replacement.peripheral.writes.isEmpty) }
        print("PASS feedback expiry, reconnect generation and terminal stop suppress delayed presets")
    }
}
