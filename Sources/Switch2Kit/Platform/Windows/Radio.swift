#if os(Windows)
import Foundation
import Switch2KitWinRT

// Private adaptation surface consumed by ControllerTransport/ControllerSession.
// The public controller API and Nintendo protocol engine are shared unchanged.
package typealias CBCentralManager = WindowsCentral
package typealias CBPeripheral = WindowsPeripheral
package typealias CBService = WindowsService
package typealias CBCharacteristic = WindowsCharacteristic
package struct CBUUID: Sendable {
    package let uuidString: String
    package init(_ value: UUID) { uuidString = value.uuidString }
}
package enum CBManagerState { case unknown, resetting, unsupported, unauthorized, poweredOff, poweredOn }
package enum CBCharacteristicWriteType { case withoutResponse }
package let CBAdvertisementDataManufacturerDataKey = "manufacturerData"
package let CBCentralManagerScanOptionAllowDuplicatesKey = "allowDuplicates"
package protocol CBCentralManagerDelegate: AnyObject {
    func centralManagerDidUpdateState(_ central: CBCentralManager)
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber)
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral)
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?)
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?)
}
package protocol CBPeripheralDelegate: AnyObject {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?)
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?)
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?)
    func peripheral(_ peripheral: CBPeripheral, didReadRSSI rssi: NSNumber, error: Error?)
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral)
    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService])
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?)
}
package struct WindowsRadioError: Error { package let code: Int32 }
package final class WindowsService {
    package var characteristics: [CBCharacteristic]?
    package init(_ characteristics: [CBCharacteristic]) { self.characteristics = characteristics }
}
package final class WindowsCharacteristic {
    package let index: UInt32
    package let uuid: CBUUID
    package let flags: UInt32
    package var value: Data?
    package var isNotifying = false
    package init(index: UInt32, uuid: UUID, flags: UInt32) {
        self.index = index; self.uuid = CBUUID(uuid); self.flags = flags
    }
}

