import Foundation
import Switch2Kit
import Switch2KitCABI

package func retainedHandle(_ context: CContext) -> OpaquePointer {
    OpaquePointer(Unmanaged.passRetained(context).toOpaque())
}
private func context(_ handle: OpaquePointer?) -> CContext? {
    guard let handle else { return nil }
    return Unmanaged<CContext>.fromOpaque(UnsafeRawPointer(handle)).takeUnretainedValue()
}

/// C ABI entry point; ownership, threading and argument rules are specified in Switch2KitC.h.
@_cdecl("s2k_abi_version")
public func abiVersion() -> UInt32 { 1 }

/// C ABI entry point; ownership, threading and argument rules are specified in Switch2KitC.h.
@_cdecl("s2k_create")
public func createContext(_ config: UnsafePointer<S2KConfig>?, _ result: UnsafeMutablePointer<Int32>?) -> OpaquePointer? {
    let capacity = config.map { Int($0.pointee.event_capacity) } ?? 256
    let maximum = config.map { Int($0.pointee.maximum_controllers) } ?? 16
    if let config, config.pointee.abi_version != 1 || config.pointee.struct_size != MemoryLayout<S2KConfig>.size {
        result?.pointee = 2; return nil
    }
    guard (1...256).contains(capacity), (1...64).contains(maximum) else { result?.pointee = 1; return nil }
    #if canImport(CoreBluetooth)
    guard Thread.isMainThread else { result?.pointee = 4; return nil }
    do {
        let source = MainActor.assumeIsolated { ManagerSource(maximumControllers: maximum) }
        let handle = retainedHandle(try CContext(source: source, capacity: capacity))
        result?.pointee = 0; return handle
    } catch { result?.pointee = cError(error); return nil }
    #else
    result?.pointee = 3; return nil
    #endif
}

/// C ABI entry point; ownership, threading and argument rules are specified in Switch2KitC.h.
@_cdecl("s2k_destroy")
public func destroyContext(_ handle: OpaquePointer?) {
    guard let handle else { return }
    let value = Unmanaged<CContext>.fromOpaque(UnsafeRawPointer(handle)).takeRetainedValue()
    value.close()
}
/// C ABI entry point; ownership, threading and argument rules are specified in Switch2KitC.h.
@_cdecl("s2k_start")
public func startContext(_ handle: OpaquePointer?) -> Int32 { context(handle)?.start() ?? 1 }
/// C ABI entry point; ownership, threading and argument rules are specified in Switch2KitC.h.
@_cdecl("s2k_stop")
public func stopContext(_ handle: OpaquePointer?) -> Int32 { context(handle)?.stop() ?? 1 }
/// C ABI entry point; ownership, threading and argument rules are specified in Switch2KitC.h.
@_cdecl("s2k_discover")
public func discoverContext(_ handle: OpaquePointer?, _ seconds: Double) -> Int32 { context(handle)?.discover(seconds) ?? 1 }

/// C ABI entry point; ownership, threading and argument rules are specified in Switch2KitC.h.
@_cdecl("s2k_read")
public func readContext(_ handle: OpaquePointer?, _ events: UnsafeMutablePointer<S2KEvent>?,
    _ capacity: UInt32, _ stride: UInt32, _ count: UnsafeMutablePointer<UInt32>?,
    _ snapshot: UnsafeMutablePointer<S2KSnapshot>?, _ snapshotSize: UInt32,
    _ flags: UnsafeMutablePointer<UInt32>?) -> Int32 {
    guard let value = context(handle), let count, let snapshot, let flags,
          capacity <= 4096, capacity == 0 || events != nil else { return 1 }
    guard stride == MemoryLayout<S2KEvent>.stride,
          snapshotSize == MemoryLayout<S2KSnapshot>.size else { return 2 }
    let batch = value.read(maximum: Int(capacity))
    snapshot.pointee = cSnapshot(batch.snapshot, stopping: batch.stopping)
    count.pointee = UInt32(batch.events.count)
    flags.pointee = (batch.resync ? 1 : 0) | (batch.more ? 2 : 0)
    for (index, event) in batch.events.enumerated() { events?[index] = cEvent(event) }
    return 0
}

