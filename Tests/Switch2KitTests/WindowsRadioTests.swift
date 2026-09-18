#if os(Windows)
import Foundation
import XCTest
import Switch2KitWinRT
@testable import Switch2Kit

private final class RadioBoundary: WindowsRadio {
    var events: [S2WEvent] = []
    var scans: [Bool] = []
    var tokens: [UInt64] = []
    var cancellations: [UInt64] = []
    var writes: [Data] = []
    var acceptsCancellation = true
    var closed = false
    func next() -> S2WEvent? { events.isEmpty ? nil : events.removeFirst() }
    func scan(_ enabled: Bool) -> Bool { scans.append(enabled); return true }
    func connect(token: UInt64, address: UInt64, type: UInt32) -> Bool { tokens.append(token); return true }
    func cancel(_ token: UInt64) -> Bool { cancellations.append(token); return acceptsCancellation }
    func discover(_ token: UInt64) -> Bool { true }
    func notify(_ token: UInt64, index: UInt32, enabled: Bool) -> Bool { true }
    func write(_ token: UInt64, index: UInt32, data: Data) -> Bool { writes.append(data); return true }
    func close() { closed = true }
}
private final class RadioObserver: CBCentralManagerDelegate, CBPeripheralDelegate {
    var found: [WindowsPeripheral] = []
    var stateChanges = 0, connected = 0, disconnected = 0, failed = 0, values = 0
    func centralManagerDidUpdateState(_ central: CBCentralManager) { stateChanges += 1 }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) { found.append(peripheral) }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) { connected += 1 }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) { failed += 1 }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) { disconnected += 1 }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {}
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {}
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {}
    func peripheral(_ peripheral: CBPeripheral, didReadRSSI rssi: NSNumber, error: Error?) {}
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {}
    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {}
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) { values += 1 }
}
final class WindowsRadioTests: XCTestCase {
    private func event(_ kind: UInt32, token: UInt64 = 0) -> S2WEvent {
        var e = S2WEvent(); e.kind = kind; e.token = token; return e
    }
    private func setup() -> (WindowsCentral, RadioBoundary, RadioObserver) {
        let observer = RadioObserver(), radio = RadioBoundary()
        let central = WindowsCentral(delegate: observer, queue: DispatchQueue(label: "test.windows-radio"), factory: { radio })
        // Drive the real adaptation layer synchronously; only the OS boundary is replaced.
        central.driver = radio
        var ready = event(UInt32(S2W_STATE)); ready.status = 5
        central.receive(ready)
        central.scanForPeripherals(withServices: nil, options: nil)
        return (central, radio, observer)
    }
    private func advertisement(address: UInt64 = 42, model: UInt16 = 0x2073) -> S2WEvent {
        var e = event(UInt32(S2W_ADVERTISEMENT)); e.address = address
        e.host_address = 0x010203040506; e.address_type = 0; e.length = 18
        var bytes = [UInt8](repeating: 0, count: 18)
        bytes[0] = 0x53; bytes[1] = 0x05; bytes[5] = 0x7e; bytes[6] = 0x05
        bytes[7] = UInt8(truncatingIfNeeded: model); bytes[8] = UInt8(truncatingIfNeeded: model >> 8)
        withUnsafeMutableBytes(of: &e.bytes) { $0.copyBytes(from: bytes) }
        return e
    }
    private func connect(_ central: WindowsCentral, _ observer: RadioObserver) throws -> WindowsPeripheral {
        central.receive(advertisement())
        let p = try XCTUnwrap(observer.found.last); p.delegate = observer
        central.connect(p, options: nil)
        var connected = event(UInt32(S2W_CONNECTED), token: p.token); connected.flags = 67
        central.receive(connected)
        return p
    }
    func testRecognizedModelsAdmissionAndBoundedAdvertisements() {
        let (central, radio, observer) = setup(); defer { central.shutdown() }
        for (index, model) in [UInt16(0x2073), 0x2069, 0x2067, 0x2066].enumerated() {
            central.receive(advertisement(address: UInt64(index + 1), model: model))
        }
        XCTAssertEqual(observer.found.count, 4)
        central.receive(advertisement(address: 5, model: 0xffff))
        XCTAssertEqual(observer.found.count, 4)
        for address in 1...1000 { central.receive(advertisement(address: UInt64(address))) }
        XCTAssertEqual(observer.found.count, 128)
        XCTAssertEqual(radio.scans, [true])
    }
    func testCancelFencesLateConnectionAndOldInput() throws {
        let (central, radio, observer) = setup(); defer { central.shutdown() }
        central.receive(advertisement())
        let p = try XCTUnwrap(observer.found.first)
        central.connect(p, options: nil); let old = p.token
        radio.acceptsCancellation = false
        central.cancelPeripheralConnection(p)
        XCTAssertEqual(p.token, 0); XCTAssertEqual(radio.cancellations, [old])
        central.receive(event(UInt32(S2W_CONNECTED), token: old))
        XCTAssertEqual(observer.connected, 0)
        central.connect(p, options: nil)
        XCTAssertGreaterThan(p.token, old)
        central.receive(event(UInt32(S2W_VALUE), token: old))
        XCTAssertEqual(observer.values, 0)
    }
    func testWritesUseBackpressureAndRejectOversizedFrames() throws {
        let (central, radio, observer) = setup(); defer { central.shutdown() }
        let p = try connect(central, observer)
        let ch = WindowsCharacteristic(index: 0, uuid: UUID(), flags: UInt32(S2W_WRITE))
        p.characteristics[0] = ch
        p.writeValue(Data([1]), for: ch, type: .withoutResponse)
        p.writeValue(Data([2]), for: ch, type: .withoutResponse)
        XCTAssertEqual(radio.writes, [Data([1])])
        central.receive(event(UInt32(S2W_WRITABLE), token: p.token))
        p.writeValue(Data([3]), for: ch, type: .withoutResponse)
        XCTAssertEqual(radio.writes, [Data([1]), Data([3])])
        central.receive(event(UInt32(S2W_WRITABLE), token: p.token))
        p.writeValue(Data(repeating: 0, count: 65), for: ch, type: .withoutResponse)
        XCTAssertEqual(radio.writes.count, 2); XCTAssertFalse(p.connected)
        XCTAssertEqual(p.token, 0)
    }
    func testOverflowInvalidatesConnectionsAndRejectsLateValues() throws {
        let (central, _, observer) = setup(); defer { central.shutdown() }
        let p = try connect(central, observer); let token = p.token
        central.receive(event(UInt32(S2W_OVERFLOW)))
        XCTAssertFalse(central.isScanning); XCTAssertFalse(p.connected)
        XCTAssertEqual(p.token, 0)
        central.receive(event(UInt32(S2W_VALUE), token: token))
        XCTAssertEqual(observer.values, 0)
    }
    func testUnauthorizedStateDoesNotStartScanning() {
        let (central, radio, _) = setup(); defer { central.shutdown() }
        var denied = event(UInt32(S2W_STATE)); denied.status = 3
        central.receive(denied)
        central.scanForPeripherals(withServices: nil, options: nil)
        XCTAssertEqual(radio.scans, [true]); XCTAssertFalse(central.isScanning)
    }
    func testPollingWorkAndShutdownAreBounded() {
        let (central, radio, observer) = setup()
        radio.events = Array(repeating: event(UInt32(S2W_STATE)), count: 300)
        let before = observer.stateChanges
        central.drain()
        XCTAssertEqual(observer.stateChanges - before, 256)
        XCTAssertEqual(radio.events.count, 44)
        central.shutdown(); central.shutdown()
        XCTAssertTrue(radio.closed); XCTAssertNil(central.driver)
    }
    func testPhysicalIdentityAndHostAddressByteOrder() {
        let (central, _, _) = setup(); defer { central.shutdown() }
        let p = WindowsPeripheral(address: 42, type: 0, host: 0x010203040506, central: central)
        let same = WindowsPeripheral(address: 42, type: 0, host: 0x010203040506, central: central)
        let other = WindowsPeripheral(address: 42, type: 1, host: 0x010203040506, central: central)
        XCTAssertEqual(p.identifier, same.identifier); XCTAssertNotEqual(p.identifier, other.identifier)
        XCTAssertEqual(p.hostAddressBytesLE, Data([6, 5, 4, 3, 2, 1]))
    }
}
#endif
