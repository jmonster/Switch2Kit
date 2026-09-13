import XCTest
import Switch2Kit

final class MotionCalibrationTests: XCTestCase {
    private let zero = Switch2Vector3(x: 0, y: 0, z: 0)
    private let one = Switch2Vector3(x: 1, y: 1, z: 1)

    func testBiasGainAndSignedAxisOrder() throws {
        let sensor = try Switch2SensorCalibration(offset: .init(x: 10, y: -20, z: 30),
                                                  unitsPerCount: .init(x: 0.5, y: 2, z: 0.25),
                                                  xAxis: .negativeY, yAxis: .positiveZ, zAxis: .positiveX)
        XCTAssertEqual(sensor.apply(to: .init(x: 14, y: -17, z: 26)), .init(x: -6, y: -1, z: 2))
    }

    func testEverySignedAxisPermutation() throws {
        for x in Switch2MotionAxis.allCases {
            for y in Switch2MotionAxis.allCases where abs(y.rawValue) != abs(x.rawValue) {
                for z in Switch2MotionAxis.allCases where Set([x, y, z].map { abs($0.rawValue) }).count == 3 {
                    let sensor = try Switch2SensorCalibration(offset: zero, unitsPerCount: one,
                                                              xAxis: x, yAxis: y, zAxis: z)
                    let expected: (Switch2MotionAxis) -> Double = { axis in
                        let value = [2.0, 3.0, 5.0][Int(abs(axis.rawValue)) - 1]
                        return axis.rawValue < 0 ? -value : value
                    }
                    XCTAssertEqual(sensor.apply(to: .init(x: 2, y: 3, z: 5)),
                                   .init(x: expected(x), y: expected(y), z: expected(z)))
                }
            }
        }
    }

    func testReferenceCalibrationRetainsGravityAndIndependentGyroBias() throws {
        // Synthetic six-position means with independent bias/gain on each native axis.
        let accel = try Switch2SensorCalibration(negativeReference: .init(x: -990, y: -1980, z: -3030),
                                                positiveReference: .init(x: 1010, y: 2020, z: 2970), magnitude: 9.80665)
        XCTAssertEqual(accel.offset, .init(x: 10, y: 20, z: -30))
        let gyro = try Switch2SensorCalibration(offset: .init(x: 5, y: 6, z: 7), unitsPerCount: .init(x: 0.01, y: 0.02, z: 0.03))
        let profile = Switch2MotionCalibration(acceleration: accel, angularVelocity: gyro)
        let raw = Switch2Motion(accelerationRaw: .init(x: 10, y: 20, z: 2970),
                                angularVelocityRaw: .init(x: 5, y: 6, z: 7), magneticFieldRaw: .init(), temperatureCelsius: 25)
        let result = profile.apply(to: raw)
        XCTAssertEqual(result.acceleration.x, 0)
        XCTAssertEqual(result.acceleration.y, 0)
        XCTAssertEqual(result.acceleration.z, 9.80665, accuracy: 1e-12)
        XCTAssertEqual(result.angularVelocity, zero)
        XCTAssertEqual(raw.accelerationRaw.z, 2970)
    }

    func testKnownRateReferences() throws {
        let sensor = try Switch2SensorCalibration(negativeReference: .init(x: -100, y: -200, z: -400),
                                                  positiveReference: .init(x: 100, y: 200, z: 400), magnitude: .pi)
        let result = sensor.apply(to: .init(x: 100, y: -200, z: 0))
        XCTAssertEqual(result.x, .pi, accuracy: 1e-12)
        XCTAssertEqual(result.y, -.pi, accuracy: 1e-12)
        XCTAssertEqual(result.z, 0)
    }

    func testInvalidProfilesThrowInsteadOfClamping() throws {
        for bad in [Double.nan, .infinity, -.infinity, 32768, -32769] {
            XCTAssertThrowsError(try Switch2SensorCalibration(offset: .init(x: bad, y: 0, z: 0), unitsPerCount: one))
        }
        for bad in [Double.nan, .infinity, -.infinity, 0, -1, .greatestFiniteMagnitude] {
            XCTAssertThrowsError(try Switch2SensorCalibration(offset: zero, unitsPerCount: .init(x: 1, y: bad, z: 1)))
        }
        XCTAssertThrowsError(try Switch2SensorCalibration(offset: zero, unitsPerCount: one, xAxis: .positiveX, yAxis: .negativeX))
    }

    func testDegenerateReferencesAreRejected() throws {
        for magnitude in [Double.nan, .infinity, 0, -1] {
            XCTAssertThrowsError(try Switch2SensorCalibration(negativeReference: zero, positiveReference: one, magnitude: magnitude))
        }
        for positive in [Switch2Vector3(x: 0, y: 1, z: 1), .init(x: -1, y: 1, z: 1), .init(x: .nan, y: 1, z: 1), .init(x: 32768, y: 1, z: 1)] {
            XCTAssertThrowsError(try Switch2SensorCalibration(negativeReference: zero, positiveReference: positive, magnitude: 1))
        }
        XCTAssertThrowsError(try Switch2SensorCalibration(negativeReference: zero,
                                                          positiveReference: .init(x: .leastNonzeroMagnitude, y: 1, z: 1), magnitude: 1))
    }

    func testAllRawExtremaStayFiniteAtMaximumAcceptedGain() throws {
        let gain = Double.greatestFiniteMagnitude / 65536
        for offset in [-32768.0, 32767.0] {
            let sensor = try Switch2SensorCalibration(offset: .init(x: offset, y: offset, z: offset),
                                                      unitsPerCount: .init(x: gain, y: gain, z: gain))
            for raw in [Int16.min, Int16.max] {
                let result = sensor.apply(to: .init(x: raw, y: raw, z: raw))
                XCTAssertTrue(result.x.isFinite && result.y.isFinite && result.z.isFinite)
            }
        }
    }

    func testConcurrentStatelessUse() throws {
        let sensor = try Switch2SensorCalibration(offset: zero, unitsPerCount: one)
        DispatchQueue.concurrentPerform(iterations: 10_000) { i in
            let value = sensor.apply(to: .init(x: Int16(i), y: -Int16(i), z: 0))
            XCTAssertEqual(value, .init(x: Double(i), y: -Double(i), z: 0))
        }
    }
}