private func control(_ handle: OpaquePointer?, _ id: UnsafePointer<S2KID>?, _ connection: UnsafePointer<S2KID>?,
                     _ operation: (Switch2Controller, any ControllerSource) -> Int32) -> Int32 {
    guard let context = context(handle), let id, let connection else { return 1 }
    return context.withController(id: swiftID(id.pointee), connection: swiftID(connection.pointee), operation: operation)
}
/// C ABI entry point; ownership, threading and argument rules are specified in Switch2KitC.h.
@_cdecl("s2k_disconnect")
public func disconnectController(_ handle: OpaquePointer?, _ id: UnsafePointer<S2KID>?,
                                 _ connection: UnsafePointer<S2KID>?, _ forget: UInt32) -> Int32 {
    guard forget <= 1 else { return 1 }
    return control(handle, id, connection) { c, source in
        source.disconnect(id: c.id, connection: c.connectionID, forget: forget == 1); return 0
    }
}
private func rumble(_ handle: OpaquePointer?, _ id: UnsafePointer<S2KID>?, _ connection: UnsafePointer<S2KID>?,
                    strong: Double, weak: Double, duration: Double?, feedback: Bool) -> Int32 {
    guard strong.isFinite, weak.isFinite, (0...1).contains(strong), (0...1).contains(weak) else { return 1 }
    if let duration, !duration.isFinite || !(0.01...0.5).contains(duration) { return 1 }
    return control(handle, id, connection) { c, source in
        guard feedback || c.capabilities.contains(.continuousRumble) else { return 7 }
        source.rumble(id: c.id, connection: c.connectionID, strong: strong, weak: weak, duration: duration, feedback: feedback)
        return 0
    }
}
/// C ABI entry point; ownership, threading and argument rules are specified in Switch2KitC.h.
@_cdecl("s2k_play_feedback")
public func playFeedback(_ handle: OpaquePointer?, _ id: UnsafePointer<S2KID>?, _ connection: UnsafePointer<S2KID>?,
                         _ intensity: Double) -> Int32 { rumble(handle, id, connection, strong: intensity, weak: 0, duration: nil, feedback: true) }
/// C ABI entry point; ownership, threading and argument rules are specified in Switch2KitC.h.
@_cdecl("s2k_set_rumble")
public func setRumble(_ handle: OpaquePointer?, _ id: UnsafePointer<S2KID>?, _ connection: UnsafePointer<S2KID>?,
                      _ strong: Double, _ weak: Double) -> Int32 { rumble(handle, id, connection, strong: strong, weak: weak, duration: nil, feedback: false) }
/// C ABI entry point; ownership, threading and argument rules are specified in Switch2KitC.h.
@_cdecl("s2k_pulse_rumble")
public func pulseRumble(_ handle: OpaquePointer?, _ id: UnsafePointer<S2KID>?, _ connection: UnsafePointer<S2KID>?,
                        _ strong: Double, _ weak: Double, _ seconds: Double) -> Int32 { rumble(handle, id, connection, strong: strong, weak: weak, duration: seconds, feedback: false) }
/// C ABI entry point; ownership, threading and argument rules are specified in Switch2KitC.h.
@_cdecl("s2k_set_player")
public func setPlayer(_ handle: OpaquePointer?, _ id: UnsafePointer<S2KID>?, _ connection: UnsafePointer<S2KID>?, _ number: UInt32) -> Int32 {
    guard (1...8).contains(number) else { return 1 }
    return control(handle, id, connection) { c, source in source.player(id: c.id, connection: c.connectionID, number: Int(number)); return 0 }
}
