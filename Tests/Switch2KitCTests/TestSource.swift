import Foundation
import Synchronization
import Switch2Kit
import Switch2KitC

// Also compiled into the native C++ test fixture, never into a distribution library.
final class TestSource: ControllerSource {
    let hub = ControllerEventHub()
    struct State: Sendable {
        var running = false
        var controllers: [Int: Switch2Controller] = [:]
        var lifetimes: [Int: SessionLifetime] = [:]
        var calls: [String] = []
        var stopCompletion: (@Sendable () -> Void)?
    }
    let state = Mutex(State())
    func snapshot(_ value: State) -> Switch2ManagerSnapshot {
        .init(isRunning: value.running, bluetooth: .poweredOn, discovery: .paused,
              controllers: value.controllers.sorted { $0.key < $1.key }.map(\.value))
    }
    func start() { state.withLock { $0.running = true; hub.publish(snapshot($0), event: .status(snapshot($0))) } }
    func stop(completion: @escaping @Sendable () -> Void) {
        state.withLock { value in
            value.running = false
            for lifetime in value.lifetimes.values { lifetime.retire() }
            value.controllers.removeAll(); value.lifetimes.removeAll()
            value.stopCompletion = completion
            hub.publish(snapshot(value), event: .status(snapshot(value)))
        }
    }
    func finishStop() {
        let completion = state.withLock { value in let c = value.stopCompletion; value.stopCompletion = nil; return c }
        completion?()
    }
    func discover(seconds: Double) { state.withLock { $0.calls.append("discover") } }
    func disconnect(id: Switch2ControllerID, connection: UUID, forget: Bool) { state.withLock { $0.calls.append("disconnect") } }
    func rumble(id: Switch2ControllerID, connection: UUID, strong: Double, weak: Double, duration: Double?, feedback: Bool) {
        state.withLock { $0.calls.append(feedback ? "feedback" : "rumble") }
    }
    func player(id: Switch2ControllerID, connection: UUID, number: Int) { state.withLock { $0.calls.append("player") } }
    func emit(index: Int = 0, model: Switch2ControllerModel = .proController2,
              sequence: UInt64 = 1, pressed: Bool = false) {
        state.withLock { value in
            let fresh = value.lifetimes[index] == nil
            let lifetime = value.lifetimes[index] ?? SessionLifetime()
            value.lifetimes[index] = lifetime
            let id = Switch2ControllerID(rawValue: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!)
            let buttons: Switch2Buttons = pressed ? [.a, .zl] : []
            let controller = Switch2Controller(id: id, model: model,
                state: .init(buttons: buttons,
                    leftStick: model == .joyCon2Right ? nil : .init(x: -0.5, y: 1),
                    rightStick: model == .joyCon2Left ? nil : .init(x: 0.25, y: -1),
                    leftTrigger: .init(isPressed: pressed, travel: model == .nsoGameCube ? 0.25 : nil),
                    rightTrigger: .init(travel: model == .nsoGameCube ? 0.75 : nil),
                    battery: .init(millivolts: 3900, chargeStateRaw: 3, currentRaw: -42),
                    motion: .init(accelerationRaw: .init(x: -100, y: 200, z: 300),
                                  angularVelocityRaw: .init(x: -400, y: 500, z: 600),
                                  magneticFieldRaw: .init(x: 1, y: 2, z: 3), temperatureCelsius: 26),
                    optical: model == .joyCon2Left ? .init(xCounter: 65535, yCounter: 5, surfaceQualityRaw: 6, liftDistanceRaw: 7) : nil,
                    receivedAt: Double(sequence) / 120, sequence: sequence), connectedAt: Date(),
                bodyColor: nil, buttonColor: nil, serialNumber: nil,
                sessionGeneration: lifetime.id, lastActivityAt: 0)
            value.controllers[index] = controller
            hub.publish(snapshot(value), event: fresh ? .connected(controller) : .input(controller), lifetime: lifetime)
        }
    }
    func retire(index: Int = 0, publish: Bool = true) {
        state.withLock { value in
            value.lifetimes.removeValue(forKey: index)?.retire()
            if publish, let c = value.controllers.removeValue(forKey: index) {
                hub.publish(snapshot(value), event: .disconnected(c.id, .requested))
            }
        }
    }
}
