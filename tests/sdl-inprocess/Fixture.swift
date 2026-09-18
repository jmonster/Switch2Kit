import Foundation
import Synchronization
import Switch2Kit
import Switch2KitC
import Switch2KitCABI

// This module is a test fixture, not part of the SDK or its distributions.
final class SDLTestSource: ControllerSource {
    let hub = ControllerEventHub()
    struct State: Sendable {
        var controllers: [Int32: Switch2Controller] = [:]
        var lifetimes: [Int32: SessionLifetime] = [:]
        var calls: [Switch2ControllerID: (count: UInt32, strong: Double, weak: Double)] = [:]
        var running = false
        var automaticDiscovery = false
        var discoveryConfigurationCount: UInt32 = 0
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
            value.running = false; value.stopCompletion = completion
            for token in value.lifetimes.values { token.retire() }
            value.controllers.removeAll(); value.lifetimes.removeAll()
            hub.publish(snapshot(value), event: .status(snapshot(value)))
        }
    }
    func discover(seconds: Double) {}
    func setAutomaticDiscovery(_ enabled: Bool) {
        // Record policy intent without simulating Bluetooth or changing ready sessions.
        state.withLock {
            $0.automaticDiscovery = enabled
            $0.discoveryConfigurationCount += 1
        }
    }
    func disconnect(id: Switch2ControllerID, connection: UUID, forget: Bool) {}
    func rumble(id: Switch2ControllerID, connection: UUID, strong: Double, weak: Double, duration: Double?, feedback: Bool) {
        state.withLock { value in
            let count = value.calls[id]?.count ?? 0
            value.calls[id] = (count + 1, strong, weak)
        }
    }
    func player(id: Switch2ControllerID, connection: UUID, number: Int) {}
    func report(index: Int32, model: Switch2ControllerModel, raw: S2KState) {
        state.withLock { value in
            let added = value.lifetimes[index] == nil
            let token = value.lifetimes[index] ?? SessionLifetime()
            value.lifetimes[index] = token
            let id = Switch2ControllerID(rawValue: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!)
            let c = Switch2Controller(id: id, model: model,
                state: .init(buttons: .init(rawValue: raw.buttons),
                    leftStick: model == .joyCon2Right ? nil : .init(x: raw.left_x, y: raw.left_y),
                    rightStick: model == .joyCon2Left ? nil : .init(x: raw.right_x, y: raw.right_y),
                    leftTrigger: .init(isPressed: raw.left_pressed != 0, travel: model == .nsoGameCube ? raw.left_travel : nil),
                    rightTrigger: .init(isPressed: raw.right_pressed != 0, travel: model == .nsoGameCube ? raw.right_travel : nil),
                    battery: .init(millivolts: 3900),
                    motion: raw.present & UInt32(S2K_HAS_MOTION) != 0 ? .init(
                        accelerationRaw: .init(x: raw.accel.0, y: raw.accel.1, z: raw.accel.2),
                        angularVelocityRaw: .init(x: raw.gyro.0, y: raw.gyro.1, z: raw.gyro.2),
                        magneticFieldRaw: .init(x: raw.magnetometer.0, y: raw.magnetometer.1, z: raw.magnetometer.2),
                        temperatureCelsius: raw.temperature_celsius) : nil, receivedAt: raw.received_at, sequence: raw.sequence),
                connectedAt: Date(), bodyColor: nil, buttonColor: nil, serialNumber: nil,
                sessionGeneration: token.id, lastActivityAt: 0)
            value.controllers[index] = c
            hub.publish(snapshot(value), event: added ? .connected(c) : .input(c), lifetime: token)
        }
    }
    func retire(_ index: Int32) {
        state.withLock { value in
            value.lifetimes.removeValue(forKey: index)?.retire()
            if let c = value.controllers.removeValue(forKey: index) {
                hub.publish(snapshot(value), event: .disconnected(c.id, .linkLost))
            }
        }
    }
}
private func source(_ handle: OpaquePointer) -> SDLTestSource {
    Unmanaged<CContext>.fromOpaque(UnsafeRawPointer(handle)).takeUnretainedValue().source as! SDLTestSource
}
@_cdecl("test_input_create")
public func fixtureCreate() -> OpaquePointer? { try? retainedHandle(CContext(source: SDLTestSource(), capacity: 256)) }
@_cdecl("test_input_report")
public func fixtureReport(_ handle: OpaquePointer, _ index: Int32, _ model: UInt32, _ input: UnsafePointer<S2KState>) {
    guard (0..<64).contains(index), let model = Switch2ControllerModel(rawValue: UInt16(clamping: model)) else { return }
    source(handle).report(index: index, model: model, raw: input.pointee)
}
@_cdecl("test_input_retire")
public func fixtureRetire(_ handle: OpaquePointer, _ index: Int32) { source(handle).retire(index) }
@_cdecl("test_input_rumble")
public func fixtureRumble(_ handle: OpaquePointer, _ index: Int32, _ strong: UnsafeMutablePointer<Double>, _ weak: UnsafeMutablePointer<Double>) -> UInt32 {
    let id = Switch2ControllerID(rawValue: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!)
    let value = source(handle).state.withLock { $0.calls[id] }
    strong.pointee = value?.strong ?? 0; weak.pointee = value?.weak ?? 0
    return value?.count ?? 0
}
