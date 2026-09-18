import Foundation
import XCTest
@testable import Switch2Kit

final class ControllerClockTests: XCTestCase {
    func testReceiveClockIsFiniteMonotonicAndHighResolution() {
        var previous = ControllerClock.now
        XCTAssertTrue(previous.isFinite)
        XCTAssertGreaterThan(previous, 0)
        var distinct = 0
        for _ in 0..<10_000 {
            let current = ControllerClock.now
            XCTAssertGreaterThanOrEqual(current, previous)
            if current > previous { distinct += 1 }
            previous = current
        }
        // Do not require every call to advance, or depend on sleep scheduling.
        // A millisecond/system-tick clock cannot timestamp high-rate reports.
        XCTAssertGreaterThan(distinct, 100)
    }
}
