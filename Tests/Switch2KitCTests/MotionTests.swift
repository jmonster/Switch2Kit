import XCTest
import Switch2KitC
import Switch2KitCABI

final class MotionTests: XCTestCase {
    private func profile() -> S2KMotionCalibration {
        var p = S2KMotionCalibration()
        p.version = UInt32(S2K_MOTION_CALIBRATION_VERSION)
        p.struct_size = UInt32(MemoryLayout<S2KMotionCalibration>.size)
        p.acceleration.units_per_count = (0.5, 2, 0.25)
        p.acceleration.offset = (10, -20, 30)
        p.acceleration.axes = (-2, 3, 1)
        p.angular_velocity.units_per_count = (0.1, 0.2, 0.3)
        p.angular_velocity.axes = (1, 2, 3)
        return p
    }
    private func input() -> S2KState {
        var s = S2KState()
        s.present = UInt32(S2K_HAS_MOTION); s.received_at = 123.5; s.sequence = .max
        s.accel = (14, -17, 26); s.gyro = (10, -5, 0)
        return s
    }

    func testLayoutAndValueConversionPreserveTimestampAndSequence() {
        XCTAssertEqual(MemoryLayout<S2KSensorCalibration>.size, 64)
        XCTAssertEqual(MemoryLayout<S2KMotionCalibration>.size, 136)
        XCTAssertEqual(MemoryLayout<S2KCalibratedMotion>.size, 64)
        var s = input(), p = profile(), result = S2KCalibratedMotion()
        XCTAssertEqual(convertMotion(&s, &p, &result, 64), Int32(S2K_OK))
        XCTAssertEqual(result.acceleration.0, -6)
        XCTAssertEqual(result.acceleration.1, -1)
        XCTAssertEqual(result.acceleration.2, 2)
        XCTAssertEqual(result.angular_velocity.0, 1)
        XCTAssertEqual(result.angular_velocity.1, -1)
        XCTAssertEqual(result.angular_velocity.2, 0)
        XCTAssertEqual(result.received_at, s.received_at)
        XCTAssertEqual(result.sequence, s.sequence)
    }

    func testMissingMotionDoesNotInventAZeroSample() {
        var s = input(), p = profile(), result = S2KCalibratedMotion()
        result.sequence = 42; s.present = 0
        XCTAssertEqual(convertMotion(&s, &p, &result, 64), Int32(S2K_NOT_READY))
        XCTAssertEqual(result.sequence, 42)
    }

    func testVersionSizesAndNullPointersAreRejectedWithoutWriting() {
        var s = input(), p = profile(), result = S2KCalibratedMotion()
        result.sequence = 42
        XCTAssertEqual(convertMotion(nil, &p, &result, 64), Int32(S2K_INVALID_ARGUMENT))
        XCTAssertEqual(convertMotion(&s, nil, &result, 64), Int32(S2K_INVALID_ARGUMENT))
        XCTAssertEqual(convertMotion(&s, &p, nil, 64), Int32(S2K_INVALID_ARGUMENT))
        XCTAssertEqual(convertMotion(&s, &p, &result, 63), Int32(S2K_ABI_MISMATCH))
        p.version = 2
        XCTAssertEqual(convertMotion(&s, &p, &result, 64), Int32(S2K_ABI_MISMATCH))
        p = profile(); p.struct_size -= 1
        XCTAssertEqual(convertMotion(&s, &p, &result, 64), Int32(S2K_ABI_MISMATCH))
        XCTAssertEqual(result.sequence, 42)
    }

    func testInvalidProfilesAndReceiveTimesAreRejectedWithoutWriting() {
        var s = input(), result = S2KCalibratedMotion()
        result.sequence = 42
        let defects: [(inout S2KMotionCalibration) -> Void] = [
            { $0.acceleration.axes = (1, -1, 3) }, { $0.acceleration.axes.0 = 0 },
            { $0.angular_velocity.axes.1 = 4 }, { $0.angular_velocity.axes.2 = .min },
            { $0.acceleration.units_per_count.0 = .nan }, { $0.angular_velocity.units_per_count.2 = .infinity },
            { $0.acceleration.units_per_count.1 = 0 }, { $0.acceleration.offset.2 = 32768 },
            { $0.acceleration.reserved = 1 }, { $0.angular_velocity.reserved = 1 }
        ]
        for defect in defects {
            var p = profile(); defect(&p)
            XCTAssertEqual(convertMotion(&s, &p, &result, 64), Int32(S2K_INVALID_ARGUMENT))
            XCTAssertEqual(result.sequence, 42)
        }
        var p = profile()
        for time in [Double.nan, .infinity, -.infinity, -1] {
            s.received_at = time
            XCTAssertEqual(convertMotion(&s, &p, &result, 64), Int32(S2K_INVALID_ARGUMENT))
            XCTAssertEqual(result.sequence, 42)
        }
    }
}
