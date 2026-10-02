import Foundation
@testable import Switch2Kit

// Only the sd-bus boundary is replaced. lifecycle.py compiles unchanged
// production Central/RadioTypes method bodies with test-visible access control.
final class BlueZBus {
    typealias Completion = (Result<[BlueZValue], BlueZError>) -> Void
    struct Call { let path: String; let member: String; let completion: Completion }
    var failed: ((BlueZError) -> Void)?
    var signal: ((String, String, String, [BlueZValue]) -> Void)?
    var calls: [Call] = []
    var closed = false
    init(queue: DispatchQueue) throws {}
    func subscribe(_ rule: String) throws {}
    func close() { closed = true; calls.removeAll(); failed = nil; signal = nil }
    func call(path: String, interface: String, member: String, arguments: [BlueZArgument] = [], completion: @escaping Completion) {
        calls.append(Call(path: path, member: member, completion: completion))
    }
    func take(_ member: String) -> Completion {
        guard let index = calls.firstIndex(where: { $0.member == member }) else { preconditionFailure("Missing \(member)") }
        return calls.remove(at: index).completion
    }
}
final class Observer: CBCentralManagerDelegate {
    var connections = 0, disconnections = 0
    var onState: ((BlueZCentral) -> Void)?
    func centralManagerDidUpdateState(_ central: CBCentralManager) { onState?(central) }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {}
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) { connections += 1 }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {}
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) { disconnections += 1 }
}
final class Fixture {
    let observer = Observer()
    let central: BlueZCentral
    let bus: BlueZBus
    let peripheral: BlueZPeripheral
    init(connected: Bool = true) {
        central = BlueZCentral(delegate: observer, queue: DispatchQueue(label: "test.bluez-lifecycle"))
        central.restart(); bus = central.bus!
        let adapter = "/org/bluez/hci0", path = "/org/bluez/hci0/device"
        bus.take("GetManagedObjects")(.success([.dictionary([
            adapter: .dictionary(["org.bluez.Adapter1": .dictionary([
                "Address": .string("12:34:56:78:9A:BC"), "Powered": .number(1)
            ])]),
            path: .dictionary(["org.bluez.Device1": .dictionary([
                "Connected": .number(0), "ServicesResolved": .number(1)
            ])])
        ])]))
        peripheral = BlueZPeripheral(path: path, adapter: adapter, hostAddress: "12:34:56:78:9A:BC",
            address: "11:22:33:44:55:66", addressType: "public", central: central)
        central.peripherals[path] = peripheral
        peripheral.connected = connected
    }
    func failRefresh(_ result: Result<[BlueZValue], BlueZError>) {
        central.refreshObjects()
        bus.take("GetManagedObjects")(result)
    }
    func finish() { central.shutdown() }
}
@main struct LifecycleTests {
    static func main() {
        for result: Result<[BlueZValue], BlueZError> in [
            .failure(.unavailable), .failure(BlueZError(name: "org.freedesktop.DBus.Error.AccessDenied")), .success([])
        ] {
            let f = Fixture()
            // Use the actual service-discovery refresh that failed after Connect.
            f.peripheral.discoverServices(nil)
            f.bus.take("GetManagedObjects")(result)
            let denied: Bool
            if case .failure(let error) = result { denied = error.isPermission } else { denied = false }
            precondition(f.central.state == (denied ? .unauthorized : .unsupported))
            precondition(!f.peripheral.connected && f.peripheral.disconnecting)
            precondition(f.bus.calls.map(\.member) == ["Disconnect"])
            f.bus.take("Disconnect")(.success([]))
            precondition(f.observer.disconnections == 1 && !f.peripheral.disconnecting)
            f.finish(); precondition(f.bus.closed)
        }
        print("PASS failed/denied/malformed service snapshots release owned links")

        do {
            let f = Fixture(connected: false)
            f.central.connect(f.peripheral, options: nil)
            let lateConnect = f.bus.take("Connect")
            f.failRefresh(.failure(.unavailable))
            precondition(!f.peripheral.connecting && f.peripheral.disconnecting)
            let cancelledGeneration = f.peripheral.generation
            lateConnect(.success([]))
            precondition(!f.peripheral.connected && f.observer.connections == 0)
            precondition(f.peripheral.generation == cancelledGeneration)
            f.bus.take("Disconnect")(.success([])); f.finish()
        }
        print("PASS snapshot failure fences a delayed Connect completion")

        do {
            let f = Fixture()
            f.central.cancelPeripheralConnection(f.peripheral)
            let generation = f.peripheral.generation
            f.failRefresh(.failure(.unavailable))
            precondition(f.bus.calls.map(\.member) == ["Disconnect"])
            precondition(f.peripheral.generation == generation)
            // A failed/timed-out Disconnect uses the existing backend failure
            // path, closes the bus and clears ownership instead of hanging.
            f.bus.take("Disconnect")(.failure(.unavailable))
            precondition(f.bus.closed && f.central.bus == nil)
            precondition(!f.peripheral.connected && !f.peripheral.disconnecting)
            f.finish()
        }
        print("PASS pending cancellation is preserved and a failed release closes the backend")

        do {
            let f = Fixture()
            f.central.refreshObjects()
            let lateSnapshot = f.bus.take("GetManagedObjects")
            f.central.shutdown()
            let generation = f.peripheral.generation
            lateSnapshot(.failure(.unavailable))
            precondition(f.central.closing && f.central.delegate == nil)
            precondition(f.peripheral.generation == generation)
            precondition(f.bus.calls.map(\.member) == ["Disconnect"])
            f.bus.take("Disconnect")(.success([]))
            precondition(f.bus.closed && f.central.shutdownLifetime == nil)
        }
        print("PASS a late failed refresh cannot restart or duplicate shutdown")

        do {
            let f = Fixture()
            f.observer.onState = { central in
                if central.state == .unsupported { central.shutdown() }
            }
            f.failRefresh(.failure(.unavailable))
            precondition(f.central.closing && f.central.delegate == nil)
            precondition(f.bus.calls.map(\.member) == ["Disconnect"])
            f.bus.take("Disconnect")(.success([]))
            precondition(f.bus.closed && f.central.shutdownLifetime == nil)
        }
        do {
            let f = Fixture(connected: false)
            f.failRefresh(.failure(.unavailable))
            precondition(f.bus.calls.isEmpty && !f.peripheral.disconnecting)
            f.finish()
        }
        print("PASS reentrant shutdown preserves one release and idle devices are untouched")
    }
}
