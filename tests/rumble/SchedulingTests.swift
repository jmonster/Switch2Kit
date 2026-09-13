import Foundation

private final class SchedulingDelegate: ControllerSessionDelegate {
    func sessionReady(_ session: ControllerSession) {}
    func sessionFailed(_ session: ControllerSession, reason: String) { preconditionFailure(reason) }
    func sessionDidUpdateState(_ session: ControllerSession) {}
}

@main enum SchedulingTests {
    static func main() {
        let queue = DispatchQueue(label: "rumble.scheduling")
        let delegate = SchedulingDelegate()
        func session(_ model: Switch2.Model) -> ControllerSession {
            let result = ControllerSession(peripheral: CBPeripheral(), slot: 0,
                wasPairingMode: false, queue: queue, delegate: delegate)
            result.model = model; result.handshakeComplete = true; result.readyReported = true
            result.lastWriteAt = ProcessInfo.processInfo.systemUptime
            for id in [Switch2.GATT.commandWrite, Switch2.GATT.commandResponse,
                       Switch2.GATT.vibration(for: model)] { result.chars[id] = CBCharacteristic(id) }
            return result
        }
        queue.sync {
            let s = session(.proController2)
            s.applyRumblePulse(strong: 0.3, weak: 0.2, duration: 0.4)
            let timer = s.rumbleStopTimer!
            for _ in 0..<10_000 {
                s.applyRumblePulse(strong: 0.4, weak: 0.1, duration: 0.4)
                precondition((s.rumbleStopTimer! as AnyObject) === (timer as AnyObject))
            }
            precondition(!timer.isCancelled && s.rumbleStopGeneration == s.rumbleGeneration)
            let writes = s.peripheral.writes.count
            s.finishRumblePulse() // A previously queued timer event must honor the replacement deadline.
            precondition(s.rumbleTarget.strong == 0.4 && s.peripheral.writes.count == writes)
            s.rumbleStopDeadline = 0
            s.finishRumblePulse()
            precondition(s.rumbleTarget.strong == 0 && s.rumbleTarget.weak == 0)
            precondition(s.rumbleStopDeadline == nil && s.rumbleStopGeneration == nil)
            precondition((s.rumbleStopTimer! as AnyObject) === (timer as AnyObject))
            s.applyRumblePulse(strong: 0.4, weak: 0, duration: 0.4)
            s.applyRumble(strong: 0.2, weak: 0.3)
            s.finishRumblePulse()
            precondition(s.rumbleTarget.strong == 0.2 && s.rumbleTarget.weak == 0.3)
            precondition(s.rumbleStopDeadline == nil)
            s.applyRumblePulse(strong: 0.8, weak: 0, duration: 0.4)
            s.teardown()
            precondition(timer.isCancelled && s.rumbleStopTimer == nil && s.rumbleStopDeadline == nil)
            let retiredWrites = s.peripheral.writes.count
            s.finishRumblePulse()
            s.applyRumblePulse(strong: 1, weak: 0, duration: 0.1)
            precondition(s.peripheral.writes.count == retiredWrites && s.rumbleStopTimer == nil)
        }
        print("PASS 10,000 pulses share one timer; replacement, continuous intent and retirement fence stop events")

        queue.sync {
            for model in Switch2.Model.allCases {
                let s = session(model)
                s.applyRumblePulse(strong: 0, weak: 0, duration: 0.2)
                precondition(s.rumbleStopTimer == nil)
                s.teardown()
            }
        }
        print("PASS silent pulses allocate no stop timer")

        queue.sync {
            for model in Switch2.Model.allCases {
                for scenario in 0..<4 {
                    let s = session(model), radio = s.peripheral
                    let feedbackID = model.hasHDRumble ? Switch2.GATT.vibration(for: model) : Switch2.GATT.commandWrite
                    switch scenario {
                    case 0: radio.canSendWriteWithoutResponse = false
                    case 1: s.setPlayerLEDs()
                    case 2: s.chars.removeValue(forKey: feedbackID)
                    default: radio.writeLimit = 0
                    }
                    let writes = radio.writes.count
                    var error: Switch2KitError?
                    s.applyRumbleFeedback(intensity: 0.5) { error = $0 }
                    precondition(error == (scenario < 2 ? .operationBusy : .protocolFailure))
                    precondition(radio.writes.count == writes && s.pendingMotor == nil)
                    precondition(s.rumbleStopTimer == nil && s.lastRumbleFeedbackAt == -.infinity)
                    radio.canSendWriteWithoutResponse = true
                    s.peripheralIsReady(toSendWriteWithoutResponse: radio)
                    precondition(radio.writes.count == writes, "Rejected feedback was delivered later")
                    if scenario != 1 {
                        radio.writeLimit = 512
                        s.chars[feedbackID] = CBCharacteristic(feedbackID)
                        s.applyRumbleFeedback(intensity: 0.5) { error = $0 }
                        if let frame = s.pendingCommand?.frame {
                            s.handleCommandResponse(Data([frame[0], 1, frame[2], frame[3], 0, 0, 0, 0]))
                        }
                        precondition(error == nil && radio.writes.count == writes + 1)
                        precondition((s.rumbleStopTimer != nil) == model.hasHDRumble)
                    }
                    s.teardown()
                }
            }
        }
        print("PASS every model rejects busy/missing/undersized writes without delayed feedback or consuming its rate allowance")

        queue.sync {
            let s = session(.proController2)
            s.applyRumblePulse(strong: 0.2, weak: 0.3, duration: 0.4)
            let deadline = s.rumbleStopDeadline, generation = s.rumbleStopGeneration
            s.peripheral.canSendWriteWithoutResponse = false
            var error: Switch2KitError?
            s.applyRumbleFeedback(intensity: 1) { error = $0 }
            precondition(error == .operationBusy)
            precondition(s.rumbleTarget.strong == 0.2 && s.rumbleTarget.weak == 0.3)
            precondition(s.rumbleStopDeadline == deadline && s.rumbleStopGeneration == generation)
            s.teardown()
        }
        print("PASS rejected feedback leaves an existing game pulse and its deadline intact")
    }
}
