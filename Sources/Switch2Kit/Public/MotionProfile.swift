import Foundation

/// A versioned, explicitly selected calibration for one physical device and holding orientation.
/// The host owns loading and saving. This value never opens a file or reads application preferences.
/// Validation establishes compatibility and numerical safety, not the truth of physical measurements.
public struct Switch2MotionProfile: Equatable, Sendable {
    /// Maximum UTF-8 profile size. Hosts should bound reads before constructing Data.
    public static let maximumEncodedSize = 4096
    /// The raw signed-16-bit report layout and compatibility feature setup understood by this version.
    /// This identifies the existing handshake, not an inferred hardware sampling rate or register range.
    public static let configurationVersion: UInt32 = 1
    /// Locally scoped physical identity, independent of connection generation and player assignment.
    public let device: Switch2ControllerID
    /// Physical model for which the measurements were obtained.
    public let model: Switch2ControllerModel
    /// Short host-visible holding-orientation label: 1...63 lower-case ASCII letters, digits, '-' or '_'.
    public let orientationName: String
    /// Proper rotation from the measured reference frame to right/up/toward-user body axes.
    /// Reflections are not holding orientations. The same proper rotation applies to both sensors.
    public let holdingAxes: [Switch2MotionAxis]
    /// Independently measured sensor-native biases, gains and axis signs in the reference frame.
    /// In particular, stationary gyro data alone cannot establish its gain or signs.
    public let calibration: Switch2MotionCalibration
    /// Exact feature byte sent by both initialization and enablement for this model/configuration.
    public var featureFlags: UInt8 { Switch2.Feature.flags(for: model, profile: .compatibility) }

