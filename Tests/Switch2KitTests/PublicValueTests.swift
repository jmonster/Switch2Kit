import XCTest
@testable import Switch2Kit

final class PublicValueTests: XCTestCase {
    func testKnownModelsAndCapabilities() {
        XCTAssertEqual(Switch2ControllerModel.allCases.count, 4)
        for model in Switch2ControllerModel.allCases {
            XCTAssertTrue(model.capabilities.contains(.buttons))
            XCTAssertEqual(model.capabilities.contains(.analogTriggers), model == .nsoGameCube)
            XCTAssertTrue(model.capabilities.contains(.rumble))
            XCTAssertEqual(model.capabilities.contains(.continuousRumble), model != .nsoGameCube)
            XCTAssertEqual(model.capabilities.contains(.rumblePresets), model == .nsoGameCube)
        }
    }
    func testFiniteStickAndTriggerBounds() {
        XCTAssertEqual(Switch2Stick(x: .nan, y: 2), Switch2Stick(x: 0, y: 1))
        XCTAssertEqual(Switch2Trigger(isPressed: true, travel: -2).travel, 0)
        XCTAssertNil(Switch2Trigger(travel: .infinity).travel)
        XCTAssertNil(Switch2Battery(millivolts: 0).estimatedCharge)
        XCTAssertEqual(Switch2Battery(millivolts: 4150).estimatedCharge, 1)
    }
}
