import Foundation
import XCTest
import Switch2Kit
import Switch2KitC
import Switch2KitCABI

final class CMotionProfileTests: XCTestCase {
    private func encoded() throws -> Data {
        // Synthetic input, intentionally not shipped as a measured model profile.
        let sensor = try Switch2SensorCalibration(offset: .init(x: 0, y: 0, z: 0),
            unitsPerCount: .init(x: 0.01, y: 0.01, z: 0.01))
        return try Switch2MotionProfile(device: .init(rawValue: UUID(uuidString: "01234567-89ab-cdef-0123-456789abcdef")!),
            model: .proController2, orientationName: "upright", holdingAxes: [.negativeY, .positiveX, .positiveZ],
            calibration: .init(acceleration: sensor, angularVelocity: sensor)).encoded()
    }
    private func profile() throws -> S2KMotionProfile {
        let data = try encoded(); var value = S2KMotionProfile()
        let result = data.withUnsafeBytes { bytes in
            decodeMotionProfile(bytes.bindMemory(to: UInt8.self).baseAddress, UInt32(bytes.count), &value, 256)
        }
        XCTAssertEqual(result, Int32(S2K_OK)); return value
    }
    func testLayoutDecodeCompositionAndActualConversion() throws {
        XCTAssertEqual(MemoryLayout<S2KMotionProfile>.size, 256)
        XCTAssertEqual(MemoryLayout<S2KMotionProfile>.offset(of: \.calibration), 40)
        XCTAssertEqual(MemoryLayout<S2KMotionProfile>.offset(of: \.orientation), 192)
        var value = try profile(), calibration = S2KMotionCalibration()
        XCTAssertEqual(motionProfileCalibration(&value, nil, &calibration, 136), Int32(S2K_OK))
        var state = S2KState(), output = S2KCalibratedMotion()
        state.present = UInt32(S2K_HAS_MOTION); state.sequence = 5; state.received_at = 12
        state.accel = (100, 200, 300); state.gyro = (400, 500, 600)
        XCTAssertEqual(convertMotion(&state, &calibration, &output, 64), Int32(S2K_OK))
        XCTAssertEqual(output.acceleration.0, -2); XCTAssertEqual(output.acceleration.1, 1)
        XCTAssertEqual(output.angular_velocity.0, -5); XCTAssertEqual(output.angular_velocity.1, 4)
        XCTAssertEqual(output.sequence, 5); XCTAssertEqual(output.received_at, 12)
    }
    func testPhysicalBindingSurvivesGenerationButRejectsWrongDeviceModelOrCapability() throws {
        var value = try profile(), calibration = S2KMotionCalibration(), device = S2KController()
        device.id = value.device; device.model = value.model; device.capabilities = UInt32(S2K_CAP_RAW_MOTION)
        for generation: UInt8 in [1, 2, 3] {
            device.connection_id.bytes.0 = generation
            XCTAssertEqual(motionProfileCalibration(&value, &device, &calibration, 136), Int32(S2K_OK))
        }
        calibration.version = 42
        device.id.bytes.0 ^= 1
        XCTAssertEqual(motionProfileCalibration(&value, &device, &calibration, 136), Int32(S2K_INVALID_ARGUMENT))
        device.id = value.device; device.model = UInt32(S2K_GAMECUBE)
        XCTAssertEqual(motionProfileCalibration(&value, &device, &calibration, 136), Int32(S2K_INVALID_ARGUMENT))
        device.model = value.model; device.capabilities = 0
        XCTAssertEqual(motionProfileCalibration(&value, &device, &calibration, 136), Int32(S2K_UNSUPPORTED_OPERATION))
        XCTAssertEqual(calibration.version, 42)
    }
    func testDecodeErrorsLeaveAllOutputBytesUnchanged() throws {
        var value = try profile()
        let before = withUnsafeBytes(of: value) { Array($0) }
        let data = try encoded()
        data.withUnsafeBytes { bytes in
            let pointer = bytes.bindMemory(to: UInt8.self).baseAddress
            XCTAssertEqual(decodeMotionProfile(nil, 1, &value, 256), Int32(S2K_INVALID_ARGUMENT))
            XCTAssertEqual(decodeMotionProfile(pointer, 0, &value, 256), Int32(S2K_INVALID_ARGUMENT))
            // Oversized input is rejected before dereferencing even a small caller buffer.
            XCTAssertEqual(decodeMotionProfile(pointer, 4097, &value, 256), Int32(S2K_INVALID_ARGUMENT))
            XCTAssertEqual(decodeMotionProfile(pointer, UInt32(bytes.count), &value, 255), Int32(S2K_ABI_MISMATCH))
            XCTAssertEqual(decodeMotionProfile(pointer, 1, &value, 256), Int32(S2K_INVALID_ARGUMENT))
            XCTAssertEqual(decodeMotionProfile(pointer, UInt32(bytes.count), nil, 256), Int32(S2K_INVALID_ARGUMENT))
        }
        XCTAssertEqual(withUnsafeBytes(of: value) { Array($0) }, before)
    }
    func testAllCStructFieldsAreValidatedRatherThanTrustingFileOrigin() throws {
        let valid = try profile()
        let defects: [(inout S2KMotionProfile) -> Void] = [
            { $0.configuration = 2 }, { $0.feature_flags = 0x27 }, { $0.model = 0xffff2069 },
            { $0.reserved = 1 }, { $0.reserved2 = 1 }, { $0.holding_axes = (-1, 2, 3) },
            { $0.holding_axes = (1, 1, 3) }, { $0.holding_axes.0 = .min },
            { $0.calibration.acceleration.units_per_count.0 = .nan },
            { $0.calibration.angular_velocity.offset.1 = .infinity },
            { $0.calibration.angular_velocity.reserved = 1 },
            { $0.orientation.0 = 0 }, { $0.orientation.63 = 1 }
        ]
        for defect in defects {
            var value = valid, output = S2KMotionCalibration(); output.version = 42; defect(&value)
            XCTAssertEqual(motionProfileCalibration(&value, nil, &output, 136), Int32(S2K_INVALID_ARGUMENT))
            XCTAssertEqual(output.version, 42)
        }
    }
    func testProfileAndNestedABIVersionsAndSizes() throws {
        let valid = try profile()
        let defects: [(inout S2KMotionProfile) -> Void] = [
            { $0.version = 2 }, { $0.struct_size = 0 },
            { $0.calibration.version = 2 }, { $0.calibration.struct_size = 0 }
        ]
        for defect in defects {
            var value = valid, output = S2KMotionCalibration(); output.version = 42; defect(&value)
            XCTAssertEqual(motionProfileCalibration(&value, nil, &output, 136), Int32(S2K_ABI_MISMATCH))
            XCTAssertEqual(output.version, 42)
        }
        var value = valid, output = S2KMotionCalibration(); output.version = 42
        XCTAssertEqual(motionProfileCalibration(nil, nil, &output, 136), Int32(S2K_INVALID_ARGUMENT))
        XCTAssertEqual(motionProfileCalibration(&value, nil, nil, 136), Int32(S2K_INVALID_ARGUMENT))
        XCTAssertEqual(motionProfileCalibration(&value, nil, &output, 135), Int32(S2K_ABI_MISMATCH))
        XCTAssertEqual(output.version, 42)
    }
    func testClockIsTheReportReceiveClockAndThreadSafe() {
        let before = ProcessInfo.processInfo.systemUptime, value = monotonicTime(), after = ProcessInfo.processInfo.systemUptime
        XCTAssertTrue(value.isFinite); XCTAssertGreaterThanOrEqual(value, before); XCTAssertLessThanOrEqual(value, after)
        DispatchQueue.concurrentPerform(iterations: 1000) { _ in XCTAssertTrue(monotonicTime().isFinite) }
    }
}
