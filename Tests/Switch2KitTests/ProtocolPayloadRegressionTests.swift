import Foundation
import XCTest
@testable import Switch2Kit

// Direct helper coverage migrated from the standalone Swift 5 protocol runner.
// Full report/trigger/framing coverage remains in ProtocolDecodingTests.
final class ProtocolPayloadRegressionTests: XCTestCase {
    func testManufacturerPayloadForEveryModelAndPairingState() throws {
        for model in Switch2.Model.allCases {
            var data = Data(repeating: 0, count: 16)
            data[3] = 0x7e; data[4] = 0x05
            data[5] = UInt8(truncatingIfNeeded: model.rawValue)
            data[6] = UInt8(truncatingIfNeeded: model.rawValue >> 8)
            let advertisement = try XCTUnwrap(Switch2.parseAdvertisement(manufacturerData: data))
            XCTAssertEqual(advertisement.model, model)
            XCTAssertTrue(advertisement.isPairing)
            data[10] = 1
            XCTAssertFalse(try XCTUnwrap(Switch2.parseAdvertisement(manufacturerData: data)).isPairing)
        }
        XCTAssertNil(Switch2.parseAdvertisement(manufacturerData: Data(repeating: 0, count: 15)))
    }

    func testLegacyModelHelpersAndPackedStickBytes() {
        XCTAssertTrue(Switch2.Model.nsoGameCube.hasAnalogTriggers)
        XCTAssertFalse(Switch2.Model.nsoGameCube.hasHDRumble)
        XCTAssertTrue(Switch2.Model.proController2.hasHDRumble)
        XCTAssertFalse(Switch2.Model.joyCon2Right.hasSecondStick)
        let stick = Switch2.stickXY(Data([0xff, 0x0f, 0x80]), 0)
        XCTAssertEqual(stick.0, 4095)
        XCTAssertEqual(stick.1, 2048)
    }
}
