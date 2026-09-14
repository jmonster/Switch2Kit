import XCTest
import Switch2Kit

final class MotionProfileTests: XCTestCase {
    private func profile(_ model: Switch2ControllerModel = .proController2,
                         holding: [Switch2MotionAxis] = [.positiveX, .positiveY, .positiveZ]) throws -> Switch2MotionProfile {
        // Synthetic coefficients exercise the format and mathematics, not a measured controller profile.
        let accel = try Switch2SensorCalibration(offset: .init(x: 10, y: -20, z: 30),
            unitsPerCount: .init(x: 0.01, y: 0.02, z: 0.03), xAxis: .negativeY, yAxis: .positiveX, zAxis: .positiveZ)
        let gyro = try Switch2SensorCalibration(offset: .init(x: 4, y: 5, z: 6),
            unitsPerCount: .init(x: 0.001, y: 0.002, z: 0.003), xAxis: .positiveZ, yAxis: .negativeX, zAxis: .positiveY)
        return try .init(device: .init(rawValue: UUID(uuidString: "01234567-89ab-cdef-0123-456789abcdef")!),
            model: model, orientationName: "two-handed-upright", holdingAxes: holding,
            calibration: .init(acceleration: accel, angularVelocity: gyro))
    }
    func testAllModelsRoundTripAndConfigurationBinding() throws {
        for model in Switch2ControllerModel.allCases {
            let value = try profile(model)
            XCTAssertEqual(try Switch2MotionProfile(encoded: value.encoded()), value)
            XCTAssertLessThan(value.encoded().count, Switch2MotionProfile.maximumEncodedSize)
            let flags: UInt8 = model == .joyCon2Left || model == .joyCon2Right ? 0xb7 : 0xa7
            XCTAssertEqual(value.featureFlags, flags)
            let text = String(decoding: value.encoded(), as: UTF8.self)
            XCTAssertThrowsError(try Switch2MotionProfile(encoded: Data(text.replacingOccurrences(of:
                "0x\(String(flags, radix: 16))", with: "0x27").utf8)))
        }
    }
    func testHoldingRotationComposesOnceAndPreservesNativeBiasGain() throws {
        let value = try profile(holding: [.negativeY, .positiveX, .positiveZ])
        let raw = Switch2Motion(accelerationRaw: .init(x: 110, y: 80, z: 130),
            angularVelocityRaw: .init(x: 1004, y: 1005, z: 1006), magneticFieldRaw: .init(), temperatureCelsius: 20)
        let result = value.bodyCalibration.apply(to: raw)
        // Reference accel=(-2,1,3), gyro=(3,-1,2); proper holding rotation maps (x,y,z)->(-y,x,z).
        XCTAssertEqual(result.acceleration, .init(x: -1, y: -2, z: 3))
        XCTAssertEqual(result.angularVelocity, .init(x: 1, y: 3, z: 2))
        XCTAssertEqual(value.bodyCalibration.acceleration.offset, value.calibration.acceleration.offset)
        XCTAssertEqual(value.bodyCalibration.angularVelocity.unitsPerCount, value.calibration.angularVelocity.unitsPerCount)
    }
    func testOnly24ProperHoldingRotationsAreAccepted() throws {
        var accepted = 0, rejected = 0
        for x in Switch2MotionAxis.allCases { for y in Switch2MotionAxis.allCases { for z in Switch2MotionAxis.allCases {
            guard Set([abs(x.rawValue), abs(y.rawValue), abs(z.rawValue)]).count == 3 else { continue }
            do { _ = try profile(holding: [x, y, z]); accepted += 1 }
            catch { rejected += 1 }
        } } }
        XCTAssertEqual(accepted, 24); XCTAssertEqual(rejected, 24)
        XCTAssertThrowsError(try profile(holding: [.positiveX, .positiveX, .positiveZ]))
        XCTAssertThrowsError(try profile(holding: [.positiveX, .positiveY]))
    }
    func testMalformedDimensionsUnitsNumericAndDuplicateRecordsFailClosed() throws {
        let valid = String(decoding: try profile().encoded(), as: UTF8.self)
        let changes = [
            ("Switch2KitMotionProfile 1", "Switch2KitMotionProfile 2"),
            ("raw-range -32768 32767", "raw-range -2048 2047"),
            ("model 0x2069", "model 0x2009"),
            ("bt-report-v1", "bt-report-v2"),
            ("acceleration m/s2", "acceleration g"),
            ("angular-velocity rad/s", "angular-velocity deg/s"),
            ("bias 10.0 -20.0 30.0", "bias 10 -20"),
            ("bias 10.0 -20.0 30.0", "bias 10 -20 30 40"),
            ("bias 10.0 -20.0 30.0", "bias nan -20 30"),
            ("bias 10.0 -20.0 30.0", "bias 32768 -20 30"),
            ("gain 0.01 0.02 0.03", "gain 0.01 -0.02 0.03"),
            ("gain 0.01 0.02 0.03", "gain inf 0.02 0.03"),
            ("axes -2 1 3", "axes -2 2 3"),
            ("axes -2 1 3", "axes -2147483648 1 3"),
            ("range-at-32768 327.68 655.36 983.04", "range-at-32768 1 2 3"),
            ("two-handed-upright 1 2 3", "two-handed-upright -1 2 3")
        ]
        for (before, after) in changes {
            XCTAssertTrue(valid.contains(before), before)
            XCTAssertThrowsError(try Switch2MotionProfile(encoded: Data(valid.replacingOccurrences(of: before, with: after).utf8)), after)
        }
        for suffix in ["device 00000000-0000-0000-0000-000000000000\n", "unknown-field 1\n", "\u{0}", "☃"] {
            XCTAssertThrowsError(try Switch2MotionProfile(encoded: Data((valid + suffix).utf8)))
        }
    }
    func testEmptyOversizedAndInvalidEncodingAreRejected() {
        for data in [Data(), Data(repeating: 32, count: 4097), Data([0xff, 0xfe]), Data([0])] {
            XCTAssertThrowsError(try Switch2MotionProfile(encoded: data))
        }
    }
    func testLabelsAndGainAdmissionBounds() throws {
        let value = try profile()
        for name in ["", String(repeating: "a", count: 64), "../profile", "upright with spaces", "Uppercase", "\n"] {
            XCTAssertThrowsError(try Switch2MotionProfile(device: value.device, model: value.model,
                orientationName: name, calibration: value.calibration))
        }
        for gain in [1e-100, 1.0, 1e100] {
            let bad = try Switch2SensorCalibration(offset: .init(x: 0, y: 0, z: 0), unitsPerCount: .init(x: gain, y: gain, z: gain))
            XCTAssertThrowsError(try Switch2MotionProfile(device: value.device, model: value.model,
                orientationName: "upright", calibration: .init(acceleration: bad, angularVelocity: value.calibration.angularVelocity)))
        }
    }
    func testWhitespaceAndCRLFRoundTrip() throws {
        let profile = try profile()
        let text = String(decoding: profile.encoded(), as: UTF8.self).replacingOccurrences(of: " ", with: "\t").replacingOccurrences(of: "\n", with: "\r\n")
        XCTAssertEqual(try Switch2MotionProfile(encoded: Data(text.utf8)), profile)
    }
    func testConcurrentDecodingHasNoMutableCacheOrPersistence() throws {
        let profile = try profile(), data = profile.encoded()
        DispatchQueue.concurrentPerform(iterations: 1000) { _ in
            XCTAssertEqual(try? Switch2MotionProfile(encoded: data), profile)
        }
    }
}
