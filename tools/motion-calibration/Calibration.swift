import Foundation
import Switch2Kit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// This tool is an explicit diagnostic action. Nothing is captured by the library by default.
// No conversion is implemented here: use #58's reference initializer and apply(to:).
enum CalibrationFailure: String, Error {
    case usage = "Check the command and required arguments. See tools/motion-calibration/README.md."
    case file = "Use a readable regular input file within the size limit and a new output filename."
    case format = "Malformed or incompatible calibration record. No profile was saved."
    case samples = "Capture needs 128..2048 consecutive samples over 1..10 seconds for each of seven poses."
    case continuity = "Capture contains missing, repeated, stale or discontinuous reports. Recapture the affected run."
    case clipping = "A sensor reached the signed report limit. Reduce the input/range and recapture."
    case unstable = "Observable motion, noise, cross-axis response or an incorrectly placed pose makes this capture unusable."
    case reference = "Supply independent gyro scale AND positive-rotation axes from known-rate measurements or verified configuration."
    case unavailable = "Live capture requires the macOS native library and Bluetooth permission."
    case bluetooth = "Bluetooth/controller readiness failed. Check Bluetooth permission, radio state and the selected controller."
}

let poses = ["+X", "-X", "+Y", "-Y", "+Z", "-Z"]
let sampleLimit = 2048
let captureLimit = 4 * 1024 * 1024
let gravity = 9.80665

// Tool-only capture metadata. Profiles themselves use the one published library format.
struct CaptureBinding: Equatable {
    let device: Switch2ControllerID
    let model: Switch2ControllerModel
    let holding: String
    let featureFlags: UInt8

    init(_ fields: [String]) throws {
        guard fields.count == 5, let uuid = UUID(uuidString: fields[0]),
              let rawModel = UInt16(fields[1]), let model = Switch2ControllerModel(rawValue: rawModel),
              fields[2] == "bt-report-v1", fields[3].hasPrefix("0x"),
              let flags = UInt8(fields[3].dropFirst(2), radix: 16) else { throw CalibrationFailure.format }
        // Only validates binding/name syntax against the existing profile API. These
        // temporary numerical coefficients are never selected, saved or called measurements.
        let sensor = try Switch2SensorCalibration(offset: .init(x: 0, y: 0, z: 0),
                                                   unitsPerCount: .init(x: 0.001, y: 0.001, z: 0.001))
        let binding = try Switch2MotionProfile(device: .init(rawValue: uuid), model: model,
            orientationName: fields[4], calibration: .init(acceleration: sensor, angularVelocity: sensor))
        guard flags == binding.featureFlags else { throw CalibrationFailure.format }
        device = binding.device; self.model = model; holding = binding.orientationName; featureFlags = flags
    }
    var fields: [String] {
        [device.rawValue.uuidString, String(model.rawValue), "bt-report-v1", "0x" + String(featureFlags, radix: 16), holding]
    }
}

enum GyroBasis: String { case knownRate = "known-rate", verifiedConfiguration = "verified-configuration" }

struct CalibrationSample {
    let sequence: UInt64
    let receivedAt: Double
    let acceleration, gyro: Switch2RawVector3
    init(_ fields: [String]) throws {
        guard fields.count == 8, let sequence = UInt64(fields[0]), sequence > 0,
              let time = Double(fields[1]), time.isFinite, time > 0 else { throw CalibrationFailure.format }
        let values = fields.dropFirst(2).compactMap(Int16.init)
        guard values.count == 6 else { throw CalibrationFailure.format }
        guard values.allSatisfy({ $0 != Int16.min && $0 != Int16.max }) else { throw CalibrationFailure.clipping }
        self.sequence = sequence; receivedAt = time
        acceleration = .init(x: values[0], y: values[1], z: values[2])
        gyro = .init(x: values[3], y: values[4], z: values[5])
    }
    var fields: [String] {
        [String(sequence), String(receivedAt), String(acceleration.x), String(acceleration.y), String(acceleration.z),
         String(gyro.x), String(gyro.y), String(gyro.z)]
    }
}

struct StationaryRecord {
    let binding: CaptureBinding
    let connection: UUID
    let windows: [[CalibrationSample]]

