#if os(Linux)
import Foundation

package final class BlueZCentral: @unchecked Sendable {
    package weak var delegate: CBCentralManagerDelegate?
    package private(set) var state: CBManagerState = .unknown
    package var isScanning: Bool { scanRequested && state == .poweredOn }
    private let queue: DispatchQueue
    private var bus: BlueZBus?
    private var epoch: UInt64 = 0
    private var objects: [String: [String: BlueZValue]] = [:]
    private var peripherals: [String: BlueZPeripheral] = [:]
    private var adapter: String?
    private var scanGeneration: UInt64 = 0
    private var scanRequested = false
    private var scanActive = false
    private var scanBusy = false
    private var filterReady = false
    private var seen = Set<String>()
    private var refreshing = false
    private var refreshCompletions: [() -> Void] = []
    private var closing = false
    private var shutdownLifetime: BlueZCentral?

    package init(delegate: CBCentralManagerDelegate, queue: DispatchQueue) {
        self.delegate = delegate; self.queue = queue
        // The transport assigns this reference before calling restart().
        // Failed startup is retried only by an explicit stop/start.
    }
    deinit { bus?.close() }
    package func restart() {
        guard bus == nil, !closing else { return }
        do {
            let connection = try BlueZBus(queue: queue)
            bus = connection
            connection.failed = { [weak self] error in self?.backendFailed(error) }
            connection.signal = { [weak self] path, interface, member, values in
                self?.receive(path: path, interface: interface, member: member, values: values)
            }
            try connection.subscribe("type='signal',sender='org.bluez'")
            try connection.subscribe("type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop.DBus',member='NameOwnerChanged',arg0='org.bluez'")
            refreshObjects()
        } catch { backendFailed((error as? BlueZError) ?? .unavailable) }
    }
    package func shutdown() {
        guard !closing else { return }
        closing = true; delegate = nil
        stopScan()
        for peripheral in Array(peripherals.values) where peripheral.connected || peripheral.connecting {
            cancelPeripheralConnection(peripheral)
        }
        // Keep the bus alive for outstanding Disconnect replies. The transport
        // has already retired its sessions, so no input can escape during this
        // bounded release period. A daemon failure cannot retain the SDK forever.
        shutdownLifetime = self
        finishShutdownIfIdle()
        queue.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, self.closing else { return }
            self.bus?.close(); self.bus = nil; self.shutdownLifetime = nil
        }
    }
    private func finishShutdownIfIdle() {
        guard closing, !peripherals.values.contains(where: { $0.connected || $0.connecting || $0.disconnecting }) else { return }
        bus?.close(); bus = nil; shutdownLifetime = nil
    }
    private func setState(_ value: CBManagerState) {
        guard state != value else { return }
        state = value
        delegate?.centralManagerDidUpdateState(self)
    }
    private func resetRadio() {
        epoch &+= 1
        scanGeneration &+= 1
        scanRequested = false; scanActive = false; scanBusy = false; filterReady = false
        seen.removeAll(); objects.removeAll(); adapter = nil
        refreshing = false; refreshCompletions.removeAll()
        for peripheral in peripherals.values { peripheral.invalidate() }
        peripherals.removeAll()
    }
    private func backendFailed(_ error: BlueZError) {
        bus?.close(); bus = nil
        resetRadio()
        setState(error.isPermission ? .unauthorized : .unsupported)
        finishShutdownIfIdle()
    }
    package func call(path: String, interface: String, member: String, arguments: [BlueZArgument] = [],
                      completion: @escaping (Result<[BlueZValue], BlueZError>) -> Void) {
        guard let bus else { completion(.failure(.unavailable)); return }
        bus.call(path: path, interface: interface, member: member, arguments: arguments, completion: completion)
    }
    private func refreshObjects(_ completion: (() -> Void)? = nil) {
        if let completion {
            guard refreshCompletions.count < 64 else { backendFailed(.malformed); return }
            refreshCompletions.append(completion)
        }
        guard !refreshing else { return }
        refreshing = true
        let epoch = self.epoch
        call(path: "/", interface: "org.freedesktop.DBus.ObjectManager", member: "GetManagedObjects") { [weak self] result in
            guard let self, self.epoch == epoch else { return }
            self.refreshing = false
            guard case .success(let values) = result, let objects = values.first?.dictionary, objects.count <= 8192 else {
                self.refreshCompletions.removeAll()
                if case .failure(let error) = result, error.isPermission { self.setState(.unauthorized) }
                else { self.setState(.unsupported) }
                return
            }
            var next: [String: [String: BlueZValue]] = [:]
            for (path, value) in objects {
                guard path.hasPrefix("/org/bluez"), path.count <= 4096, let interfaces = value.dictionary else { continue }
                next[path] = interfaces
            }
            self.objects = next
            self.updateAdapter()
            let completions = self.refreshCompletions
            self.refreshCompletions.removeAll()
            for completion in completions { completion() }
        }
    }
    private func properties(_ path: String, _ interface: String) -> [String: BlueZValue] {
        objects[path]?[interface]?.dictionary ?? [:]
    }
    private func updateAdapter() {
        let available = objects.keys.filter { objects[$0]?["org.bluez.Adapter1"] != nil }.sorted()
        let selected: String?
        if let adapter, available.contains(adapter), properties(adapter, "org.bluez.Adapter1")["Powered"]?.number == 1 { selected = adapter }
        else { selected = available.first(where: { properties($0, "org.bluez.Adapter1")["Powered"]?.number == 1 }) ?? available.first }
        if adapter != selected {
            // A delayed StartDiscovery reply may outlive adapter selection.
            // Release this bus client's old discovery session even when the
            // normal scan reconciler is busy. StopDiscovery never releases a
            // different client's session; an already-removed adapter can fail.
            if let previous = adapter, scanActive || scanBusy {
                call(path: previous, interface: "org.bluez.Adapter1", member: "StopDiscovery") { _ in }
                scanActive = false
            }
            scanGeneration &+= 1
            if adapter != nil {
                // Existing links belong to the old adapter. Do not silently move
                // their identities or leave owned radio connections behind.
                for peripheral in Array(peripherals.values) where peripheral.connected || peripheral.connecting {
                    cancelPeripheralConnection(peripheral)
                }
                setState(.resetting)
            }
            adapter = selected; filterReady = false; scanActive = false; scanBusy = false
        }
        guard let adapter else { setState(.unsupported); return }
        let props = properties(adapter, "org.bluez.Adapter1")
        guard let address = props["Address"]?.string, BlueZIdentity.addressBytes(address) != nil else { setState(.unsupported); return }
        if props["Powered"]?.number == 1 { setState(.poweredOn) }
        else {
            if state != .poweredOff { scanGeneration &+= 1 }
            for peripheral in peripherals.values { peripheral.invalidate() }
            scanActive = false; scanBusy = false; filterReady = false
            setState(.poweredOff)
        }
    }
    package func scanForPeripherals(withServices services: [CBUUID]?, options: [String: Any]?) {
        guard !closing, state == .poweredOn else { return }
        if !scanRequested { seen.removeAll() }
        scanRequested = true
        reconcileScan()
    }
    package func stopScan() {
        scanRequested = false; seen.removeAll()
        reconcileScan()
    }
    private func reconcileScan() {
        guard !scanBusy, let adapter, bus != nil else { return }
        let desired = scanRequested && state == .poweredOn && !closing
        if desired && !filterReady {
            scanBusy = true
            let scanGeneration = self.scanGeneration
            // DuplicateData asks BlueZ to report fresh manufacturer payloads.
            // The engine's duplicate policy is enforced locally. Cached startup
            // manufacturer data is never treated as a fresh advertisement.
            call(path: adapter, interface: "org.bluez.Adapter1", member: "SetDiscoveryFilter",
                 arguments: [.options([("Transport", .string("le")), ("DuplicateData", .boolean(true))])]) { [weak self] result in
                guard let self, self.scanGeneration == scanGeneration, self.adapter == adapter else { return }
                self.scanBusy = false
                guard case .success = result else { self.scanFailed(result); return }
                self.filterReady = true
                self.reconcileScan()
            }
            return
        }
        guard desired != scanActive else { return }
        scanBusy = true
        let scanGeneration = self.scanGeneration
        call(path: adapter, interface: "org.bluez.Adapter1", member: desired ? "StartDiscovery" : "StopDiscovery") { [weak self] result in
            guard let self, self.scanGeneration == scanGeneration, self.adapter == adapter else { return }
            self.scanBusy = false
            guard case .success = result else { self.scanFailed(result); return }
            self.scanActive = desired
            self.reconcileScan()
        }
    }
    private func scanFailed(_ result: Result<[BlueZValue], BlueZError>) {
        scanRequested = false; scanActive = false
        if case .failure(let error) = result { backendFailed(error) }
    }
    private func discovered(_ path: String) {
        guard isScanning, scanActive, !seen.contains(path), seen.count < 512, let adapter else { return }
        let props = properties(path, "org.bluez.Device1")
        guard props["Adapter"]?.string == adapter, props["Connected"]?.number != 1,
              let address = props["Address"]?.string, BlueZIdentity.addressBytes(address) != nil,
              let addressType = props["AddressType"]?.string, ["public", "random"].contains(addressType),
              let hostAddress = properties(adapter, "org.bluez.Adapter1")["Address"]?.string,
              BlueZIdentity.addressBytes(hostAddress) != nil,
              let payload = props["ManufacturerData"]?.dictionary?[String(Switch2.nintendoCompanyID)]?.bytes,
              payload.count <= 254 else { return }
        var manufacturer = Data([UInt8(truncatingIfNeeded: Switch2.nintendoCompanyID), UInt8(Switch2.nintendoCompanyID >> 8)])
        manufacturer.append(payload)
        guard Switch2.recognizeAdvertisement(manufacturer) != nil else { return }
        if peripherals[path] == nil {
            // Retain live/connecting links; idle advertisement objects can be
            // discarded safely because their identities are deterministic.
            if peripherals.count >= 128 {
                peripherals = peripherals.filter { $0.value.connected || $0.value.connecting || $0.value.disconnecting }
            }
            guard peripherals.count < 128 else { return }
            peripherals[path] = BlueZPeripheral(path: path, adapter: adapter, hostAddress: hostAddress,
                                               address: address, addressType: addressType, central: self)
        }
        guard let peripheral = peripherals[path], !peripheral.disconnecting else { return }
        seen.insert(path)
        delegate?.centralManager(self, didDiscover: peripheral,
                                 advertisementData: [CBAdvertisementDataManufacturerDataKey: manufacturer],
                                 rssi: NSNumber(value: props["RSSI"]?.number ?? 127))
    }
    package func connect(_ peripheral: CBPeripheral, options: [String: Any]?) {
        guard !closing, peripherals[peripheral.path] === peripheral, peripheral.adapter == adapter,
              !peripheral.connecting, !peripheral.connected, !peripheral.disconnecting,
              properties(peripheral.path, "org.bluez.Device1")["Connected"]?.number != 1 else {
            delegate?.centralManager(self, didFailToConnect: peripheral, error: BlueZError.unavailable); return
        }
        peripheral.generation &+= 1
        let generation = peripheral.generation
        peripheral.connecting = true
        call(path: peripheral.path, interface: "org.bluez.Device1", member: "Connect") { [weak self, weak peripheral] result in
            guard let self, let peripheral, peripheral.generation == generation, !peripheral.disconnecting else { return }
            peripheral.connecting = false
            switch result {
            case .success:
                peripheral.connected = true
                self.delegate?.centralManager(self, didConnect: peripheral)
            case .failure(let error): self.delegate?.centralManager(self, didFailToConnect: peripheral, error: error)
            }
        }
    }
    package func cancelPeripheralConnection(_ peripheral: CBPeripheral) {
        guard !peripheral.disconnecting else { return }
        peripheral.generation &+= 1
        let generation = peripheral.generation
        let owned = peripheral.connected || peripheral.connecting
        peripheral.disconnecting = true
        peripheral.connecting = false; peripheral.connected = false
        peripheral.writePending = false
        guard owned else { disconnected(peripheral, generation: generation); return }
        call(path: peripheral.path, interface: "org.bluez.Device1", member: "Disconnect") { [weak self, weak peripheral] result in
            guard let self, let peripheral, peripheral.generation == generation else { return }
            if case .failure(let error) = result, error.name != "org.bluez.Error.NotConnected" {
                self.backendFailed(error); return
            }
            self.disconnected(peripheral, generation: generation)
        }
    }
    private func disconnected(_ peripheral: BlueZPeripheral, generation: UInt64) {
        guard peripheral.generation == generation else { return }
        peripheral.invalidate()
        delegate?.centralManager(self, didDisconnectPeripheral: peripheral, error: nil)
        finishShutdownIfIdle()
    }
    package func linkFailed(_ peripheral: BlueZPeripheral, error: BlueZError) {
        guard peripheral.connected, !peripheral.disconnecting else { return }
        // Service invalidation takes the existing fatal session path, preserving
        // its neutralization, generation fencing and transport cancellation.
        if let services = peripheral.services, !services.isEmpty {
            peripheral.delegate?.peripheral(peripheral, didModifyServices: services)
        } else { cancelPeripheralConnection(peripheral) }
    }
    package func loadServices(_ peripheral: BlueZPeripheral) {
        guard peripheral.connected, !peripheral.disconnecting, peripheral.discoveringServices,
              properties(peripheral.path, "org.bluez.Device1")["ServicesResolved"]?.number == 1 else { return }
        let generation = peripheral.generation
        refreshObjects { [weak self, weak peripheral] in
            guard let self, let peripheral, peripheral.generation == generation,
                  peripheral.connected, !peripheral.disconnecting, peripheral.discoveringServices else { return }
            peripheral.discoveringServices = false
            var services: [CBService] = []
            var characteristics: [String: CBCharacteristic] = [:]
            for path in self.objects.keys.sorted() {
                let service = self.properties(path, "org.bluez.GattService1")
                guard service["Device"]?.string == peripheral.path else { continue }
                var members: [CBCharacteristic] = []
                for characteristicPath in self.objects.keys.sorted() {
                    let props = self.properties(characteristicPath, "org.bluez.GattCharacteristic1")
                    guard props["Service"]?.string == path, let text = props["UUID"]?.string,
                          let uuid = UUID(uuidString: text), let flags = props["Flags"]?.array else { continue }
                    guard characteristics.count < 256 else { self.linkFailed(peripheral, error: .malformed); return }
                    let value = CBCharacteristic(path: characteristicPath, uuid: uuid,
                        flags: Set(flags.compactMap(\.string)), mtu: Int(props["MTU"]?.number ?? 23))
                    members.append(value); characteristics[characteristicPath] = value
                }
                services.append(CBService(path: path, characteristics: members))
            }
            peripheral.characteristics = characteristics; peripheral.services = services
            peripheral.delegate?.peripheral(peripheral, didDiscoverServices: services.isEmpty ? BlueZError.malformed : nil)
        }
    }
    private func receive(path: String, interface: String, member: String, values: [BlueZValue]) {
        if interface == "org.freedesktop.DBus", member == "NameOwnerChanged", values.count == 3, values[0].string == "org.bluez" {
            resetRadio(); setState(.resetting)
            if values[2].string?.isEmpty == false { refreshObjects() }
            else { setState(.unsupported) }
            return
        }
        if interface == "org.freedesktop.DBus.ObjectManager", member == "InterfacesAdded", values.count == 2,
           let objectPath = values[0].string, let interfaces = values[1].dictionary {
            guard objects[objectPath] != nil || objects.count < 8192 else { backendFailed(.malformed); return }
            objects[objectPath, default: [:]].merge(interfaces) { _, new in new }
            if interfaces["org.bluez.Adapter1"] != nil { updateAdapter() }
            if interfaces["org.bluez.Device1"] != nil { discovered(objectPath) }
            return
        }
        if interface == "org.freedesktop.DBus.ObjectManager", member == "InterfacesRemoved", values.count == 2,
           let objectPath = values[0].string, let interfaces = values[1].array {
            for item in interfaces.compactMap(\.string) { objects[objectPath]?.removeValue(forKey: item) }
            if objects[objectPath]?.isEmpty == true { objects.removeValue(forKey: objectPath) }
            for peripheral in Array(peripherals.values) {
                if peripheral.path == objectPath, peripheral.connected || peripheral.connecting || peripheral.disconnecting {
                    disconnected(peripheral, generation: peripheral.generation)
                } else if peripheral.characteristics[objectPath] != nil || peripheral.services?.contains(where: { $0.path == objectPath }) == true {
                    linkFailed(peripheral, error: .malformed)
                }
            }
            updateAdapter()
            return
        }
        guard interface == "org.freedesktop.DBus.Properties", member == "PropertiesChanged", values.count == 3,
              let changedInterface = values[0].string, let changed = values[1].dictionary,
              let invalidated = values[2].array else { return }
        guard objects[path] != nil || objects.count < 8192 else { backendFailed(.malformed); return }
        var props = properties(path, changedInterface)
        props.merge(changed) { _, new in new }
        let absent = Set(invalidated.compactMap(\.string))
        for name in absent { props.removeValue(forKey: name) }
        objects[path, default: [:]][changedInterface] = .dictionary(props)
        if changedInterface == "org.bluez.Adapter1" { updateAdapter(); return }
        if changedInterface == "org.bluez.Device1" {
            if let peripheral = peripherals[path] {
                if changed["Connected"]?.number == 0 || absent.contains("Connected") {
                    if peripheral.connected || peripheral.connecting || peripheral.disconnecting {
                        disconnected(peripheral, generation: peripheral.generation)
                    }
                } else if changed["ServicesResolved"]?.number == 0 || absent.contains("ServicesResolved") {
                    linkFailed(peripheral, error: .malformed)
                } else if changed["ServicesResolved"]?.number == 1 { loadServices(peripheral) }
            }
            if changed["ManufacturerData"] != nil { discovered(path) }
            return
        }
        guard changedInterface == "org.bluez.GattCharacteristic1" else { return }
        for peripheral in Array(peripherals.values) where peripheral.connected && !peripheral.disconnecting {
            guard let characteristic = peripheral.characteristics[path] else { continue }
            if !absent.isDisjoint(with: ["UUID", "Service", "Flags", "MTU"]) || changed["UUID"] != nil || changed["Service"] != nil || changed["Flags"] != nil || changed["MTU"] != nil {
                linkFailed(peripheral, error: .malformed); continue
            }
            if characteristic.isNotifying, changed["Notifying"]?.number == 0 || absent.contains("Notifying") {
                characteristic.isNotifying = false
                peripheral.delegate?.peripheral(peripheral, didUpdateNotificationStateFor: characteristic, error: nil)
            }
            if characteristic.isNotifying, let data = changed["Value"]?.bytes, data.count <= 512 {
                characteristic.value = data
                peripheral.delegate?.peripheral(peripheral, didUpdateValueFor: characteristic, error: nil)
            }
        }
    }
}
#endif
