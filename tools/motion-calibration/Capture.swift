import Foundation
import Switch2Kit
import Switch2KitCABI
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// Keep the host run loop/reader serviced while a terminal user positions the controller.
// One byte per readiness notification, a bounded line and a five-minute timeout; no worker
// thread can outlive the session. `input` and timeout are internal regression-test seams.
func waitForCaptureReturn(input: Int32 = STDIN_FILENO, timeoutNanoseconds: UInt64 = 300_000_000_000,
                          service: () throws -> Void) throws {
    let start = DispatchTime.now().uptimeNanoseconds
    var count = 0
    while DispatchTime.now().uptimeNanoseconds - start < timeoutNanoseconds {
        try service()
        var descriptor = pollfd(fd: input, events: Int16(POLLIN), revents: 0)
        let ready = poll(&descriptor, 1, 10)
        if ready < 0 {
            if errno == EINTR { continue }
            throw CalibrationFailure.usage
        }
        guard ready != 0 else { continue }
        guard descriptor.revents & Int16(POLLERR | POLLNVAL) == 0 else { throw CalibrationFailure.usage }
        var byte: UInt8 = 0
        let bytes = read(input, &byte, 1)
        if bytes < 0 && errno == EINTR { continue }
        guard bytes == 1 else { throw CalibrationFailure.usage }
        if byte == 10 { return }
        count += 1
        guard count <= 1024 else { throw CalibrationFailure.usage }
    }
    throw CalibrationFailure.usage
}

#if os(macOS)
import CoreFoundation

// Uses only the existing engine's bounded C reader. No BLE decoder, session or protocol reads.
private final class CaptureSession {
    private let context: OpaquePointer
    private(set) var snapshot = S2KSnapshot()
    private var events = Array(repeating: S2KEvent(), count: 32)

    init() throws {
        guard Thread.isMainThread else { throw CalibrationFailure.unavailable }
        var result: S2KResult = 0
        guard let context = s2k_create(nil, &result), result == S2K_OK else { throw CalibrationFailure.unavailable }
        self.context = context
        guard s2k_start(context) == S2K_OK, s2k_discover(context, 90) == S2K_OK else {
            s2k_destroy(context); throw CalibrationFailure.bluetooth
        }
    }
    func pump() {
        CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.002, false)
        Thread.sleep(forTimeInterval: 0.002) // Keep an empty run loop from becoming a busy spin.
    }
    func read() throws -> (flags: UInt32, events: [S2KEvent]) {
        var count: UInt32 = 0, flags: UInt32 = 0
        let result = events.withUnsafeMutableBufferPointer {
            s2k_read(context, $0.baseAddress, UInt32($0.count), UInt32(MemoryLayout<S2KEvent>.size), &count,
                     &snapshot, UInt32(MemoryLayout<S2KSnapshot>.size), &flags)
        }
        guard result == S2K_OK, count <= events.count, snapshot.count <= S2K_MAX_CONTROLLERS,
              snapshot.abi_version == S2K_ABI_VERSION else { throw CalibrationFailure.bluetooth }
        return (flags, Array(events.prefix(Int(count))))
    }
    func controllers() -> [S2KController] {
        withUnsafeBytes(of: snapshot.controllers) {
            Array($0.bindMemory(to: S2KController.self).prefix(Int(snapshot.count)))
        }
    }
    func stop() {
        _ = s2k_stop(context)
        let deadline = monotonic() + 6
        while monotonic() < deadline {
            pump()
            if (try? read()) != nil && snapshot.running == 0 && snapshot.stopping == 0 { break }
        }
        s2k_destroy(context)
    }
}

private func monotonic() -> Double { s2k_monotonic_time() }
private func same(_ id: S2KID, _ uuid: UUID) -> Bool { UUID(uuid: id.bytes) == uuid }

func listControllers() throws {
    let session = try CaptureSession()
    defer { session.stop() }
    print("Explicit diagnostic discovery: locally scoped physical IDs will be displayed for 20 seconds.")
    let deadline = monotonic() + 20
    var shown = Set<UUID>()
    while monotonic() < deadline {
        session.pump(); _ = try session.read()
        if session.snapshot.bluetooth == S2K_BT_UNAUTHORIZED || session.snapshot.bluetooth == S2K_BT_UNSUPPORTED ||
            session.snapshot.bluetooth == S2K_BT_OFF { throw CalibrationFailure.bluetooth }
        for controller in session.controllers() where shown.count < 64 {
            let id = UUID(uuid: controller.id.bytes)
            if shown.insert(id).inserted { print("\(id.uuidString) model=\(controller.model)") }
        }
    }
}

