import Foundation

/// A three-dimensional value. Units and axes are specified by the containing API.
public struct Switch2Vector3: Equatable, Sendable {
    /// X component.
    public let x: Double
    /// Y component.
    public let y: Double
    /// Z component.
    public let z: Double
    /// Creates a vector without clamping or replacing non-finite values.
    /// Calibration initializers validate their input vectors explicitly.
    public init(x: Double, y: Double, z: Double) { self.x = x; self.y = y; self.z = z }
    fileprivate func allSatisfy(_ predicate: (Double) -> Bool) -> Bool { predicate(x) && predicate(y) && predicate(z) }
}

/// Selects one signed sensor-native axis for an output component.
public enum Switch2MotionAxis: Int32, CaseIterable, Sendable {
    /// Sensor-native positive X.
    case positiveX = 1
    /// Sensor-native positive Y.
    case positiveY = 2
    /// Sensor-native positive Z.
    case positiveZ = 3
    /// Sensor-native negative X.
    case negativeX = -1
    /// Sensor-native negative Y.
    case negativeY = -2
    /// Sensor-native negative Z.
    case negativeZ = -3

    fileprivate func component(of vector: Switch2Vector3) -> Double {
        let value: Double
        switch self {
        case .positiveX, .negativeX: value = vector.x
        case .positiveY, .negativeY: value = vector.y
        case .positiveZ, .negativeZ: value = vector.z
        }
        return rawValue < 0 ? -value : value
    }
}

/// Bias, positive per-axis gain, and signed axis order for a raw three-axis sensor.
/// Conversion first computes `(raw - offset) * unitsPerCount` in sensor-native
/// order, then selects signed output axes. This is not a cross-axis correction
/// matrix, automatic stationary detection, gravity removal, or orientation fusion.
public struct Switch2SensorCalibration: Equatable, Sendable {
    /// Zero-input offsets in sensor-native counts, including fractional counts.
    public let offset: Switch2Vector3
    /// Positive output-unit gain per raw count, in sensor-native order.
    public let unitsPerCount: Switch2Vector3
    /// Sensor axis supplying the output X component.
    public let xAxis: Switch2MotionAxis
    /// Sensor axis supplying the output Y component.
    public let yAxis: Switch2MotionAxis
    /// Sensor axis supplying the output Z component.
    public let zAxis: Switch2MotionAxis

    /// Creates a measured calibration. Offsets must be finite signed-16-bit values;
    /// gains must be positive and finite with no overflow across that input range.
    /// Each native axis must appear exactly once. Invalid data throws `invalidParameter`.
    /// Identity axis order is a convenience, not a claim about a controller's orientation.
    public init(offset: Switch2Vector3, unitsPerCount: Switch2Vector3,
                xAxis: Switch2MotionAxis = .positiveX, yAxis: Switch2MotionAxis = .positiveY,
                zAxis: Switch2MotionAxis = .positiveZ) throws {
        guard offset.allSatisfy({ $0.isFinite && (-32768...32767).contains($0) }),
              unitsPerCount.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= Double.greatestFiniteMagnitude / 65536 }),
              abs(xAxis.rawValue) != abs(yAxis.rawValue),
              abs(xAxis.rawValue) != abs(zAxis.rawValue), abs(yAxis.rawValue) != abs(zAxis.rawValue) else {
            throw Switch2KitError.invalidParameter
        }
        self.offset = offset; self.unitsPerCount = unitsPerCount
        self.xAxis = xAxis; self.yAxis = yAxis; self.zAxis = zAxis
    }

    /// Derives offset and gain from measurements at equal negative/positive references.
    /// Each vector component is an independently measured axis mean, NOT one pose.
    /// For an accelerometer, collect six stationary poses at +/- gravity per native axis
    /// and supply magnitude 9.80665 for m/s². For a gyro, use a known rotation rate in rad/s.
    /// Merely leaving a gyro still establishes bias, not its scale or physical axis signs.
    /// Reference counts must be finite in -32768...32767, with positive > negative per axis.
    public init(negativeReference: Switch2Vector3, positiveReference: Switch2Vector3,
                magnitude: Double, xAxis: Switch2MotionAxis = .positiveX,
                yAxis: Switch2MotionAxis = .positiveY, zAxis: Switch2MotionAxis = .positiveZ) throws {
        guard magnitude.isFinite, magnitude > 0,
              negativeReference.allSatisfy({ $0.isFinite && (-32768...32767).contains($0) }),
              positiveReference.allSatisfy({ $0.isFinite && (-32768...32767).contains($0) }),
              positiveReference.x > negativeReference.x, positiveReference.y > negativeReference.y,
              positiveReference.z > negativeReference.z else { throw Switch2KitError.invalidParameter }
        try self.init(offset: .init(x: (negativeReference.x + positiveReference.x) / 2,
                                   y: (negativeReference.y + positiveReference.y) / 2,
                                   z: (negativeReference.z + positiveReference.z) / 2),
                      unitsPerCount: .init(x: magnitude / ((positiveReference.x - negativeReference.x) / 2),
                                           y: magnitude / ((positiveReference.y - negativeReference.y) / 2),
                                           z: magnitude / ((positiveReference.z - negativeReference.z) / 2)),
                      xAxis: xAxis, yAxis: yAxis, zAxis: zAxis)
    }

    /// Converts one raw vector. Finite output is guaranteed by initializer validation.
    /// No dead zone, filtering, sample history, or hidden mutable state is applied.
    public func apply(to raw: Switch2RawVector3) -> Switch2Vector3 {
        let native = Switch2Vector3(x: (Double(raw.x) - offset.x) * unitsPerCount.x,
                                   y: (Double(raw.y) - offset.y) * unitsPerCount.y,
                                   z: (Double(raw.z) - offset.z) * unitsPerCount.z)
        return .init(x: xAxis.component(of: native), y: yAxis.component(of: native), z: zAxis.component(of: native))
    }
}

/// SI motion values in the body-frame axes chosen by the supplied calibration.
/// No world orientation, integration interval, or sensor hardware timestamp is inferred.
public struct Switch2CalibratedMotion: Equatable, Sendable {
    /// Specific force in m/s², including the stationary gravity response.
    public let acceleration: Switch2Vector3
    /// Angular velocity in radians per second, with the supplied axis signs.
    public let angularVelocity: Switch2Vector3
}

/// Explicit motion calibration for a particular device, sensor range, and orientation.
/// There are no default model profiles: the host supplies measured gains, bias and axes.
/// This value is immutable and may be reused concurrently; it owns no queues or timers.
public struct Switch2MotionCalibration: Equatable, Sendable {
    /// Acceleration calibration with gains expressed in m/s² per count.
    public let acceleration: Switch2SensorCalibration
    /// Gyroscope calibration with gains expressed in rad/s per count.
    public let angularVelocity: Switch2SensorCalibration
    /// Creates a profile from validated sensor calibrations. Select a profile for the
    /// actual physical device and its current sensor configuration, not its player slot.
    public init(acceleration: Switch2SensorCalibration, angularVelocity: Switch2SensorCalibration) {
        self.acceleration = acceleration; self.angularVelocity = angularVelocity
    }
    /// Converts available telemetry; preserves gravity and does not alter the raw report.
    /// Magnetometer and temperature remain accessible on the original motion value.
    public func apply(to raw: Switch2Motion) -> Switch2CalibratedMotion {
        .init(acceleration: acceleration.apply(to: raw.accelerationRaw),
              angularVelocity: angularVelocity.apply(to: raw.angularVelocityRaw))
    }
}
