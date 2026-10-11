import Foundation
@main enum DiscoveryEngineTests {
    static func pendingOnDemandWindowSurvivesStartup() {
        for state in [CBCentralManager.State.unknown, .resetting] {
            let engine = ControllerTransport(configuration: .init(discoveryMode: .onDemand),
                hub: ControllerEventHub(), diagnostics: Switch2Diagnostics())
            engine.start()
            engine.btQueue.sync { engine.central.state = state }
            engine.requestDiscoveryWindow(seconds: 60)
            engine.btQueue.sync {
                precondition(engine.discovery.deadline == nil && !engine.central.isScanning)
                precondition(engine.pendingDiscoverySeconds == 60)
                engine.centralManagerDidUpdateState(engine.central)
                precondition(engine.pendingDiscoverySeconds == 60 && engine.discovery.deadline == nil,
                    "Bluetooth startup discarded the requested on-demand search window")
                let now = ControllerClock.now
                engine.central.state = .poweredOn
                engine.centralManagerDidUpdateState(engine.central)
                let deadline = engine.discovery.deadline!
                precondition(engine.central.isScanning && engine.pendingDiscoverySeconds == nil)
                precondition(deadline >= now + 60 && deadline < now + 61,
                    "The bounded search must get its full budget after Bluetooth startup")
                engine.central.state = .resetting
                engine.centralManagerDidUpdateState(engine.central)
                engine.central.state = .poweredOn
                engine.centralManagerDidUpdateState(engine.central)
                precondition(engine.discovery.deadline == deadline,
                    "A radio reset must preserve, not extend, an already-started deadline")
                _ = engine.discovery.shouldScan(readyIDs: [], now: deadline + 1)
                engine.updateScanning()
                precondition(!engine.central.isScanning, "Startup must not turn a bounded request into perpetual scanning")
            }
            engine.stop(); engine.btQueue.sync {}
        }
        for state in [CBCentralManager.State.unauthorized, .unsupported, .poweredOff] {
            let engine = ControllerTransport(configuration: .init(discoveryMode: .onDemand),
                hub: ControllerEventHub(), diagnostics: Switch2Diagnostics())
            engine.start(); engine.requestDiscoveryWindow(seconds: 60)
            engine.btQueue.sync {
                engine.central.state = state
                engine.centralManagerDidUpdateState(engine.central)
                precondition(engine.discovery.deadline == nil && !engine.central.isScanning)
                precondition(engine.pendingDiscoverySeconds == nil)
                engine.central.state = .poweredOn
                engine.centralManagerDidUpdateState(engine.central)
                precondition(!engine.central.isScanning,
                    "Denial, unsupported radio and radio-off must still require another explicit request")
            }
            engine.stop(); engine.btQueue.sync {}
        }
        for state in [CBCentralManager.State.unauthorized, .unsupported, .poweredOff] {
            let engine = ControllerTransport(configuration: .init(discoveryMode: .onDemand),
                hub: ControllerEventHub(), diagnostics: Switch2Diagnostics())
            engine.start()
            engine.btQueue.sync {
                engine.central.state = state
                engine.centralManagerDidUpdateState(engine.central)
            }
            engine.requestDiscoveryWindow(seconds: 60)
            engine.btQueue.sync {
                precondition(engine.pendingDiscoverySeconds == nil && engine.discovery.deadline == nil,
                    "A request made after denial or radio-off must not leave deferred intent")
                engine.central.state = .poweredOn
                engine.centralManagerDidUpdateState(engine.central)
                precondition(!engine.central.isScanning)
            }
            engine.stop(); engine.btQueue.sync {}
        }
        for connectedOnly in [false, true] {
            let engine = ControllerTransport(configuration: .init(discoveryMode: .onDemand),
                hub: ControllerEventHub(), diagnostics: Switch2Diagnostics())
            engine.start()
            engine.btQueue.sync { engine.central.state = .unknown }
            engine.requestDiscoveryWindow(seconds: 60)
            if connectedOnly { engine.useConnectedForDiscovery() } else { engine.stop() }
            engine.btQueue.sync {
                precondition(engine.pendingDiscoverySeconds == nil && engine.discovery.deadline == nil)
                engine.central.state = .poweredOn
                engine.centralManagerDidUpdateState(engine.central)
                precondition(!engine.central.isScanning, "Canceled intent must never start later")
            }
            engine.stop(); engine.btQueue.sync {}
        }
        for shutdown in [false, true] {
            let engine = ControllerTransport(configuration: .init(discoveryMode: .onDemand),
                hub: ControllerEventHub(), diagnostics: Switch2Diagnostics())
            engine.start()
            engine.btQueue.sync { engine.central.state = .unknown }
            engine.requestDiscoveryWindow(seconds: 60)
            if shutdown {
                engine.shutdown()
                engine.btQueue.sync {
                    precondition(engine.pendingDiscoverySeconds == nil && engine.central == nil)
                }
                engine.start()
            } else {
                engine.configureDiscovery(mode: .automatic, remembered: [])
                engine.configureDiscovery(mode: .onDemand, remembered: [])
            }
            engine.btQueue.sync {
                precondition(engine.pendingDiscoverySeconds == nil && engine.discovery.deadline == nil)
                engine.central.state = .poweredOn
                engine.centralManagerDidUpdateState(engine.central)
                precondition(!engine.central.isScanning, "Mode changes and shutdown must cancel deferred intent")
            }
            engine.stop(); engine.btQueue.sync {}
        }
        print("PASS pending on-demand search across unknown/resetting, full budget, expiry, pre/post denial and radio-off, end/stop/mode-change/shutdown cancellation")
    }

