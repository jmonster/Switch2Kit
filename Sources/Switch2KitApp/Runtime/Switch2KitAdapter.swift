import Foundation
import Switch2Kit

// Module-local compatibility names, not copied parsers, calibration or protocol implementations.
// App output formats use package-scoped controller values.
typealias Switch2 = Switch2Kit.Switch2
typealias ControllerState = Switch2Kit.ControllerState

/// The dashboard's value adapter. It performs no decoding, calibration, Bluetooth or output IO.
/// Missing physical controls remain neutral in existing logical-player/output wire formats.


/// Application-queue-confined record of a physical snapshot and its dashboard slot.
/// This is NOT a Bluetooth session: it owns no peripheral, handshake, retry, or decoder.
final class ApplicationController: @unchecked Sendable {
    let slot: Int
    private let manager: Switch2ControllerManager
    private(set) var snapshot: Switch2Controller
    private(set) var state: ControllerState
    private(set) var isRetired = false
    var onRSSI: ((Int) -> Void)?
    var id: Switch2ControllerID { snapshot.id }
    var model: Switch2.Model { snapshot.model }
    var displayName: String { snapshot.name }
    var serialNumber: String { snapshot.serialNumber ?? "peripheral-\(id.rawValue.uuidString)" }
    var batteryMillivolts: UInt16 { snapshot.state.battery.millivolts ?? 0 }
    var lastReportAt: TimeInterval { snapshot.state.receivedAt }
    var lastActivityAt: TimeInterval { snapshot.lastActivityAt }
    var info: Switch2.ControllerInfo? {
        Switch2.ControllerInfo(serialNumber: serialNumber, vendorID: Switch2.nintendoVendorID,
            productID: model.rawValue,
            bodyColor: (snapshot.bodyColor?.red ?? 128, snapshot.bodyColor?.green ?? 128, snapshot.bodyColor?.blue ?? 128),
            buttonColor: (snapshot.buttonColor?.red ?? 128, snapshot.buttonColor?.green ?? 128, snapshot.buttonColor?.blue ?? 128))
    }
    init(snapshot: Switch2Controller, slot: Int, manager: Switch2ControllerManager) {
        self.snapshot = snapshot; self.slot = slot; self.manager = manager
        self.state = Switch2KitStateAdapter.outputState(snapshot.state)
    }
    func update(_ value: Switch2Controller) {
        guard !isRetired, value.id == id, value.sessionGeneration == snapshot.sessionGeneration else { return }
        snapshot = value; state = Switch2KitStateAdapter.outputState(value.state)
    }
    func teardown() { isRetired = true; onRSSI = nil }
    func setRumble(strong: Double, weak: Double) {
        guard !isRetired else { return }
        try? manager.setRumble(for: id, strong: strong, weak: weak)
    }
    func pulseRumble(strong: Double, weak: Double = 0, duration: Double) {
        guard !isRetired else { return }
        // The session's existing safety intent already expires after 500 ms.
        if duration <= 0 { try? manager.setRumble(for: id, strong: 0); return }
        try? manager.pulseRumble(for: id, strong: strong, weak: weak, duration: min(0.5, max(0.01, duration)))
    }
    private var lastRumbleTestAt: TimeInterval = -.infinity
    func testRumble(intensity: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        guard !isRetired, intensity.isFinite, intensity > 0, now - lastRumbleTestAt >= 0.5 else { return }
        lastRumbleTestAt = now
        let level = min(1, intensity)
        try? manager.pulseRumble(for: id, strong: level,
                                weak: model == .proController2 ? level : 0, duration: 0.4)
    }
    func setPlayerNumber(_ value: Int) {
        guard !isRetired else { return }
        try? manager.setPlayerNumber(value, for: id); refreshLEDs()
    }
    private var savedLEDPattern: UInt8? {
        let values = UserDefaults.standard.dictionary(forKey: "controllerSettings")?[serialNumber] as? [String: Any]
        guard let pattern = values?["ledPattern"] as? Int, pattern > 0 else { return nil }
        return UInt8(pattern & 15)
    }
    func refreshLEDs() {
        guard !isRetired else { return }
        try? manager.setPlayerLEDPattern(savedLEDPattern, for: id)
    }
    func setRawLEDs(_ pattern: UInt8?) {
        guard !isRetired else { return }
        try? manager.setPlayerLEDPattern(pattern ?? savedLEDPattern, for: id)
    }
    func requestRSSI() {
        guard !isRetired else { return }
        manager.requestSignalStrength(for: id)
    }
}