    /// Creates an explicit profile. No built-in physical-model coefficients are supplied.
    /// Accelerometer full-scale response at 32768 counts must be 1...1024 standard gravities;
    /// gyro response must be 0.01...1024 full turns/s. These generous admission bounds are
    /// numerical/policy limits, NOT claims about the hardware range selected by the controller.
    /// Sensor biases and unique axis selections retain the converter's existing validation.
    public init(device: Switch2ControllerID, model: Switch2ControllerModel, orientationName: String,
                holdingAxes: [Switch2MotionAxis] = [.positiveX, .positiveY, .positiveZ],
                calibration: Switch2MotionCalibration) throws {
        let name = Array(orientationName.utf8)
        guard (1...63).contains(name.count), name.allSatisfy({
            (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }), Self.isProperRotation(holdingAxes),
        Self.gains(calibration.acceleration, in: 9.80665...(9.80665 * 1024)),
        Self.gains(calibration.angularVelocity, in: 0.01...(2 * .pi * 1024)) else {
            throw Switch2KitError.invalidParameter
        }
        self.device = device; self.model = model; self.orientationName = orientationName
        self.holdingAxes = holdingAxes; self.calibration = calibration
    }

    /// Composes the holding rotation into the existing converter's signed axis selectors.
    /// Bias/gain conversion is still performed exactly once by `Switch2MotionCalibration`.
    /// Measured native gyro signs are independent of accelerometer signs; they are not guessed
    /// by treating all signed permutations as interchangeable physical rotations.
    public var bodyCalibration: Switch2MotionCalibration {
        func rotated(_ sensor: Switch2SensorCalibration) -> Switch2SensorCalibration {
            let native = [sensor.xAxis, sensor.yAxis, sensor.zAxis]
            let axes = holdingAxes.map { axis in
                Switch2MotionAxis(rawValue: native[Int(abs(axis.rawValue)) - 1].rawValue * (axis.rawValue < 0 ? -1 : 1))!
            }
            // A proper permutation preserves the already-validated gains, bias and unique axes.
            return try! .init(offset: sensor.offset, unitsPerCount: sensor.unitsPerCount,
                              xAxis: axes[0], yAxis: axes[1], zAxis: axes[2])
        }
        return .init(acceleration: rotated(calibration.acceleration),
                     angularVelocity: rotated(calibration.angularVelocity))
    }

    /// Decodes the strict version-1 text format documented in motion-profiles.md.
    /// Unknown fields, duplicate/trailing records, incorrect units/configuration/range,
    /// non-ASCII input, oversized input, non-finite numbers and malformed dimensions fail closed.
    /// No paths, commands or application settings can be embedded in a profile.
    public init(encoded data: Data) throws {
        guard !data.isEmpty, data.count <= Self.maximumEncodedSize,
              data.allSatisfy({ $0 == 9 || $0 == 10 || $0 == 13 || (32...126).contains($0) }),
              let text = String(data: data, encoding: .utf8) else { throw Switch2KitError.invalidParameter }
        let lines = text.split(whereSeparator: { $0.isNewline }).map {
            $0.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        }
        guard lines.count == 16,
              lines[0] == ["Switch2KitMotionProfile", "1"],
              lines[1].count == 2, lines[1][0] == "device", let id = UUID(uuidString: lines[1][1]),
              lines[2].count == 2, lines[2][0] == "model", lines[2][1].hasPrefix("0x"),
              let modelValue = UInt16(lines[2][1].dropFirst(2), radix: 16),
              let model = Switch2ControllerModel(rawValue: modelValue),
              lines[3].count == 3, lines[3][0] == "configuration", lines[3][1] == "bt-report-v1",
              lines[3][2].hasPrefix("0x"), let flags = UInt8(lines[3][2].dropFirst(2), radix: 16),
              flags == Switch2.Feature.flags(for: model, profile: .compatibility),
              lines[4] == ["raw-range", "-32768", "32767"],
              lines[5].count == 5, lines[5][0] == "orientation",
              lines[6] == ["acceleration", "m/s2"],
              lines[11] == ["angular-velocity", "rad/s"] else { throw Switch2KitError.invalidParameter }
        func vector(_ row: Int, _ key: String) throws -> Switch2Vector3 {
            guard lines[row].count == 4, lines[row][0] == key,
                  let x = Double(lines[row][1]), let y = Double(lines[row][2]), let z = Double(lines[row][3]),
                  x.isFinite, y.isFinite, z.isFinite else { throw Switch2KitError.invalidParameter }
            return .init(x: x, y: y, z: z)
        }
        func sensor(_ start: Int) throws -> Switch2SensorCalibration {
            guard lines[start + 2].count == 4, lines[start + 2][0] == "axes" else {
                throw Switch2KitError.invalidParameter
            }
            let order = try Self.axes(Array(lines[start + 2].dropFirst()))
            let gain = try vector(start + 1, "gain")
            let range = try vector(start + 3, "range-at-32768")
            for (value, expected) in zip([range.x, range.y, range.z], [gain.x, gain.y, gain.z]) {
                guard value > 0, abs(value / 32768 - expected) <= abs(expected) * 1e-12 else {
                    throw Switch2KitError.invalidParameter
                }
            }
            return try .init(offset: vector(start, "bias"), unitsPerCount: gain,
                             xAxis: order[0], yAxis: order[1], zAxis: order[2])
        }
        try self.init(device: .init(rawValue: id), model: model, orientationName: lines[5][1],
                      holdingAxes: Self.axes(Array(lines[5].dropFirst(2))),
                      calibration: .init(acceleration: sensor(7), angularVelocity: sensor(12)))
    }

    /// Encodes a bounded profile. Only the calling host decides whether/where to persist this data.
    /// The range records are gain-derived SI response at 32768 native counts, not factory-register readings.
    public func encoded() -> Data {
        func numbers(_ v: Switch2Vector3) -> String { "\(v.x) \(v.y) \(v.z)" }
        func sensor(_ s: Switch2SensorCalibration) -> [String] {
            let gain = s.unitsPerCount
            return ["bias \(numbers(s.offset))", "gain \(numbers(gain))",
                    "axes \(s.xAxis.rawValue) \(s.yAxis.rawValue) \(s.zAxis.rawValue)",
                    "range-at-32768 \(gain.x * 32768) \(gain.y * 32768) \(gain.z * 32768)"]
        }
        let lines = ["Switch2KitMotionProfile 1", "device \(device.rawValue.uuidString.lowercased())",
            "model 0x\(String(model.rawValue, radix: 16))",
            "configuration bt-report-v1 0x\(String(featureFlags, radix: 16))", "raw-range -32768 32767",
            "orientation \(orientationName) \(holdingAxes.map { String($0.rawValue) }.joined(separator: " "))",
            "acceleration m/s2"] + sensor(calibration.acceleration) + ["angular-velocity rad/s"] + sensor(calibration.angularVelocity)
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private static func axes(_ values: [String]) throws -> [Switch2MotionAxis] {
        let result = values.compactMap { Int32($0).flatMap(Switch2MotionAxis.init(rawValue:)) }
        guard values.count == 3, result.count == 3 else { throw Switch2KitError.invalidParameter }
        return result
    }
    private static func gains(_ sensor: Switch2SensorCalibration, in range: ClosedRange<Double>) -> Bool {
        let gain = sensor.unitsPerCount
        return [gain.x, gain.y, gain.z].allSatisfy { range.contains($0 * 32768) }
    }
    private static func isProperRotation(_ axes: [Switch2MotionAxis]) -> Bool {
        guard axes.count == 3 else { return false }
        let values = axes.map { Int($0.rawValue) }
        guard Set(values.map(abs)).count == 3 else { return false }
        var determinant = values.reduce(1) { $0 * ($1 < 0 ? -1 : 1) }
        for i in 0..<3 { for j in (i + 1)..<3 where abs(values[i]) > abs(values[j]) { determinant = -determinant } }
        return determinant == 1
    }
}