func capture(binding: CaptureBinding, rate: Double? = nil, evidence: String = "") throws -> Data {
    let session = try CaptureSession()
    defer { session.stop() }
    print("Explicit motion capture. Keep other hosts disconnected; place the selected controller within range.")
    var selected: S2KController?
    let readinessDeadline = monotonic() + 60
    while selected == nil && monotonic() < readinessDeadline {
        session.pump(); _ = try session.read()
        selected = session.controllers().first { same($0.id, binding.device.rawValue) && $0.model == binding.model.rawValue }
        if session.snapshot.bluetooth == S2K_BT_UNAUTHORIZED || session.snapshot.bluetooth == S2K_BT_UNSUPPORTED ||
            session.snapshot.bluetooth == S2K_BT_OFF { throw CalibrationFailure.bluetooth }
    }
    guard let selected else { throw CalibrationFailure.bluetooth }
    let generation = UUID(uuid: selected.connection_id.bytes)
    var lines = ["switch2kit-capture,1", (binding.fields + [generation.uuidString]).joined(separator: ",")]
    var windows = [[CalibrationSample]]()
    for pose in rate == nil ? poses + ["zero"] : poses {
        if let rate {
            print("Use the independently measured fixture rate \(rate) rad/s about the \(pose) body axis. Press Return once steady.")
        } else if pose == "zero" { print("Place the controller completely still. Press Return for gyro zero-rate sampling.") }
        else { print("Point the \(pose) body axis vertically upward, then hold still. Press Return when settled.") }
        func discardPendingReports() throws {
            session.pump()
            // Reconciliation is permitted between poses, never used as a sensor measurement.
            for _ in 0..<16 {
                let batch = try session.read()
                guard session.controllers().contains(where: {
                    same($0.id, binding.device.rawValue) && same($0.connection_id, generation) && $0.model == binding.model.rawValue
                }) else { throw CalibrationFailure.continuity }
                if batch.flags & UInt32(S2K_READ_MORE) == 0 { return }
            }
            throw CalibrationFailure.continuity
        }
        try waitForCaptureReturn(service: discardPendingReports)
        // Discard another second while the main run loop continues to run. This is settling
        // time, not a claim that host receive timestamps describe hardware sampling time.
        let settleUntil = monotonic() + 1
        while monotonic() < settleUntil { try discardPendingReports() }
        let start = monotonic(), deadline = start + 10
        var samples = [CalibrationSample]()
        while monotonic() < deadline {
            session.pump()
            let batch = try session.read()
            guard batch.flags & UInt32(S2K_READ_RESYNC) == 0,
                  session.controllers().contains(where: {
                      same($0.id, binding.device.rawValue) && same($0.connection_id, generation) && $0.model == binding.model.rawValue
                  }) else { throw CalibrationFailure.continuity }
            for event in batch.events where event.kind == S2K_EVENT_INPUT && same(event.controller.id, binding.device.rawValue) {
                let controller = event.controller, state = controller.state
                guard same(controller.connection_id, generation), controller.model == binding.model.rawValue,
                      state.present & UInt32(S2K_HAS_MOTION) != 0,
                      state.received_at.isFinite, state.received_at > 0 else { throw CalibrationFailure.continuity }
                // A report can race the initial drain. Skip old reports only before this
                // pose starts; after its first sample, backwards time invalidates the run.
                if state.received_at < start {
                    guard samples.isEmpty else { throw CalibrationFailure.continuity }
                    continue
                }
                let age = monotonic() - state.received_at
                guard age >= 0, age <= 0.1 else { throw CalibrationFailure.continuity }
                let fields = [String(state.sequence), String(state.received_at),
                              String(state.accel.0), String(state.accel.1), String(state.accel.2),
                              String(state.gyro.0), String(state.gyro.1), String(state.gyro.2)]
                let sample = try CalibrationSample(fields)
                if let previous = samples.last {
                    guard previous.sequence != UInt64.max, sample.sequence == previous.sequence + 1,
                          sample.receivedAt > previous.receivedAt, sample.receivedAt - previous.receivedAt <= 0.1 else {
                        throw CalibrationFailure.continuity
                    }
                }
                guard samples.count < sampleLimit else { throw CalibrationFailure.samples }
                samples.append(sample)
            }
            if samples.count >= 128, let first = samples.first, let last = samples.last,
               last.receivedAt - first.receivedAt >= 2 { break }
        }
        guard samples.count >= 128, let first = samples.first, let last = samples.last,
              (1...10).contains(last.receivedAt - first.receivedAt) else { throw CalibrationFailure.samples }
        if rate != nil { windows.append(samples) }
        else { lines.append(contentsOf: samples.map { ([pose] + $0.fields).joined(separator: ",") }) }
        print("Captured \(samples.count) fresh reports; pose fitting and motion rejection run before profile export.")
    }
    if let rate { return try knownRateReference(binding: binding, windows: windows, rate: rate, evidence: evidence) }
    let data = Data((lines.joined(separator: "\n") + "\n").utf8)
    _ = try StationaryRecord(data: data)
    return data
}
#else
// Offline fitting/validation are portable. This is not a transport fake.
func listControllers() throws { throw CalibrationFailure.unavailable }
func capture(binding: CaptureBinding, rate: Double? = nil, evidence: String = "") throws -> Data { throw CalibrationFailure.unavailable }
#endif
