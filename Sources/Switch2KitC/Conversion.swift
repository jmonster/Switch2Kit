import Foundation
import Switch2Kit
import Switch2KitCABI

func cID(_ id: UUID) -> S2KID {
    var value = S2KID()
    withUnsafeMutableBytes(of: &value.bytes) { out in
        withUnsafeBytes(of: id.uuid) { out.copyBytes(from: $0) }
    }
    return value
}
func swiftID(_ value: S2KID) -> UUID {
    withUnsafeBytes(of: value.bytes) { bytes in
        UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                    bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
func cController(_ controller: Switch2Controller) -> S2KController {
    var out = S2KController()
    out.id = cID(controller.id.rawValue); out.connection_id = cID(controller.connectionID)
    out.model = UInt32(controller.model.rawValue); out.capabilities = UInt32(controller.capabilities.rawValue)
    let s = controller.state
    out.state.sequence = s.sequence; out.state.received_at = s.receivedAt; out.state.buttons = s.buttons.rawValue
    if let v = s.leftStick { out.state.present |= 1; out.state.left_x = v.x; out.state.left_y = v.y }
    if let v = s.rightStick { out.state.present |= 2; out.state.right_x = v.x; out.state.right_y = v.y }
    if let v = s.leftTrigger.travel { out.state.present |= 4; out.state.left_travel = v }
    if let v = s.rightTrigger.travel { out.state.present |= 8; out.state.right_travel = v }
    out.state.left_pressed = s.leftTrigger.isPressed ? 1 : 0
    out.state.right_pressed = s.rightTrigger.isPressed ? 1 : 0
    if let v = s.battery.millivolts { out.state.present |= 16; out.state.battery_millivolts = v }
    out.state.battery_current_raw = s.battery.currentRaw; out.state.charge_state_raw = s.battery.chargeStateRaw
    if let m = s.motion {
        out.state.present |= 32
        out.state.accel = (m.accelerationRaw.x, m.accelerationRaw.y, m.accelerationRaw.z)
        out.state.gyro = (m.angularVelocityRaw.x, m.angularVelocityRaw.y, m.angularVelocityRaw.z)
        out.state.magnetometer = (m.magneticFieldRaw.x, m.magneticFieldRaw.y, m.magneticFieldRaw.z)
        out.state.temperature_celsius = m.temperatureCelsius
    }
    if let o = s.optical {
        out.state.present |= 64; out.state.optical_x = o.xCounter; out.state.optical_y = o.yCounter
        out.state.surface_quality = o.surfaceQualityRaw; out.state.lift_distance = o.liftDistanceRaw
    }
    return out
}
func cSnapshot(_ snapshot: Switch2ManagerSnapshot, stopping: Bool) -> S2KSnapshot {
    var out = S2KSnapshot()
    out.abi_version = 1; out.running = snapshot.isRunning ? 1 : 0; out.stopping = stopping ? 1 : 0
    switch snapshot.bluetooth {
    case .unknown: out.bluetooth = 0
    case .resetting: out.bluetooth = 1
    case .unsupported: out.bluetooth = 2
    case .unauthorized: out.bluetooth = 3
    case .poweredOff: out.bluetooth = 4
    case .poweredOn: out.bluetooth = 5
    }
    switch snapshot.discovery {
    case .stopped: out.discovery = 0
    case .scanning(let deadline): out.discovery = 1; out.discovery_deadline = deadline ?? 0
    case .connecting: out.discovery = 2
    case .paused: out.discovery = 3
    case .capacityReached: out.discovery = 4
    }
    out.count = UInt32(min(64, snapshot.controllers.count))
    withUnsafeMutablePointer(to: &out.controllers) { pointer in
        pointer.withMemoryRebound(to: S2KController.self, capacity: 64) { destination in
            for (index, controller) in snapshot.controllers.prefix(64).enumerated() {
                destination[index] = cController(controller)
            }
        }
    }
    return out
}
func cError(_ error: Error) -> S2KResult {
    guard let error = error as? Switch2KitError else { return 13 }
    switch error {
    case .invalidParameter: return 1
    case .operationBusy: return 5
    case .controllerNotReady: return 6
    case .unsupportedOperation: return 7
    case .operationQueueFull, .observerLimitReached: return 8
    case .bluetoothUnavailable: return 9
    case .protocolFailure: return 10
    case .timedOut: return 11
    case .connectionFailed: return 12
    }
}
func cEvent(_ event: Switch2ControllerEvent) -> S2KEvent {
    var out = S2KEvent()
    switch event {
    case .input(let controller): out.kind = 1; out.controller = cController(controller)
    case .connected(let controller): out.kind = 2; out.controller = cController(controller)
    case .disconnected(let id, let reason):
        out.kind = 3; out.controller.id = cID(id.rawValue)
        switch reason {
        case .linkLost: out.detail = 1
        case .requested: out.detail = 2
        case .forgotten: out.detail = 3
        case .stopped: out.detail = 4
        case .bluetoothUnavailable: out.detail = 5
        case .timeout: out.detail = 6
        case .protocolFailure: out.detail = 7
        }
    case .snapshot, .status: out.kind = 4
    case .connectionChanged(let id, let phase):
        out.kind = 5; out.controller.id = cID(id.rawValue)
        switch phase {
        case .connecting: out.detail = 1
        case .handshaking: out.detail = 2
        case .ready: out.detail = 3
        case .disconnected: out.detail = 4
        }
    case .failure(let id, let error):
        out.kind = 6; out.detail = cError(error)
        if let id { out.controller.id = cID(id.rawValue) }
    case .signalStrengthChanged(let id, let db):
        out.kind = 7; out.detail = Int32(clamping: db); out.controller.id = cID(id.rawValue)
    }
    return out
}