    init(data: Data) throws {
        let lines = try boundedLines(data, maximumLines: 2 + 7 * sampleLimit, maximumLineBytes: 512)
        guard lines.count >= 2, lines[0] == "switch2kit-capture,1" else { throw CalibrationFailure.format }
        let fields = split(lines[1])
        guard fields.count == 6, let connection = UUID(uuidString: fields[5]),
              connection != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) else { throw CalibrationFailure.format }
        binding = try CaptureBinding(Array(fields.prefix(5))); self.connection = connection
        var samples = Array(repeating: [CalibrationSample](), count: 7)
        let names = poses + ["zero"]
        var phase = 0
        var previous: CalibrationSample?
        for line in lines.dropFirst(2) {
            let values = split(line)
            guard values.count == 9, let index = names.firstIndex(of: values[0]),
                  index == phase || index == phase + 1, index < 7 else { throw CalibrationFailure.format }
            phase = index
            let sample = try CalibrationSample(Array(values.dropFirst()))
            if let previous {
                guard sample.sequence > previous.sequence, sample.receivedAt > previous.receivedAt else {
                    throw CalibrationFailure.continuity
                }
            }
            if let previous = samples[index].last {
                guard previous.sequence != UInt64.max, sample.sequence == previous.sequence + 1,
                      sample.receivedAt - previous.receivedAt <= 0.1 else { throw CalibrationFailure.continuity }
            }
            guard samples[index].count < sampleLimit else { throw CalibrationFailure.samples }
            samples[index].append(sample); previous = sample
        }
        for window in samples {
            guard (128...sampleLimit).contains(window.count), let first = window.first, let last = window.last,
                  (1...10).contains(last.receivedAt - first.receivedAt) else { throw CalibrationFailure.samples }
        }
        windows = samples
    }
}

struct GyroReference {
    let binding: CaptureBinding
    let basis: GyroBasis
    let evidence: String
    let calibration: Switch2SensorCalibration

    init(data: Data) throws {
        let lines = try boundedLines(data, maximumLines: 10, maximumLineBytes: 600)
        guard lines.count >= 5, lines[0] == "switch2kit-gyro-reference,1" else { throw CalibrationFailure.reference }
        binding = try CaptureBinding(split(lines[1]))
        let source = lines[2].split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard source.count == 2, let basis = GyroBasis(rawValue: source[0]),
              !source[1].isEmpty, source[1].utf8.count <= 512,
              !source[1].unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw CalibrationFailure.reference
        }
        self.basis = basis; evidence = source[1]
        switch basis {
        case .verifiedConfiguration:
            guard lines.count == 5 else { throw CalibrationFailure.reference }
            let gainFields = split(lines[3]); let axisFields = split(lines[4])
            guard gainFields.count == 4, gainFields[0] == "gain-rad/s-per-count", axisFields.count == 4, axisFields[0] == "axes" else {
                throw CalibrationFailure.reference
            }
            let gains = gainFields.dropFirst().compactMap(Double.init)
            let axes = axisFields.dropFirst().compactMap(Int32.init).compactMap(Switch2MotionAxis.init(rawValue:))
            guard gains.count == 3, axes.count == 3 else { throw CalibrationFailure.reference }
            calibration = try .init(offset: .init(x: 0, y: 0, z: 0),
                                    unitsPerCount: .init(x: gains[0], y: gains[1], z: gains[2]),
                                    xAxis: axes[0], yAxis: axes[1], zAxis: axes[2])
        case .knownRate:
            guard lines.count == 10 else { throw CalibrationFailure.reference }
            let rateFields = split(lines[3])
            guard rateFields.count == 2, rateFields[0] == "rate-rad/s", let rate = Double(rateFields[1]),
                  rate.isFinite, rate > 0 else { throw CalibrationFailure.reference }
            var means = [[Double]]()
            for index in 0..<6 {
                let values = split(lines[index + 4])
                guard values.count == 4, values[0] == poses[index] else { throw CalibrationFailure.reference }
                let raw = values.dropFirst().compactMap(Double.init)
                guard raw.count == 3, raw.allSatisfy({ $0.isFinite && (-32767...32766).contains($0) }) else {
                    throw CalibrationFailure.reference
                }
                means.append(raw)
            }
            calibration = try derive(means: means, magnitude: rate)
        }
    }
}