// A fake can replace only the operating-system boundary in Windows unit tests.
// Production always constructs NativeWindowsRadio and the actual WinRT driver.
package protocol WindowsRadio: AnyObject {
    func next() -> S2WEvent?
    func scan(_ enabled: Bool) -> Bool
    func connect(token: UInt64, address: UInt64, type: UInt32) -> Bool
    func cancel(_ token: UInt64) -> Bool
    func discover(_ token: UInt64) -> Bool
    func notify(_ token: UInt64, index: UInt32, enabled: Bool) -> Bool
    func write(_ token: UInt64, index: UInt32, data: Data) -> Bool
    func close()
}
private final class NativeWindowsRadio: WindowsRadio {
    private var handle: OpaquePointer? = s2w_create()
    private var creationFailureReported = false
    deinit { close() }
    func close() { if let handle { s2w_destroy(handle); self.handle = nil }; creationFailureReported = true }
    func next() -> S2WEvent? {
        var value = S2WEvent()
        if handle == nil, !creationFailureReported {
            creationFailureReported = true; value.kind = UInt32(S2W_STATE); value.status = 2
            return value
        }
        return s2w_next(handle, &value) == 1 ? value : nil
    }
    func scan(_ enabled: Bool) -> Bool { s2w_scan(handle, enabled ? 1 : 0) == 1 }
    func connect(token: UInt64, address: UInt64, type: UInt32) -> Bool { s2w_connect(handle, token, address, type) == 1 }
    func cancel(_ token: UInt64) -> Bool { s2w_cancel(handle, token) == 1 }
    func discover(_ token: UInt64) -> Bool { s2w_discover(handle, token) == 1 }
    func notify(_ token: UInt64, index: UInt32, enabled: Bool) -> Bool { s2w_notify(handle, token, index, enabled ? 1 : 0) == 1 }
    func write(_ token: UInt64, index: UInt32, data: Data) -> Bool {
        data.withUnsafeBytes { s2w_write(handle, token, index, $0.bindMemory(to: UInt8.self).baseAddress, UInt32($0.count)) == 1 }
    }
}
package final class WindowsPeripheral: @unchecked Sendable {
    package let identifier: UUID
    package let address: UInt64
    package let addressType: UInt32
    package let hostAddressBytesLE: Data
    package weak var central: WindowsCentral?
    package weak var delegate: CBPeripheralDelegate?
    package var services: [CBService]?
    package var characteristics: [UInt32: CBCharacteristic] = [:]
    package var token: UInt64 = 0
    package var connected = false
    package var disconnecting = false
    package var writing = false
    package var mtu: UInt32 = 23
    package var canSendWriteWithoutResponse: Bool { connected && !disconnecting && !writing }
    package init(address: UInt64, type: UInt32, host: UInt64, central: WindowsCentral) {
        self.address = address; addressType = type; self.central = central
        hostAddressBytesLE = Data((0..<6).map { UInt8(truncatingIfNeeded: host >> ($0 * 8)) })
        identifier = BlueZIdentity.uuid(name: "Switch2Kit/WinRT/\(host)/\(type)/\(address)")
    }
    package func invalidate() {
        token = 0; connected = false; disconnecting = false; writing = false
        services = nil; characteristics.removeAll(); mtu = 23
    }
    package func discoverServices(_ uuids: [CBUUID]?) {
        guard connected, !disconnecting else { return }
        if central?.driver?.discover(token) != true { central?.failed(self, code: 1) }
    }
    package func discoverCharacteristics(_ uuids: [CBUUID]?, for service: CBService) {
        guard connected, !disconnecting, services?.contains(where: { $0 === service }) == true else { return }
        delegate?.peripheral(self, didDiscoverCharacteristicsFor: service, error: nil)
    }
    package func maximumWriteValueLength(for type: CBCharacteristicWriteType) -> Int { max(0, min(512, Int(mtu) - 3)) }
    package func setNotifyValue(_ enabled: Bool, for characteristic: CBCharacteristic) {
        guard connected, !disconnecting, characteristics[characteristic.index] === characteristic else { return }
        guard characteristic.flags & UInt32(S2W_NOTIFY | S2W_INDICATE) != 0,
              central?.driver?.notify(token, index: characteristic.index, enabled: enabled) == true else {
            delegate?.peripheral(self, didUpdateNotificationStateFor: characteristic, error: WindowsRadioError(code: 1)); return
        }
    }
    package func writeValue(_ data: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType) {
        guard canSendWriteWithoutResponse, characteristics[characteristic.index] === characteristic else { return }
        guard characteristic.flags & UInt32(S2W_WRITE) != 0, !data.isEmpty,
              data.count <= maximumWriteValueLength(for: type) else { central?.failed(self, code: 1); return }
        writing = true
        if central?.driver?.write(token, index: characteristic.index, data: data) != true { central?.failed(self, code: 1) }
    }
    // WinRT has no equivalent connected-peripheral RSSI read. Do not invent a
    // fresh value from an old advertisement or expose an unrelated device metric.
    package func readRSSI() {}
}
package final class WindowsCentral: @unchecked Sendable {
    package weak var delegate: CBCentralManagerDelegate?
    package private(set) var state: CBManagerState = .unknown
    package private(set) var isScanning = false
    package var driver: (any WindowsRadio)?
    private let factory: () -> any WindowsRadio
    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?
    private var nextToken: UInt64 = 0
    private var peripherals: [UUID: WindowsPeripheral] = [:]
    private var connections: [UInt64: WindowsPeripheral] = [:]
    private var seen = Set<UUID>()
    package init(delegate: CBCentralManagerDelegate, queue: DispatchQueue) {
        self.delegate = delegate; self.queue = queue; factory = { NativeWindowsRadio() }
    }
    package init(delegate: CBCentralManagerDelegate, queue: DispatchQueue, factory: @escaping () -> any WindowsRadio) {
        self.delegate = delegate; self.queue = queue; self.factory = factory
    }
    deinit { timer?.cancel(); driver?.close() }
    package func restart() {
        guard driver == nil || state == .resetting || state == .unsupported || state == .unauthorized else { return }
        shutdown()
        driver = factory()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(4), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.drain() }
        self.timer = timer; timer.resume()
    }
    package func shutdown() {
        timer?.cancel(); timer = nil
        isScanning = false; seen.removeAll()
        for peripheral in connections.values { peripheral.invalidate() }
        connections.removeAll(); peripherals.removeAll()
        driver?.close(); driver = nil; state = .unknown
    }
    package func scanForPeripherals(withServices services: [CBUUID]?, options: [String: Any]?) {
        guard state == .poweredOn, !isScanning else { return }
        seen.removeAll()
        isScanning = driver?.scan(true) == true
        if !isScanning { updateState(.unsupported) }
    }
    package func stopScan() { isScanning = false; seen.removeAll(); _ = driver?.scan(false) }
    package func connect(_ peripheral: CBPeripheral, options: [String: Any]?) {
        guard state == .poweredOn, peripheral.token == 0, nextToken < UInt64.max else { return }
        nextToken += 1; peripheral.token = nextToken; connections[nextToken] = peripheral
        if driver?.connect(token: nextToken, address: peripheral.address, type: peripheral.addressType) != true { failed(peripheral, code: 1) }
    }
    package func cancelPeripheralConnection(_ peripheral: CBPeripheral) {
        guard peripheral.token != 0 else { return }
        peripheral.disconnecting = true; peripheral.writing = false
        if driver?.cancel(peripheral.token) != true { finish(peripheral, failure: nil) }
    }
    package func failed(_ peripheral: WindowsPeripheral, code: Int32) {
        _ = driver?.cancel(peripheral.token)
        finish(peripheral, failure: WindowsRadioError(code: code))
    }
    private func finish(_ peripheral: WindowsPeripheral, failure: WindowsRadioError?) {
        let connected = peripheral.connected, cancelled = peripheral.disconnecting
        connections.removeValue(forKey: peripheral.token); peripheral.invalidate()
        if let failure, !connected, !cancelled { delegate?.centralManager(self, didFailToConnect: peripheral, error: failure) }
        else { delegate?.centralManager(self, didDisconnectPeripheral: peripheral, error: failure) }
    }
    private func updateState(_ value: CBManagerState) {
        state = value
        if value != .poweredOn {
            isScanning = false; seen.removeAll()
            for peripheral in connections.values { peripheral.invalidate() }
            connections.removeAll()
        }
        delegate?.centralManagerDidUpdateState(self)
    }
    package func drain() {
        // Bound work on the controller queue even when the OS delivers a burst.
        for _ in 0..<256 {
            guard let event = driver?.next() else { break }
            receive(event)
        }
    }
    package func receive(_ event: S2WEvent) {
        if event.kind == UInt32(S2W_STATE) {
            let values: [CBManagerState] = [.unknown, .resetting, .unsupported, .unauthorized, .poweredOff, .poweredOn]
            updateState(values.indices.contains(Int(event.status)) ? values[Int(event.status)] : .unknown); return
        }
        if event.kind == UInt32(S2W_OVERFLOW) { updateState(.resetting); return }
        if event.kind == UInt32(S2W_ADVERTISEMENT) {
            guard isScanning, state == .poweredOn, event.length <= 512, event.host_address != 0,
                  event.address != 0, event.address_type <= 1 else { return }
            let data = withUnsafeBytes(of: event.bytes) { Data($0.prefix(Int(event.length))) }
            guard Switch2.recognizeAdvertisement(data) != nil else { return }
            let candidate = WindowsPeripheral(address: event.address, type: event.address_type, host: event.host_address, central: self)
            guard seen.count < 128, !seen.contains(candidate.identifier) else { return }
            if peripherals[candidate.identifier] == nil, peripherals.count >= 128 {
                guard let idle = peripherals.first(where: { $0.value.token == 0 })?.key else { return }
                peripherals.removeValue(forKey: idle)
            }
            let peripheral = peripherals[candidate.identifier] ?? candidate
            peripherals[candidate.identifier] = peripheral
            seen.insert(candidate.identifier)
            delegate?.centralManager(self, didDiscover: peripheral, advertisementData: [CBAdvertisementDataManufacturerDataKey: data], rssi: NSNumber(value: event.rssi)); return
        }
        // Tokens fence late callbacks from canceled attempts and replaced links.
        guard let peripheral = connections[event.token], peripheral.token == event.token else { return }
        if event.kind == UInt32(S2W_DISCONNECTED) { finish(peripheral, failure: nil); return }
        if event.kind == UInt32(S2W_FAILED) { finish(peripheral, failure: WindowsRadioError(code: event.status)); return }
        guard !peripheral.disconnecting else { return }
        switch event.kind {
        case UInt32(S2W_CONNECTED):
            peripheral.connected = true; peripheral.mtu = event.flags
            delegate?.centralManager(self, didConnect: peripheral)
        case UInt32(S2W_MTU): peripheral.mtu = event.flags
        case UInt32(S2W_CHARACTERISTIC):
            let text = withUnsafeBytes(of: event.uuid) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
            guard let uuid = UUID(uuidString: text), peripheral.characteristics.count < 128 else { failed(peripheral, code: 1); return }
            peripheral.characteristics[event.characteristic] = WindowsCharacteristic(index: event.characteristic, uuid: uuid, flags: event.flags)
        case UInt32(S2W_SERVICES):
            peripheral.services = [WindowsService(peripheral.characteristics.sorted { $0.key < $1.key }.map(\.value))]
            peripheral.delegate?.peripheral(peripheral, didDiscoverServices: nil)
        case UInt32(S2W_NOTIFICATION):
            guard let characteristic = peripheral.characteristics[event.characteristic] else { return }
            characteristic.isNotifying = event.flags != 0 && event.status == 0
            peripheral.delegate?.peripheral(peripheral, didUpdateNotificationStateFor: characteristic, error: event.status == 0 ? nil : WindowsRadioError(code: event.status))
        case UInt32(S2W_VALUE):
            guard event.length <= 512, let characteristic = peripheral.characteristics[event.characteristic] else { failed(peripheral, code: 1); return }
            characteristic.value = withUnsafeBytes(of: event.bytes) { Data($0.prefix(Int(event.length))) }
            peripheral.delegate?.peripheral(peripheral, didUpdateValueFor: characteristic, error: nil)
        case UInt32(S2W_WRITABLE):
            peripheral.writing = false; peripheral.delegate?.peripheralIsReady(toSendWriteWithoutResponse: peripheral)
        default: break
        }
    }
}
#endif
