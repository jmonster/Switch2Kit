import Switch2Kit
import Switch2KitCABI

func sensorCalibration(_ value: S2KSensorCalibration) throws -> Switch2SensorCalibration {
    guard value.reserved == 0,
          let x = Switch2MotionAxis(rawValue: value.axes.0),
          let y = Switch2MotionAxis(rawValue: value.axes.1),
          let z = Switch2MotionAxis(rawValue: value.axes.2) else { throw Switch2KitError.invalidParameter }
    return try .init(offset: .init(x: value.offset.0, y: value.offset.1, z: value.offset.2),
                     unitsPerCount: .init(x: value.units_per_count.0, y: value.units_per_count.1, z: value.units_per_count.2),
                     xAxis: x, yAxis: y, zAxis: z)
}

/// C ABI entry point; explicit calibration, size checks and output ownership are specified in Switch2KitMotion.h.
@_cdecl("s2k_convert_motion")
public func convertMotion(_ state: UnsafePointer<S2KState>?, _ calibration: UnsafePointer<S2KMotionCalibration>?,
                          _ output: UnsafeMutablePointer<S2KCalibratedMotion>?, _ outputSize: UInt32) -> Int32 {
    guard let state, let calibration, let output else { return Int32(S2K_INVALID_ARGUMENT) }
    guard calibration.pointee.version == S2K_MOTION_CALIBRATION_VERSION,
          calibration.pointee.struct_size == MemoryLayout<S2KMotionCalibration>.size,
          outputSize == MemoryLayout<S2KCalibratedMotion>.size else { return Int32(S2K_ABI_MISMATCH) }
    let input = state.pointee
    guard input.present & UInt32(S2K_HAS_MOTION) != 0 else { return Int32(S2K_NOT_READY) }
    guard input.received_at.isFinite, input.received_at >= 0 else { return Int32(S2K_INVALID_ARGUMENT) }
    do {
        let profile = try Switch2MotionCalibration(acceleration: sensorCalibration(calibration.pointee.acceleration),
                                                  angularVelocity: sensorCalibration(calibration.pointee.angular_velocity))
        let raw = Switch2Motion(accelerationRaw: .init(x: input.accel.0, y: input.accel.1, z: input.accel.2),
                                angularVelocityRaw: .init(x: input.gyro.0, y: input.gyro.1, z: input.gyro.2),
                                magneticFieldRaw: .init(), temperatureCelsius: input.temperature_celsius)
        let motion = profile.apply(to: raw)
        var result = S2KCalibratedMotion()
        result.acceleration = (motion.acceleration.x, motion.acceleration.y, motion.acceleration.z)
        result.angular_velocity = (motion.angularVelocity.x, motion.angularVelocity.y, motion.angularVelocity.z)
        result.received_at = input.received_at; result.sequence = input.sequence
        output.pointee = result
        return Int32(S2K_OK)
    } catch { return Int32(S2K_INVALID_ARGUMENT) }
}
