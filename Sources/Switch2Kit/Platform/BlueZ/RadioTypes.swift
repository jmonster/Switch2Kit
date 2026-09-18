#if os(Linux)
import Foundation

// Narrow private adaptation boundary for the existing session/transport engine.
// The aliases intentionally match only its consumed CoreBluetooth surface; no
// Apple framework, alternate controller decoder or public compatibility API is
// provided on Linux. All mutable objects belong to the same Bluetooth queue.
package typealias CBCentralManager = BlueZCentral
package typealias CBPeripheral = BlueZPeripheral
package typealias CBService = BlueZService
package typealias CBCharacteristic = BlueZCharacteristic
package typealias CBUUID = BlueZUUID
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
package struct BlueZUUID: Sendable {
    package let uuidString: String
    package init(_ value: UUID) { uuidString = value.uuidString }
}
package final class BlueZService {
    package let path: String
    package var characteristics: [CBCharacteristic]?
    package init(path: String, characteristics: [CBCharacteristic]) { self.path = path; self.characteristics = characteristics }
}
package final class BlueZCharacteristic {
    package let path: String
    package let uuid: CBUUID
    package let flags: Set<String>
    package let writeLimit: Int
    package var value: Data?
    package var isNotifying = false
    package init(path: String, uuid: UUID, flags: Set<String>, mtu: Int) {
        self.path = path; self.uuid = CBUUID(uuid); self.flags = flags
        // ATT writes have a three-byte header. Never guess a large MTU or split
        // Nintendo protocol frames. Missing MTU falls back to the ATT minimum.
        self.writeLimit = max(0, min(512, mtu - 3))
    }
}
package final class BlueZPeripheral: @unchecked Sendable {
    package let identifier: UUID
    package let path: String
    package let adapter: String
    package let hostAddressBytesLE: Data
    package weak var central: BlueZCentral?
    package weak var delegate: CBPeripheralDelegate?
    package var services: [CBService]?
    package var characteristics: [String: CBCharacteristic] = [:]
    package var generation: UInt64 = 0
    package var connecting = false
    package var connected = false
    package var disconnecting = false
    package var discoveringServices = false
    package var writePending = false
    package var canSendWriteWithoutResponse: Bool { connected && !disconnecting && !writePending }
    package init(path: String, adapter: String, hostAddress: String, address: String, addressType: String, central: BlueZCentral) {
        self.path = path; self.adapter = adapter; self.central = central
        self.hostAddressBytesLE = BlueZIdentity.addressBytes(hostAddress)!
        self.identifier = BlueZIdentity.uuid(name: "Switch2Kit/BlueZ/\(hostAddress.uppercased())/\(addressType)/\(address.uppercased())")
    }
    package func invalidate() {
        generation &+= 1
        connecting = false; connected = false; disconnecting = false
        discoveringServices = false; writePending = false
        services = nil; characteristics.removeAll()
    }
    package func discoverServices(_ uuids: [CBUUID]?) {
        guard connected, !disconnecting else { return }
        discoveringServices = true
        central?.loadServices(self)
    }
    package func discoverCharacteristics(_ uuids: [CBUUID]?, for service: CBService) {
        guard connected, !disconnecting, services?.contains(where: { $0 === service }) == true else { return }
        delegate?.peripheral(self, didDiscoverCharacteristicsFor: service, error: nil)
    }
    package func maximumWriteValueLength(for type: CBCharacteristicWriteType) -> Int {
        let relevant = Set([Switch2.GATT.commandWrite, Switch2.GATT.vibrationPro, Switch2.GATT.vibrationGameCube,
                            Switch2.GATT.vibrationJoyConL, Switch2.GATT.vibrationJoyConR].map(\.uuidString))
        return characteristics.values.filter { relevant.contains($0.uuid.uuidString) && $0.flags.contains("write-without-response") }
            .map(\.writeLimit).min() ?? 20
    }
    package func setNotifyValue(_ enabled: Bool, for characteristic: CBCharacteristic) {
        guard connected, !disconnecting, characteristics[characteristic.path] === characteristic, let central else { return }
        guard characteristic.flags.contains("notify") || characteristic.flags.contains("indicate") else {
            delegate?.peripheral(self, didUpdateNotificationStateFor: characteristic, error: BlueZError(name: "org.bluez.Error.NotSupported")); return
        }
        let generation = self.generation
        central.call(path: characteristic.path, interface: "org.bluez.GattCharacteristic1", member: enabled ? "StartNotify" : "StopNotify") { [weak self] result in
            guard let self, self.generation == generation, self.connected, !self.disconnecting else { return }
            switch result {
            case .success:
                characteristic.isNotifying = enabled
                self.delegate?.peripheral(self, didUpdateNotificationStateFor: characteristic, error: nil)
            case .failure(let error): self.delegate?.peripheral(self, didUpdateNotificationStateFor: characteristic, error: error)
            }
        }
    }
    package func writeValue(_ data: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType) {
        guard canSendWriteWithoutResponse, characteristics[characteristic.path] === characteristic, let central else { return }
        guard characteristic.flags.contains("write-without-response"), data.count <= characteristic.writeLimit else {
            central.linkFailed(self, error: BlueZError(name: "org.bluez.Error.InvalidValueLength")); return
        }
        let generation = self.generation
        writePending = true
        // One in-flight D-Bus write per device. Engine-side motor coalescing and
        // expiry remain authoritative; this adapter never queues stale packets.
        central.call(path: characteristic.path, interface: "org.bluez.GattCharacteristic1", member: "WriteValue",
                     arguments: [.bytes(data), .options([("type", .string("command"))])]) { [weak self] result in
            guard let self, self.generation == generation, self.connected, !self.disconnecting else { return }
            self.writePending = false
            switch result {
            case .success: self.delegate?.peripheralIsReady(toSendWriteWithoutResponse: self)
            case .failure(let error): central.linkFailed(self, error: error)
            }
        }
    }
    package func readRSSI() {
        guard connected, !disconnecting, let central else { return }
        let generation = self.generation
        central.call(path: path, interface: "org.freedesktop.DBus.Properties", member: "Get", arguments: [.string("org.bluez.Device1"), .string("RSSI")]) { [weak self] result in
            guard let self, self.generation == generation, self.connected, !self.disconnecting,
                  case .success(let values) = result, let number = values.first?.number else { return }
            self.delegate?.peripheral(self, didReadRSSI: NSNumber(value: number), error: nil)
        }
    }
}
#endif
