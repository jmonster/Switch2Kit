import Foundation
import Synchronization

private final class Events: Sendable {
    let failures = Mutex(0)
}

@main enum RumbleRoutingTests {
    static func ready(_ engine: ControllerTransport, model: Switch2.Model,
                      id: UUID = UUID()) -> ControllerSession {
        let peripheral = CBPeripheral()
        peripheral.identifier = id
        let session = ControllerSession(peripheral: peripheral, slot: 0, wasPairingMode: false,
                                        queue: engine.btQueue, delegate: engine)
        session.model = model
        session.handshakeComplete = true
        session.readyReported = true
        session.lastWriteAt = ProcessInfo.processInfo.systemUptime
        for uuid in [Switch2.GATT.commandWrite, Switch2.GATT.commandResponse,
                     Switch2.GATT.inputReport, Switch2.GATT.vibration(for: model)] {
            session.chars[uuid] = CBCharacteristic(uuid)
        }
        engine.connecting[id] = (session, 0)
        engine.sessionReady(session)
        return session
    }
    static func main() {
        for model in Switch2.Model.allCases {
            let engine = ControllerTransport.fixture()
            let queue = DispatchQueue(label: "rumble.events")
            let events = Events()
            let observation = try! engine.hub.observe(queue: queue, capacity: 256) { event in
                if case .failure(_, .operationQueueFull) = event { events.failures.withLock { $0 += 1 } }
            }
            let session = engine.btQueue.sync { ready(engine, model: model) }
            let id = Switch2ControllerID(rawValue: session.peripheral.identifier)
            engine.submitRumble(id, strong: 0.25, weak: 0, duration: 0.15)
            engine.btQueue.sync {
                let writes = session.peripheral.writes
                precondition(!writes.isEmpty)
                if model == .nsoGameCube {
                    precondition(writes.count == 1)
                    precondition(writes[0].0 == Data([0x0a,0x91,1,2,0,4,0,0,3,0,0,0]))
                    precondition(writes[0].1.uuid.uuidString == Switch2.GATT.commandWrite.uuidString)
                } else {
                    precondition(writes.contains { $0.1.uuid.uuidString == Switch2.GATT.vibration(for: model).uuidString })
                }
            }
            if model == .nsoGameCube {
                engine.submitRumble(id, strong: 0.8, weak: 0, duration: nil)
                engine.btQueue.sync {}; queue.sync {}
                precondition(events.failures.withLock { $0 } == 1)
                engine.btQueue.sync {
                    precondition(session.peripheral.writes.count == 1 && session.queuedCommands.isEmpty)
                    session.handleCommandResponse(Data([0x0a,1,1,2,0,0,0,0]))
                    session.lastRumbleTestAt = -.infinity
                }
                engine.submitRumble(id, strong: 0, weak: 0.8, duration: nil)
                engine.btQueue.sync {
                    precondition(session.peripheral.writes.last!.0 == Data([0x0a,0x91,1,2,0,4,0,0,2,0,0,0]))
                    session.handleCommandResponse(Data([0x0a,1,1,2,0,0,0,0]))
                }
                engine.submitRumble(id, strong: 0, weak: 0, duration: nil)
                engine.btQueue.sync { precondition(session.peripheral.writes.count == 2) }
                print("PASS GameCube pulse and intent routing, exact soft/strong frames, mute and bounded busy reporting")
            }
            let replacement = engine.btQueue.sync {
                engine.submitRumble(id, strong: 1, weak: 1, duration: 0.15)
                engine.retire(session, cancel: false)
                return ready(engine, model: model, id: id.rawValue)
            }
            engine.btQueue.sync { precondition(replacement.peripheral.writes.isEmpty) }
            engine.stop(); engine.btQueue.sync {}
            observation.cancel()
        }
        print("PASS every model routes through its motor protocol; retired intents cannot reach replacement sessions")
    }
}
