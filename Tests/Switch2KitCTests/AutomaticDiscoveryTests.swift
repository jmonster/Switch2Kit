import Foundation
import XCTest
import Switch2Kit
import Switch2KitCABI
@testable import Switch2KitC

final class AutomaticDiscoveryTests: XCTestCase {
    func testValidationDefaultAndRadioFreeConfiguration() throws {
        let source = TestSource(), context = try CContext(source: source, capacity: 16)
        let handle = retainedHandle(context)
        defer { destroyContext(handle) }
        XCTAssertEqual(s2k_set_automatic_discovery(nil, 1), 1)
        XCTAssertEqual(s2k_set_automatic_discovery(handle, 2), 1)
        XCTAssertEqual(s2k_set_automatic_discovery(handle, UInt32.max), 1)
        XCTAssertFalse(source.state.withLock { $0.automaticDiscovery })
        XCTAssertTrue(source.state.withLock { $0.calls.isEmpty })
        XCTAssertEqual(s2k_set_automatic_discovery(handle, 0), 0)
        XCTAssertEqual(s2k_set_automatic_discovery(handle, 1), 0)
        XCTAssertEqual(s2k_set_automatic_discovery(handle, 1), 0)
        XCTAssertEqual(source.state.withLock { $0.calls }, ["automatic"])
        XCTAssertFalse(source.state.withLock { $0.running })
        XCTAssertFalse(context.read(maximum: 0).snapshot.isRunning)
    }

    func testTogglePreservesReadySessionAndInputReader() throws {
        let source = TestSource(), context = try CContext(source: source, capacity: 16)
        let handle = retainedHandle(context)
        defer { destroyContext(handle) }
        XCTAssertEqual(startContext(handle), 0)
        source.emit(pressed: true)
        let before = context.read(maximum: 16).snapshot.controllers[0]
        source.emit(sequence: 2, pressed: false)
        XCTAssertEqual(s2k_set_automatic_discovery(handle, 1), 0)
        XCTAssertEqual(s2k_set_automatic_discovery(handle, 0), 0)
        let batch = context.read(maximum: 16)
        XCTAssertFalse(batch.resync)
        XCTAssertEqual(batch.events.count, 1)
        XCTAssertEqual(batch.snapshot.controllers[0].connectionID, before.connectionID)
        XCTAssertEqual(batch.snapshot.controllers[0].state.sequence, 2)
        XCTAssertEqual(source.state.withLock { $0.calls }, ["automatic", "on-demand"])
    }

    func testStopIsAuthoritativeAndChoiceSurvivesRestart() throws {
        let source = TestSource(), context = try CContext(source: source, capacity: 16)
        let handle = retainedHandle(context)
        defer { destroyContext(handle) }
        XCTAssertEqual(s2k_set_automatic_discovery(handle, 1), 0)
        XCTAssertEqual(startContext(handle), 0)
        XCTAssertEqual(stopContext(handle), 0)
        XCTAssertEqual(s2k_set_automatic_discovery(handle, 0), 5)
        XCTAssertEqual(startContext(handle), 5)
        XCTAssertTrue(source.state.withLock { $0.automaticDiscovery })
        source.finishStop()
        XCTAssertEqual(s2k_set_automatic_discovery(handle, 1), 0)
        XCTAssertFalse(context.read(maximum: 0).snapshot.isRunning)
        XCTAssertEqual(startContext(handle), 0)
        XCTAssertTrue(source.state.withLock { $0.automaticDiscovery })
        XCTAssertEqual(stopContext(handle), 0)
        source.finishStop()
        XCTAssertEqual(s2k_set_automatic_discovery(handle, 0), 0)
        XCTAssertFalse(source.state.withLock { $0.running })
        context.close()
        XCTAssertEqual(s2k_set_automatic_discovery(handle, 1), 1)
    }

    func testConcurrentConfigurationCannotRestartStoppedSource() throws {
        let source = TestSource(), context = try CContext(source: source, capacity: 16)
        XCTAssertEqual(context.start(), 0)
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            if index == 100 {
                XCTAssertEqual(context.stop(), 0)
            } else {
                let result = context.setAutomaticDiscovery(index % 2 == 0)
                XCTAssertTrue(result == 0 || result == 5)
            }
        }
        XCTAssertFalse(source.state.withLock { $0.running })
        XCTAssertTrue(context.read(maximum: 0).stopping)
        source.finishStop()
        XCTAssertEqual(context.setAutomaticDiscovery(true), 0)
        XCTAssertFalse(source.state.withLock { $0.running })
    }
}
