import Foundation
import Switch2Kit
import Switch2KitCABI

private func cSensor(_ sensor: Switch2SensorCalibration) -> S2KSensorCalibration {
    var result = S2KSensorCalibration()
    result.offset = (sensor.offset.x, sensor.offset.y, sensor.offset.z)
    result.units_per_count = (sensor.unitsPerCount.x, sensor.unitsPerCount.y, sensor.unitsPerCount.z)
    result.axes = (sensor.xAxis.rawValue, sensor.yAxis.rawValue, sensor.zAxis.rawValue)
    return result
}
private func cCalibration(_ calibration: Switch2MotionCalibration) -> S2KMotionCalibration {
    var result = S2KMotionCalibration()
    result.version = UInt32(S2K_MOTION_CALIBRATION_VERSION)
    result.struct_size = UInt32(MemoryLayout<S2KMotionCalibration>.size)
    result.acceleration = cSensor(calibration.acceleration)
    result.angular_velocity = cSensor(calibration.angularVelocity)
    return result
}
private func cProfile(_ profile: Switch2MotionProfile) -> S2KMotionProfile {
    var result = S2KMotionProfile()
    result.version = UInt32(S2K_MOTION_PROFILE_VERSION)
    result.struct_size = UInt32(MemoryLayout<S2KMotionProfile>.size)
    result.device = cID(profile.device.rawValue)
    result.model = UInt32(profile.model.rawValue)
    result.configuration = Switch2MotionProfile.configurationVersion
    result.feature_flags = UInt32(profile.featureFlags)
    result.calibration = cCalibration(profile.calibration)
    result.holding_axes = (profile.holdingAxes[0].rawValue, profile.holdingAxes[1].rawValue, profile.holdingAxes[2].rawValue)
    withUnsafeMutableBytes(of: &result.orientation) { bytes in
        bytes.copyBytes(from: Array(profile.orientationName.utf8) + Array(repeating: UInt8(0), count: 64 - profile.orientationName.utf8.count))
    }
    return result
}
private func swiftProfile(_ value: S2KMotionProfile) throws -> Switch2MotionProfile {
    let bytes = withUnsafeBytes(of: value.orientation) { Array($0) }
    guard value.reserved == 0, value.reserved2 == 0,
          value.configuration == Switch2MotionProfile.configurationVersion,
          let modelValue = UInt16(exactly: value.model), let model = Switch2ControllerModel(rawValue: modelValue),
          let end = bytes.firstIndex(of: 0), bytes[end...].allSatisfy({ $0 == 0 }),
          let name = String(bytes: bytes[..<end], encoding: .utf8),
          let x = Switch2MotionAxis(rawValue: value.holding_axes.0),
          let y = Switch2MotionAxis(rawValue: value.holding_axes.1),
          let z = Switch2MotionAxis(rawValue: value.holding_axes.2) else { throw Switch2KitError.invalidParameter }
    let profile = try Switch2MotionProfile(device: .init(rawValue: swiftID(value.device)), model: model,
        orientationName: name, holdingAxes: [x, y, z],
        calibration: .init(acceleration: sensorCalibration(value.calibration.acceleration),
                           angularVelocity: sensorCalibration(value.calibration.angular_velocity)))
    guard value.feature_flags == profile.featureFlags else { throw Switch2KitError.invalidParameter }
    return profile
}

/// C ABI entry point; bounded host-owned bytes, validation and output rules are in Switch2KitMotionProfile.h.
@_cdecl("s2k_decode_motion_profile")
public func decodeMotionProfile(_ bytes: UnsafePointer<UInt8>?, _ byteCount: UInt32,
                                _ output: UnsafeMutablePointer<S2KMotionProfile>?, _ outputSize: UInt32) -> Int32 {
    guard let bytes, let output, byteCount > 0, byteCount <= Switch2MotionProfile.maximumEncodedSize else {
        return Int32(S2K_INVALID_ARGUMENT)
    }
    guard outputSize == MemoryLayout<S2KMotionProfile>.size else { return Int32(S2K_ABI_MISMATCH) }
    do {
        let profile = try Switch2MotionProfile(encoded: Data(bytes: bytes, count: Int(byteCount)))
        output.pointee = cProfile(profile)
        return Int32(S2K_OK)
    } catch { return Int32(S2K_INVALID_ARGUMENT) }
}

/// C ABI entry point; composes a validated physical profile through the shared Swift implementation.
@_cdecl("s2k_motion_profile_calibration")
public func motionProfileCalibration(_ profile: UnsafePointer<S2KMotionProfile>?, _ controller: UnsafePointer<S2KController>?,
                                     _ output: UnsafeMutablePointer<S2KMotionCalibration>?, _ outputSize: UInt32) -> Int32 {
    guard let profile, let output else { return Int32(S2K_INVALID_ARGUMENT) }
    let value = profile.pointee
    guard value.version == S2K_MOTION_PROFILE_VERSION, value.struct_size == MemoryLayout<S2KMotionProfile>.size,
          value.calibration.version == S2K_MOTION_CALIBRATION_VERSION,
          value.calibration.struct_size == MemoryLayout<S2KMotionCalibration>.size,
          outputSize == MemoryLayout<S2KMotionCalibration>.size else { return Int32(S2K_ABI_MISMATCH) }
    do {
        let validated = try swiftProfile(value)
        if let controller {
            guard swiftID(controller.pointee.id) == validated.device.rawValue,
                  controller.pointee.model == value.model else { return Int32(S2K_INVALID_ARGUMENT) }
            guard controller.pointee.capabilities & UInt32(S2K_CAP_RAW_MOTION) != 0 else {
                return Int32(S2K_UNSUPPORTED_OPERATION)
            }
        }
        output.pointee = cCalibration(validated.bodyCalibration)
        return Int32(S2K_OK)
    } catch { return Int32(S2K_INVALID_ARGUMENT) }
}

/// C ABI entry point; same monotonic host clock used when accepting a controller input report.
@_cdecl("s2k_monotonic_time")
public func monotonicTime() -> Double { ProcessInfo.processInfo.systemUptime }