func split(_ value: String) -> [String] { value.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
func components(_ value: Switch2RawVector3) -> [Double] { [Double(value.x), Double(value.y), Double(value.z)] }
func components(_ value: Switch2Vector3) -> [Double] { [value.x, value.y, value.z] }
func vector(_ value: [Double]) -> Switch2Vector3 { .init(x: value[0], y: value[1], z: value[2]) }

// Welford accumulation; at most three sums/second moments, never another sample history.
struct Moments {
    var count = 0
    var mean = [0.0, 0.0, 0.0], m2 = [0.0, 0.0, 0.0]
    mutating func add(_ values: [Double]) {
        count += 1
        for axis in 0..<3 {
            let delta = values[axis] - mean[axis]
            mean[axis] += delta / Double(count)
            m2[axis] += delta * (values[axis] - mean[axis])
        }
    }
    var standardDeviation: [Double] { m2.map { sqrt(max(0, $0 / Double(max(1, count - 1)))) } }
}

// The six means are ordered +X,-X,+Y,-Y,+Z,-Z in the desired SDL body frame.
// Learn each sensor's native map independently. A reflection in a native map is not
// reused as a physical holding rotation, especially not for axial gyro vectors.
func derive(means: [[Double]], magnitude: Double) throws -> Switch2SensorCalibration {
    guard means.count == 6, means.allSatisfy({ $0.count == 3 && $0.allSatisfy(\.isFinite) }),
          magnitude.isFinite, magnitude > 0 else { throw CalibrationFailure.unstable }
    var negative = [0.0, 0.0, 0.0], positive = negative
    var axes = [Switch2MotionAxis](), used = Set<Int>()
    for body in 0..<3 {
        let difference = (0..<3).map { means[2 * body][$0] - means[2 * body + 1][$0] }
        guard let native = (0..<3).max(by: { abs(difference[$0]) < abs(difference[$1]) }),
              abs(difference[native]) >= 256, used.insert(native).inserted,
              (0..<3).allSatisfy({ $0 == native || abs(difference[$0]) <= 0.03 * abs(difference[native]) }),
              let axis = Switch2MotionAxis(rawValue: Int32(native + 1) * (difference[native] < 0 ? -1 : 1)) else {
            throw CalibrationFailure.unstable
        }
        negative[native] = min(means[2 * body][native], means[2 * body + 1][native])
        positive[native] = max(means[2 * body][native], means[2 * body + 1][native])
        axes.append(axis)
    }
    let result = try Switch2SensorCalibration(negativeReference: vector(negative), positiveReference: vector(positive),
                                              magnitude: magnitude, xAxis: axes[0], yAxis: axes[1], zAxis: axes[2])
    // The reference constructor validates dimensions/range/gain. Check unused-axis bias
    // consistency too, using the actual converter and a half-count quantization allowance.
    let allowance = components(result.unitsPerCount).max()! / 2
    for index in 0..<6 {
        guard means[index].allSatisfy({ (-32768...32767).contains($0) }) else { throw CalibrationFailure.unstable }
        let raw = means[index].map { Int16($0.rounded()) }
        let value = components(result.apply(to: .init(x: raw[0], y: raw[1], z: raw[2])))
        for axis in 0..<3 {
            let target = axis == index / 2 ? magnitude * (index.isMultiple(of: 2) ? 1 : -1) : 0
            guard abs(value[axis] - target) <= 0.03 * magnitude + allowance else { throw CalibrationFailure.unstable }
        }
    }
    return result
}

func fit(_ record: StationaryRecord, gyro reference: GyroReference) throws -> Switch2MotionProfile {
    guard record.binding == reference.binding else { throw CalibrationFailure.reference }
    let accelMeans = record.windows.prefix(6).map { window in
        var moments = Moments(); for sample in window { moments.add(components(sample.acceleration)) }; return moments.mean
    }
    let acceleration = try derive(means: accelMeans, magnitude: gravity)
    var zero = Moments()
    for sample in record.windows[6] { zero.add(components(sample.gyro)) }
    let gyro = try Switch2SensorCalibration(offset: vector(zero.mean), unitsPerCount: reference.calibration.unitsPerCount,
                                            xAxis: reference.calibration.xAxis, yAxis: reference.calibration.yAxis,
                                            zAxis: reference.calibration.zAxis)
    for (pose, window) in record.windows.enumerated() {
        var accelerationStats = Moments(), gyroStats = Moments()
        for sample in window {
            let a = components(acceleration.apply(to: sample.acceleration))
            let g = components(gyro.apply(to: sample.gyro))
            accelerationStats.add(a); gyroStats.add(g)
            guard g.allSatisfy({ abs($0) <= 0.05 }) else { throw CalibrationFailure.unstable }
            if pose < 6 {
                for axis in 0..<3 {
                    let expected = axis == pose / 2 ? gravity * (pose.isMultiple(of: 2) ? 1 : -1) : 0
                    guard abs(a[axis] - expected) <= 0.5 else { throw CalibrationFailure.unstable }
                }
            } else {
                guard abs(sqrt(a.reduce(0) { $0 + $1 * $1 }) - gravity) <= 0.5 else { throw CalibrationFailure.unstable }
            }
        }
        guard accelerationStats.standardDeviation.allSatisfy({ $0 <= 0.15 }),
              gyroStats.standardDeviation.allSatisfy({ $0 <= 0.015 }) else { throw CalibrationFailure.unstable }
    }
    let binding = record.binding
    if reference.basis == .knownRate {
        // Independent references should agree on the zero-rate bias within the
        // same stationary admission bound. The tool cannot certify the fixture rate.
        for axis in 0..<3 {
            guard abs((zero.mean[axis] - components(reference.calibration.offset)[axis]) *
                      components(gyro.unitsPerCount)[axis]) <= 0.05 else { throw CalibrationFailure.reference }
        }
    }
    return try .init(device: binding.device, model: binding.model, orientationName: binding.holding,
                     calibration: .init(acceleration: acceleration, angularVelocity: gyro))
}

func knownRateReference(binding: CaptureBinding, windows: [[CalibrationSample]], rate: Double,
                        evidence: String) throws -> Data {
    guard windows.count == 6, windows.allSatisfy({ (128...sampleLimit).contains($0.count) }),
          rate.isFinite, rate > 0, !evidence.isEmpty, evidence.utf8.count <= 512,
          !evidence.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
        throw CalibrationFailure.reference
    }
    var means = [[Double]]()
    for window in windows {
        var stats = Moments()
        for sample in window { stats.add(components(sample.gyro)) }
        means.append(stats.mean)
    }
    let calibration = try derive(means: means, magnitude: rate)
    for (pose, window) in windows.enumerated() {
        var stats = Moments()
        for sample in window {
            let values = components(calibration.apply(to: sample.gyro))
            stats.add(values)
            for axis in 0..<3 {
                let expected = axis == pose / 2 ? rate * (pose.isMultiple(of: 2) ? 1 : -1) : 0
                guard abs(values[axis] - expected) <= max(0.01, rate * 0.05) else {
                    throw CalibrationFailure.unstable
                }
            }
        }
        guard stats.standardDeviation.allSatisfy({ $0 <= max(0.005, rate * 0.02) }) else {
            throw CalibrationFailure.unstable
        }
    }
    var lines = ["switch2kit-gyro-reference,1", binding.fields.joined(separator: ","),
                 "known-rate," + evidence, "rate-rad/s," + String(rate)]
    for (pose, mean) in zip(poses, means) {
        lines.append(([pose] + mean.map(String.init(describing:))).joined(separator: ","))
    }
    let data = Data((lines.joined(separator: "\n") + "\n").utf8)
    _ = try GyroReference(data: data)
    return data
}

