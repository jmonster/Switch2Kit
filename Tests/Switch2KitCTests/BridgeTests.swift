import Foundation
import XCTest
import Switch2Kit
import Switch2KitCABI
@testable import Switch2KitC

final class BridgeTests: XCTestCase {
    func make(_ capacity: Int = 256) throws -> (TestSource, CContext, OpaquePointer) {
        let source = TestSource(), context = try CContext(source: source, capacity: capacity)
        return (source, context, retainedHandle(context))
    }
    func read(_ handle: OpaquePointer, capacity: Int = 256) -> (S2KSnapshot, [S2KEvent], UInt32) {
        var events = [S2KEvent](repeating: S2KEvent(), count: capacity)
        var snapshot = S2KSnapshot(), count: UInt32 = 999, flags: UInt32 = 999
        XCTAssertEqual(events.withUnsafeMutableBufferPointer {
            readContext(handle, $0.baseAddress, UInt32(capacity), UInt32(MemoryLayout<S2KEvent>.stride),
                        &count, &snapshot, UInt32(MemoryLayout<S2KSnapshot>.size), &flags)
        }, 0)
        return (snapshot, Array(events.prefix(Int(count))), flags)
    }
    func testVersionArgumentValidationAndNoPartialWrites() throws {
        XCTAssertEqual(abiVersion(), 1)
        var config = S2KConfig(abi_version: 2, struct_size: UInt32(MemoryLayout<S2KConfig>.size), maximum_controllers: 16, event_capacity: 256)
        var result: Int32 = -1
        XCTAssertNil(createContext(&config, &result)); XCTAssertEqual(result, 2)
        config.abi_version = 1; config.event_capacity = 0
        XCTAssertNil(createContext(&config, &result)); XCTAssertEqual(result, 1)
        XCTAssertEqual(startContext(nil), 1); destroyContext(nil)
        let (_, _, handle) = try make(); defer { destroyContext(handle) }
        var snapshot = S2KSnapshot(), count: UInt32 = 456, flags: UInt32 = 123, event = S2KEvent()
        XCTAssertEqual(readContext(handle, &event, 1, 1, &count, &snapshot, 1, &flags), 2)
        XCTAssertEqual(count, 456); XCTAssertEqual(flags, 123)
        XCTAssertEqual(readContext(handle, nil, 1, UInt32(MemoryLayout<S2KEvent>.stride), &count, &snapshot,
                                   UInt32(MemoryLayout<S2KSnapshot>.size), &flags), 1)
    }
    func testAllModelsFieldUnitsAndIdentityBytes() throws {
        let (source, _, handle) = try make(); defer { destroyContext(handle) }
        XCTAssertEqual(startContext(handle), 0)
        for (index, model) in Switch2ControllerModel.allCases.enumerated() { source.emit(index: index, model: model, pressed: true) }
        let (snapshot, events, flags) = read(handle)
        XCTAssertEqual(snapshot.count, 4); XCTAssertTrue(events.isEmpty); XCTAssertEqual(flags & 1, 1)
        withUnsafeBytes(of: snapshot.controllers) { bytes in
            let values = bytes.bindMemory(to: S2KController.self)
            for (i, model) in Switch2ControllerModel.allCases.enumerated() {
                let v = values[i]
                XCTAssertEqual(v.model, UInt32(model.rawValue)); XCTAssertEqual(v.state.buttons, Switch2Buttons([.a, .zl]).rawValue)
                XCTAssertEqual(v.state.left_pressed, 1); XCTAssertEqual(v.state.right_pressed, 0)
                XCTAssertEqual(v.state.present & 4 != 0, model == .nsoGameCube)
                XCTAssertEqual(v.state.present & 1 != 0, model != .joyCon2Right)
                XCTAssertEqual(v.state.present & 2 != 0, model != .joyCon2Left)
                XCTAssertEqual(v.state.accel.0, -100); XCTAssertEqual(v.state.gyro.1, 500)
                XCTAssertEqual(v.state.temperature_celsius, 26); XCTAssertEqual(v.state.battery_current_raw, -42)
                XCTAssertEqual(v.state.battery_millivolts, 3900); XCTAssertEqual(v.state.sequence, 1)
                XCTAssertEqual(withUnsafeBytes(of: v.id.bytes) { $0[15] }, UInt8(i + 1))
                XCTAssertEqual(cID(swiftID(v.id)).bytes.15, UInt8(i + 1))
            }
        }
    }
    func testFIFOEdgesCapacityZeroAndPartialReads() throws {
        let (source, _, handle) = try make(); defer { destroyContext(handle) }
        _ = startContext(handle); source.emit(); _ = read(handle)
        for n in 2...101 { source.emit(sequence: UInt64(n), pressed: n % 2 == 0) }
        XCTAssertTrue(read(handle, capacity: 0).1.isEmpty)
        var observed: [UInt64] = []
        for _ in 0..<10 {
            let (_, events, flags) = read(handle, capacity: 10)
            XCTAssertEqual(flags & 1, 0)
            for event in events {
                let n = event.controller.state.sequence
                XCTAssertEqual(event.kind, 1); XCTAssertEqual(event.controller.state.buttons != 0, n % 2 == 0)
                observed.append(n)
            }
        }
        XCTAssertEqual(observed, Array(2...101).map(UInt64.init)); XCTAssertEqual(read(handle).2, 0)
    }
    func testOverflowResynchronizesWithoutUnboundedHistory() throws {
        let (source, context, handle) = try make(4); defer { destroyContext(handle) }
        _ = startContext(handle); source.emit(); _ = read(handle)
        for n in 2...10_001 { source.emit(sequence: UInt64(n), pressed: n % 2 == 0) }
        let (_, events, flags) = read(handle)
        XCTAssertTrue(events.isEmpty); XCTAssertEqual(flags & 1, 1)
        source.emit(sequence: 10_002, pressed: false)
        XCTAssertEqual(context.read(maximum: 4).events.count, 1)
    }
    func testRetirementAndReplacementCannotDeliverOrControlOldAttempt() throws {
        let (source, _, handle) = try make(); defer { destroyContext(handle) }
        _ = startContext(handle); source.emit(); let (first, _, _) = read(handle)
        var old = first.controllers.0
        source.emit(sequence: 2, pressed: true); source.retire(publish: false)
        let (empty, pending, flags) = read(handle)
        XCTAssertEqual(empty.count, 0); XCTAssertTrue(pending.isEmpty); XCTAssertEqual(flags & 1, 1)
        source.emit(sequence: 1)
        XCTAssertEqual(setRumble(handle, &old.id, &old.connection_id, 1, 0), 6)
        XCTAssertEqual(disconnectController(handle, &old.id, &old.connection_id, 0), 6)
        XCTAssertTrue(source.state.withLock { $0.calls.isEmpty })
        var new = read(handle).0.controllers.0
        XCTAssertNotEqual(swiftID(new.connection_id), swiftID(old.connection_id))
        XCTAssertEqual(setRumble(handle, &new.id, &new.connection_id, 0.5, 0.3), 0)
        XCTAssertEqual(source.state.withLock { $0.calls }, ["rumble"])
    }
    func testStopIsIdempotentFencesDeliveryAndCanRestartAfterTeardown() throws {
        let (source, _, handle) = try make(); defer { destroyContext(handle) }
        XCTAssertEqual(discoverContext(handle, 60), 6)
        _ = startContext(handle); source.emit(); _ = read(handle)
        XCTAssertEqual(discoverContext(handle, .nan), 1)
        XCTAssertEqual(stopContext(handle), 0); XCTAssertEqual(stopContext(handle), 0)
        XCTAssertEqual(startContext(handle), 5)
        let stopped = read(handle).0
        XCTAssertEqual(stopped.count, 0); XCTAssertEqual(stopped.running, 0); XCTAssertEqual(stopped.stopping, 1)
        source.finishStop(); XCTAssertEqual(read(handle).0.stopping, 0)
        XCTAssertEqual(startContext(handle), 0); XCTAssertEqual(startContext(handle), 0)
        source.emit(); XCTAssertEqual(read(handle).0.count, 1)
    }
    func testModelAwareRumbleAndInvalidValuesDoNotReachSource() throws {
        let (source, _, handle) = try make(); defer { destroyContext(handle) }
        _ = startContext(handle); source.emit(model: .nsoGameCube)
        var c = read(handle).0.controllers.0
        XCTAssertEqual(setRumble(handle, &c.id, &c.connection_id, 1, 0), 7)
        XCTAssertEqual(pulseRumble(handle, &c.id, &c.connection_id, 1, 0, 0.2), 7)
        XCTAssertEqual(playFeedback(handle, &c.id, &c.connection_id, .infinity), 1)
        XCTAssertEqual(setPlayer(handle, &c.id, &c.connection_id, 9), 1)
        XCTAssertEqual(playFeedback(handle, &c.id, &c.connection_id, 0.5), 0)
        XCTAssertEqual(source.state.withLock { $0.calls }, ["feedback"])
    }
    func testReaderAdmissionAndCancellationReleaseSlots() throws {
        let hub = ControllerEventHub()
        let readers = try (0..<32).map { _ in try hub.makeReader(capacity: 1) }
        XCTAssertThrowsError(try hub.makeReader(capacity: 1))
        readers[0].cancel(); let extra = try hub.makeReader(capacity: 256); extra.cancel()
        hub.cancelAll() // Must not re-enter the hub mutex from reader cancellation.
        let next = try hub.makeReader(capacity: 1); next.cancel()
    }
}
