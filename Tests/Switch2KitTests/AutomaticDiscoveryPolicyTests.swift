import Foundation
import XCTest
@testable import Switch2Kit

final class AutomaticDiscoveryPolicyTests: XCTestCase {
    func testAutomaticDiscoverySurvivesLongAbsenceWithoutRenewal() {
        let queue = DispatchQueue(label: "test.automatic-discovery")
        queue.sync {
            let policy = ControllerDiscoveryPolicy(queue: queue, mode: .onDemand) {}
            let id = UUID()
            XCTAssertFalse(policy.shouldScan(readyIDs: [], now: 0))
            policy.configure(mode: .automatic, remembered: [])
            XCTAssertTrue(policy.shouldScan(readyIDs: [], now: 0))
            XCTAssertTrue(policy.shouldScan(readyIDs: [id], now: 60))
            // Controller powers off while the emulator is paused for a day.
            XCTAssertTrue(policy.shouldScan(readyIDs: [], now: 86_400))
            XCTAssertNil(policy.deadline)
            XCTAssertTrue(policy.shouldScan(readyIDs: [id], now: 86_401))
            policy.cancelWindow()
            XCTAssertTrue(policy.shouldScan(readyIDs: [], now: 172_800))
            policy.configure(mode: .onDemand, remembered: [])
            XCTAssertFalse(policy.shouldScan(readyIDs: [id], now: 172_801))
            XCTAssertTrue(policy.openWindow(seconds: 60, now: 172_801))
            XCTAssertTrue(policy.shouldScan(readyIDs: [], now: 172_860))
            XCTAssertFalse(policy.shouldScan(readyIDs: [], now: 172_861))
        }
    }
}
