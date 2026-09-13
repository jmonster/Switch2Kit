import Foundation
import Switch2Kit
import Switch2KitC

// Test-only C exports. Not linked into libSwitch2KitC or any distributable framework.
@_cdecl("s2k_fixture_create")
public func fixtureCreate() -> OpaquePointer? {
    try? retainedHandle(CContext(source: TestSource(), capacity: 8))
}
private func source(_ handle: OpaquePointer) -> TestSource {
    Unmanaged<CContext>.fromOpaque(UnsafeRawPointer(handle)).takeUnretainedValue().source as! TestSource
}
@_cdecl("s2k_fixture_emit")
public func fixtureEmit(_ handle: OpaquePointer, _ index: Int32, _ model: UInt32, _ sequence: UInt64, _ down: UInt32) {
    guard (0..<64).contains(index), let model = Switch2ControllerModel(rawValue: UInt16(clamping: model)) else { return }
    source(handle).emit(index: Int(index), model: model, sequence: sequence, pressed: down != 0)
}
@_cdecl("s2k_fixture_retire")
public func fixtureRetire(_ handle: OpaquePointer, _ index: Int32) { source(handle).retire(index: Int(index)) }
@_cdecl("s2k_fixture_finish_stop")
public func fixtureFinishStop(_ handle: OpaquePointer) { source(handle).finishStop() }
@_cdecl("s2k_fixture_calls")
public func fixtureCalls(_ handle: OpaquePointer) -> UInt32 { UInt32(source(handle).state.withLock { $0.calls.count }) }
