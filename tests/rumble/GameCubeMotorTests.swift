import Foundation

private final class MotorDelegate: ControllerSessionDelegate {
    func sessionReady(_ session: ControllerSession) {}
    func sessionFailed(_ session: ControllerSession, reason: String) { preconditionFailure(reason) }
    func sessionDidUpdateState(_ session: ControllerSession) {}
}

@main enum GameCubeMotorTests {
    static func main() {
        let queue = DispatchQueue(label: "gamecube.motor.tests")
        let delegate = MotorDelegate()
        func fixture() -> ControllerSession {
            let session = ControllerSession(peripheral: CBPeripheral(), slot: 0,
                wasPairingMode: false, queue: queue, delegate: delegate)
            session.model = .nsoGameCube
            session.handshakeComplete = true
            session.readyReported = true
            session.lastWriteAt = ProcessInfo.processInfo.systemUptime
            for id in [Switch2.GATT.commandWrite, Switch2.GATT.commandResponse,
                       Switch2.GATT.vibrationGameCube] {
                session.chars[id] = CBCharacteristic(id)
            }
            return session
        }
        queue.sync {
            precondition(Switch2.GATT.vibration(for: .nsoGameCube) ==
                UUID(uuidString: "3F8FB670-AB25-45BF-B540-38C72834D064"))
            precondition(Switch2.GATT.vibration(for: .nsoGameCube) != Switch2.GATT.vibrationPro)
            for sequence in 0...255 {
                for on in [false, true] {
                    let packet = Switch2.gameCubeMotorPacket(isRunning: on, packetID: UInt8(sequence))
                    precondition(packet == Data([0, 0x50 | UInt8(sequence & 15), on ? 1 : 0, 0, 0]))
                }
            }
            for value in [0.0, 0.01, 0.5, 1.0, Double.nan, Double.infinity, -1.0] {
                let motors = Switch2.MotorVibration.waveform(strong: 0, weak: value, model: .nsoGameCube)
                let packet = Switch2.motorPacket(motors, packetID: 17, model: .nsoGameCube)
                precondition(packet[2] == (value.isFinite && value > 0 ? 1 : 0))
                precondition(packet.count == 5 && packet[1] == 0x51)
            }
            let s = fixture(), radio = s.peripheral
            s.applyRumble(strong: 1, weak: 0)
            precondition(radio.writes.last!.0 == Data([0, 0x50, 1, 0, 0]))
            s.applyRumble(strong: 0, weak: 0)
            precondition(radio.writes.last!.0 == Data([0, 0x51, 0, 0, 0]))
            s.applyRumble(strong: 0, weak: 1)
            precondition(radio.writes.last!.0[2] == 1)
            s.rumbleSetAt = 0
            s.maintainTick()
            precondition(radio.writes.last!.0[2] == 0)
            precondition(radio.writes.allSatisfy { $0.1.uuid.uuidString == Switch2.GATT.vibrationGameCube.uuidString })
            s.teardown()
        }
        print("PASS GameCube channel, all sequence values, on/off, channels and stale stop")

        queue.sync {
            let s = fixture(), radio = s.peripheral
            radio.canSendWriteWithoutResponse = false
            s.applyRumble(strong: 1, weak: 0)
            s.applyRumble(strong: 0, weak: 0)
            precondition(radio.writes.isEmpty)
            radio.canSendWriteWithoutResponse = true
            s.peripheralIsReady(toSendWriteWithoutResponse: radio)
            precondition(radio.writes.count == 1 && radio.writes.last!.0[2] == 0)
            radio.canSendWriteWithoutResponse = false
            s.applyRumble(strong: 1, weak: 1)
            let pending = s.pendingMotor!
            s.pendingMotor = (pending.value, 0)
            radio.canSendWriteWithoutResponse = true
            s.peripheralIsReady(toSendWriteWithoutResponse: radio)
            precondition(radio.writes.last!.0[2] == 0)
            s.teardown()
        }
        print("PASS blocked radio coalesces stop and rejects expired on requests")

        queue.sync {
            let s = fixture(), radio = s.peripheral
            s.applyRumblePulse(strong: 1, weak: 0, duration: 0.1)
            precondition(s.rumbleStopTimer != nil && radio.writes.last!.0[2] == 1)
            s.applyRumblePulse(strong: 0, weak: 1, duration: 0.4)
            s.finishRumblePulse()
            precondition(radio.writes.last!.0[2] == 1)
            s.rumbleStopDeadline = 0
            s.finishRumblePulse()
            precondition(radio.writes.last!.0[2] == 0)
            s.applyRumble(strong: 1, weak: 0)
            s.teardown()
            precondition(radio.writes.last!.0[2] == 0)
            let count = radio.writes.count
            s.applyRumble(strong: 1, weak: 0)
            s.peripheralIsReady(toSendWriteWithoutResponse: radio)
            precondition(radio.writes.count == count)
        }
        print("PASS GameCube pulse replacement, expiry, retirement stop and no writes after retirement")

        queue.sync {
            for undersized in [false, true] {
                let s = fixture(), radio = s.peripheral
                if undersized { radio.writeLimit = 4 }
                else { s.chars.removeValue(forKey: Switch2.GATT.vibrationGameCube) }
                s.chars[Switch2.GATT.vibrationPro] = CBCharacteristic(Switch2.GATT.vibrationPro)
                s.applyRumble(strong: 1, weak: 0)
                precondition(radio.writes.isEmpty && s.pendingMotor == nil)
                precondition(!s.ended)
                s.teardown()
            }
        }
        print("PASS missing channel/short MTU does not send HD packets or break input")
    }
}
