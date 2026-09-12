import Foundation
import XCTest
@testable import Switch2Kit

// All fixtures are synthetic. Hardware behavior is deliberately not inferred here.
final class ProtocolDecodingTests: XCTestCase {
    private func packed(_ x: UInt16, _ y: UInt16) -> Data {
        let value = UInt32(x) | UInt32(y) << 12
        return Data([UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value >> 16)])
    }
    private func put(_ value: UInt16, into data: inout Data, at offset: Int) {
        data[offset] = UInt8(truncatingIfNeeded: value); data[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }
    func testFullAdvertisementAdmissionForEverySupportedModel() throws {
        for model in Switch2ControllerModel.allCases {
            var data = Data(repeating: 0, count: 18)
            put(0x0553, into: &data, at: 0); put(0x057e, into: &data, at: 5); put(model.rawValue, into: &data, at: 7)
            let advert = try XCTUnwrap(Switch2.recognizeAdvertisement(data))
            XCTAssertEqual(advert.model, model); XCTAssertTrue(advert.isPairing)
            data[12] = 1
            XCTAssertFalse(try XCTUnwrap(Switch2.recognizeAdvertisement(data)).isPairing)
            XCTAssertEqual(Switch2.recognizeAdvertisement((Data([0xff]) + data).dropFirst())?.model, model)
            var bad = data; put(0x1234, into: &bad, at: 0); XCTAssertNil(Switch2.recognizeAdvertisement(bad))
            bad = data; put(0x1234, into: &bad, at: 5); XCTAssertNil(Switch2.recognizeAdvertisement(bad))
            bad = data; put(0xffff, into: &bad, at: 7); XCTAssertNil(Switch2.recognizeAdvertisement(bad))
            for length in 0..<18 { XCTAssertNil(Switch2.recognizeAdvertisement(Data(data.prefix(length)))) }
        }
    }
    func testAllTriggerTravelAndSlicedReportOffsets() throws {
        for length in 0..<60 { XCTAssertNil(Switch2.InputReport(data: Data(repeating: 0, count: length))) }
        for travel in UInt8.min...UInt8.max {
            var data = Data(repeating: 0, count: 63)
            data[4] = travel; data[60] = travel; data[61] = 255 - travel
            for bytes in [data, (Data([0xaa]) + data).dropFirst()] {
                let report = try XCTUnwrap(Switch2.InputReport(data: bytes))
                XCTAssertEqual(report.buttons.rawValue, UInt32(travel))
                XCTAssertEqual(report.leftTriggerRaw, travel); XCTAssertEqual(report.rightTriggerRaw, 255 - travel)
            }
        }
        let minimal = try XCTUnwrap(Switch2.InputReport(data: Data(repeating: 0, count: 60)))
        XCTAssertEqual(minimal.leftTriggerRaw, 0); XCTAssertEqual(minimal.rightTriggerRaw, 0)
    }
    func testButtonsSticksBatteryMotionAndOpticalFields() throws {
        var data = Data(repeating: 0, count: 63)
        data.replaceSubrange(0..<4, with: [0x78, 0x56, 0x34, 0x12])
        let buttons: Switch2Buttons = [.a, .b, .dpadUp, .dpadDown, .gl, .zr]
        for offset in 0..<4 { data[4 + offset] = UInt8(truncatingIfNeeded: buttons.rawValue >> (8 * offset)) }
        data.replaceSubrange(10..<13, with: packed(4095, 2048))
        data.replaceSubrange(13..<16, with: packed(0, 4095))
        put(3901, into: &data, at: 0x1f); data[0x21] = 3
        put(UInt16(bitPattern: -321), into: &data, at: 0x22)
        for (offset, value) in [(0x19, Int16.min), (0x1b, -2), (0x1d, Int16.max),
            (0x30, -11), (0x32, 22), (0x34, -33), (0x36, 44), (0x38, -55), (0x3a, 66), (0x2e, 127)] {
            put(UInt16(bitPattern: value), into: &data, at: offset)
        }
        put(65535, into: &data, at: 0x10); put(123, into: &data, at: 0x12)
        put(456, into: &data, at: 0x14); put(789, into: &data, at: 0x16)
        let report = try XCTUnwrap(Switch2.InputReport(data: data))
        XCTAssertEqual(report.timestamp, 0x12345678); XCTAssertEqual(report.buttons, buttons)
        XCTAssertEqual(report.leftStickRaw.0, 4095); XCTAssertEqual(report.leftStickRaw.1, 2048)
        XCTAssertEqual(report.rightStickRaw.0, 0); XCTAssertEqual(report.rightStickRaw.1, 4095)
        XCTAssertEqual(report.batteryMillivolts, 3901); XCTAssertEqual(report.batteryCurrent, -321); XCTAssertEqual(report.chargeState, 3)
        XCTAssertEqual([report.accel.0, report.accel.1, report.accel.2], [-11, 22, -33])
        XCTAssertEqual([report.gyro.0, report.gyro.1, report.gyro.2], [44, -55, 66])
        XCTAssertEqual([report.mag.0, report.mag.1, report.mag.2], [Int16.min, -2, Int16.max])
        XCTAssertEqual(report.temperatureRaw, 127)
        XCTAssertEqual([report.mouseX, report.mouseY, report.surfaceQuality, report.liftDistance], [65535, 123, 456, 789])
    }
    func testValidatedCalibrationAndAsymmetricRanges() throws {
        let data = packed(2000, 2100) + packed(1000, 800) + packed(900, 1100)
        let calibration = try XCTUnwrap(Switch2.StickCalibration(validatedData: data))
        XCTAssertEqual(calibration.apply((2000, 2100)).0, 0)
        XCTAssertEqual(calibration.apply((2500, 2500)).0, 0.5)
        XCTAssertEqual(calibration.apply((2500, 2500)).1, 0.5)
        XCTAssertEqual(calibration.apply((1550, 1550)).0, -0.5)
        XCTAssertEqual(calibration.apply((1550, 1550)).1, -0.5)
        XCTAssertEqual(calibration.apply((4095, 4095)).0, 1)
        XCTAssertEqual(calibration.apply((0, 0)).1, -1)
        for length in 0..<9 { XCTAssertNil(Switch2.StickCalibration(validatedData: Data(data.prefix(length)))) }
        XCTAssertNil(Switch2.StickCalibration(validatedData: Data(repeating: 0xff, count: 9)))
        XCTAssertNil(Switch2.StickCalibration(validatedData: Data(repeating: 0, count: 9)))
        XCTAssertNil(Switch2.StickCalibration(validatedData: packed(2000, 2100) + packed(0, 800) + packed(900, 1100)))
    }
    func testSnapshotAvailabilityAndDigitalClicksRemainIndependent() {
        var state = ControllerState(); state.buttons = .zr
        state.leftStick = (-0.25, 0.5); state.rightStick = (0.75, -1)
        state.leftTrigger = 128; state.rightTrigger = 0; state.batteryMillivolts = 3900
        for model in Switch2ControllerModel.allCases {
            let snapshot = state.snapshot(model: model, receivedAt: 123, sequence: 7)
            XCTAssertEqual(snapshot.leftStick != nil, model != .joyCon2Right)
            XCTAssertEqual(snapshot.rightStick != nil, model != .joyCon2Left)
            XCTAssertEqual(snapshot.leftTrigger.travel != nil, model == .nsoGameCube)
            XCTAssertFalse(snapshot.leftTrigger.isPressed); XCTAssertTrue(snapshot.rightTrigger.isPressed)
            if model == .nsoGameCube { XCTAssertEqual(snapshot.leftTrigger.travel, 128.0 / 255); XCTAssertEqual(snapshot.rightTrigger.travel, 0) }
            XCTAssertEqual(snapshot.battery.millivolts, 3900); XCTAssertEqual(snapshot.receivedAt, 123); XCTAssertEqual(snapshot.sequence, 7)
            XCTAssertNotNil(snapshot.motion)
            XCTAssertEqual(snapshot.optical != nil, model == .joyCon2Left || model == .joyCon2Right)
            XCTAssertNil(state.snapshot(model: model, receivedAt: 0, sensorProfile: .gamepad).motion)
            XCTAssertNil(state.snapshot(model: model, receivedAt: 0, sensorProfile: .gamepad).optical)
        }
    }
    func testCommandFramingMatchesRetainedProtocolBytes() {
        XCTAssertEqual(Switch2.buildCommand(0x09, 0x07, data: Data([3, 0, 0, 0])), Data([9, 0x91, 1, 7, 0, 4, 0, 0, 3, 0, 0, 0]))
        XCTAssertEqual(Switch2.memoryReadPayload(length: 4, address: 0x13000), Data([4, 0x7e, 0, 0, 0, 0x30, 1, 0]))
    }
}
