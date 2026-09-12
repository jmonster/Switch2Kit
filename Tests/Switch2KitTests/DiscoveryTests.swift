import Foundation
import XCTest
@testable import Switch2Kit

final class DiscoveryTests: XCTestCase {
    func testOnDemandWindowAndExplicitAutomaticMode() {
        let queue = DispatchQueue(label: "test.discovery")
        queue.sync {
            let policy = ControllerDiscoveryPolicy(queue: queue, mode: .onDemand, changed: {})
            XCTAssertFalse(policy.shouldScan(readyIDs: [], now: 0))
            for seconds in [Double.nan, .infinity, 0, -1, 301] { XCTAssertFalse(policy.openWindow(seconds: seconds, now: 0)) }
            XCTAssertTrue(policy.openWindow(seconds: 60, now: 10))
            XCTAssertTrue(policy.shouldScan(readyIDs: [], now: 69))
            XCTAssertFalse(policy.shouldScan(readyIDs: [], now: 70))
            XCTAssertNil(policy.deadline)
            policy.configure(mode: .automatic, remembered: [])
            XCTAssertTrue(policy.shouldScan(readyIDs: [], now: 100))
            XCTAssertTrue(policy.openWindow(seconds: 1, now: 100))
            XCTAssertNil(policy.deadline)
            XCTAssertTrue(policy.shouldScan(readyIDs: [], now: 1000))
            policy.cancelWindow()
        }
    }
    func testQuietDiscoveryWaitsForAllPhysicalControllersAndRecoversMissingOnes() {
        let queue = DispatchQueue(label: "test.discovery.quiet")
        queue.sync {
            let a = UUID(), b = UUID()
            let policy = ControllerDiscoveryPolicy(queue: queue, mode: .quietWhenReady, capacity: 2, changed: {})
            XCTAssertTrue(policy.shouldScan(readyIDs: [], now: 0))
            XCTAssertTrue(policy.shouldScan(readyIDs: [a], now: 1))
            XCTAssertTrue(policy.shouldScan(readyIDs: [a, b], now: 2))
            XCTAssertFalse(policy.shouldScan(readyIDs: [a, b], now: 60))
            XCTAssertTrue(policy.shouldScan(readyIDs: [a], now: 61))
            policy.forget(b)
            XCTAssertFalse(policy.shouldScan(readyIDs: [a], now: 62))
            XCTAssertTrue(policy.openWindow(seconds: 2, now: 63))
            XCTAssertTrue(policy.shouldScan(readyIDs: [a], now: 64))
            policy.useConnected([a])
            XCTAssertNil(policy.deadline)
            XCTAssertFalse(policy.shouldScan(readyIDs: [a], now: 64))
            policy.cancelWindow()
        }
    }
}
