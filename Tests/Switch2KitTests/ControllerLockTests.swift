import Foundation
import XCTest
@testable import Switch2Kit

final class ControllerLockTests: XCTestCase {
    func testContendedUpdatesAreAtomic() {
        struct State: Sendable { var count = 0; var sum = 0; var inconsistent = false }
        let state = ControllerLock(State())
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            for _ in 0..<10_000 {
                state.withLock {
                    if $0.sum != $0.count * 2 { $0.inconsistent = true }
                    $0.count += 1
                    $0.sum += 2
                }
            }
        }
        let result = state.withLock { $0 }
        XCTAssertEqual(result.count, 80_000)
        XCTAssertEqual(result.sum, 160_000)
        XCTAssertFalse(result.inconsistent)
    }

    func testThrowingClosureReleasesLockAndPreservesState() throws {
        enum Failure: Error { case expected }
        let state = ControllerLock(0)
        XCTAssertThrowsError(try state.withLock { value -> Int in
            value = 42
            throw Failure.expected
        })
        XCTAssertEqual(state.withLock { $0 }, 42)
        state.withLock { $0 += 1 }
        XCTAssertEqual(state.withLock { $0 }, 43)
    }
}