    static func gameCubeAdvertisementIsAdmitted() {
        let engine = ControllerTransport(configuration: .init(discoveryMode: .onDemand),
            hub: ControllerEventHub(), diagnostics: Switch2Diagnostics())
        engine.start(); engine.requestDiscoveryWindow(seconds: 60)
        engine.btQueue.sync {
            var advertisement = Data(repeating: 0, count: 18)
            advertisement[0] = 0x53; advertisement[1] = 0x05
            advertisement[5] = 0x7e; advertisement[6] = 0x05
            advertisement[7] = 0x73; advertisement[8] = 0x20
            let peripheral = CBPeripheral()
            engine.centralManager(engine.central, didDiscover: peripheral,
                advertisementData: [CBAdvertisementDataManufacturerDataKey: advertisement], rssi: -40)
            precondition(engine.central.connections == [peripheral.identifier])
            precondition(engine.connecting[peripheral.identifier]?.session.wasPairingMode == true)
        }
        engine.stop(); engine.btQueue.sync {}
        print("PASS NSO GameCube Nintendo manufacturer advertisement enters connection")
    }

    static func main() {
        pendingOnDemandWindowSurvivesStartup()
        gameCubeAdvertisementIsAdmitted()
        let engine = BridgeEngine.fixture()
        engine.btQueue.sync {
            engine.updateScanning()
            precondition(engine.central.isScanning, "the dashboard explicitly selects automatic discovery")
            func connect(_ slot: Int) -> ControllerSession {
                let s = ControllerSession(peripheral: CBPeripheral(), slot: slot, wasPairingMode: false,
                                          queue: engine.btQueue, delegate: engine)
                engine.connecting[s.peripheral.identifier] = (s, slot)
                engine.sessionReady(s)
                return s
            }
            let first = connect(0), second = connect(1)
            precondition(engine.central.isScanning)
            engine.discovery.configure(mode: .quietWhenReady, remembered: [])
            engine.updateScanning()
            precondition(engine.central.isScanning && engine.discovery.windowIsOpen())
            engine.discovery.cancelWindow(); engine.updateScanning()
            precondition(!engine.central.isScanning && engine.discoveryState == .paused)
            precondition(engine.sessions[0] === first && engine.sessions[1] === second)
            // An advertisement already queued before stopScan must not initiate
            // a new connection while the remembered-ready set is intentionally quiet.
            var advertisement = Data(repeating: 0, count: 18)
            advertisement[0] = 0x53; advertisement[1] = 0x05
            advertisement[5] = 0x7e; advertisement[6] = 0x05
            advertisement[7] = 0x69; advertisement[8] = 0x20
            engine.centralManager(engine.central, didDiscover: CBPeripheral(),
                advertisementData: [CBAdvertisementDataManufacturerDataKey: advertisement], rssi: -40)
            precondition(engine.connecting.isEmpty && engine.central.connections.isEmpty)
            engine.retire(second, cancel: false)
            precondition(engine.central.isScanning, "missing remembered unit must immediately resume discovery")
            precondition(engine.sessions[0] === first)
            engine.discovery.useConnected([first.peripheral.identifier]); engine.updateScanning()
            precondition(!engine.central.isScanning)
        }
        engine.requestDiscoveryWindow(seconds: 60)
        engine.btQueue.sync {
            precondition(engine.central.isScanning && engine.discovery.windowIsOpen())
            precondition(engine.sessions.count == 1, "opening discovery must not interrupt active input")
        }
        let done = DispatchSemaphore(value: 0)
        engine.stop { done.signal() }
        precondition(done.wait(timeout: .now() + 2) == .success)
        engine.btQueue.sync {
            precondition(!engine.central.isScanning && !engine.discovery.windowIsOpen())
            precondition(engine.sessions.isEmpty && engine.deadlines.isEmpty)
            engine.discovery.configure(mode: .automatic, remembered: [])
        }
        engine.start()
        engine.btQueue.sync { precondition(engine.central.isScanning) }
        print("PASS real engine discovery gating, missing-controller recovery, stale advertisements, manual window and stop/resume")
    }
}