func boundedLines(_ data: Data, maximumLines: Int, maximumLineBytes: Int) throws -> [String] {
    guard !data.isEmpty, data.count <= captureLimit else { throw CalibrationFailure.file }
    var lines = [String](), start = data.startIndex
    // Avoid split() over attacker-controlled millions of line separators.
    for index in data.indices {
        guard index - start <= maximumLineBytes else { throw CalibrationFailure.format }
        if data[index] == 10 {
            guard lines.count < maximumLines, let line = String(data: data[start..<index], encoding: .utf8) else {
                throw CalibrationFailure.format
            }
            lines.append(line.hasSuffix("\r") ? String(line.dropLast()) : line)
            start = index + 1
        }
    }
    if start != data.endIndex {
        guard lines.count < maximumLines, let line = String(data: data[start..<data.endIndex], encoding: .utf8) else {
            throw CalibrationFailure.format
        }
        lines.append(line)
    }
    return lines
}

func readBounded(_ path: String, limit: Int) throws -> Data {
    guard !path.isEmpty, path.utf8.count <= 4096, !path.utf8.contains(0), limit > 0 else { throw CalibrationFailure.file }
    // O_NONBLOCK lets fstat reject a FIFO/device without waiting for a writer.
    let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw CalibrationFailure.file }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? handle.close() }
    var info = stat()
    guard fstat(handle.fileDescriptor, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
          info.st_size > 0, info.st_size <= limit else { throw CalibrationFailure.file }
    var data = Data()
    while data.count <= limit {
        guard let chunk = try handle.read(upToCount: min(65_536, limit + 1 - data.count)), !chunk.isEmpty else { break }
        data.append(chunk)
    }
    guard data.count <= limit else { throw CalibrationFailure.file }
    return data
}

func saveNew(_ data: Data, to path: String) throws {
    guard !path.isEmpty, path.utf8.count <= 4096, !path.utf8.contains(0) else { throw CalibrationFailure.file }
    // Explicit export only; a restrictive mode and O_EXCL prevent silent overwrite/symlink replacement.
    let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
    guard fd >= 0 else { throw CalibrationFailure.file }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() }
    catch { try? handle.close(); throw CalibrationFailure.file }
}
