import Foundation
import XCTest
import Switch2Kit
import Switch2KitC
import Switch2KitCABI

// Exercise the SAME source compiled into libS2KSDLFixture by the native CMake tests.
// No physical radio, SDL implementation, or emulator behavior is simulated here.
final class SDLFixtureTests: XCTestCase {
    private func make() throws -> (SDLTestSource, CContext, OpaquePointer) {
        let handle = try XCTUnwrap(fixtureCreate())
        let context = Unmanaged<CContext>.fromOpaque(UnsafeRawPointer(handle)).takeUnretainedValue()
        return (context.source as! SDLTestSource, context, handle)
    }

    private func finishStop(_ source: SDLTestSource) throws {
        let completion = source.state.withLock { value in
            let completion = value.stopCompletion
            value.stopCompletion = nil
            return completion
        }
        // Complete the fixture's deferred stop outside both source and context locks.
        try XCTUnwrap(completion)()
    }

    func testAutomaticDiscoveryConfigurationIsValidatedIdempotentAndRadioFree() throws {
        let (source, context, handle) = try make()
        defer { destroyContext(handle) }
        XCTAssertFalse(source.state.withLock { $0.automaticDiscovery })
        XCTAssertEqual(s2k_set_automatic_discovery(nil, 1), 1)
        XCTAssertEqual(s2k_set_automatic_discovery(handle, 2), 1)
        XCTAssertEqual(s2k_set_automatic_discovery(handle, 0), 0)
        XCTAssertEqual(source.state.withLock { $0.discoveryConfigurationCount }, 0)
        XCTAssertEqual(s2k_set_automatic_discovery(handle, 1), 0)
        XCTAssertEqual(s2k_set_automatic_discovery(handle, 1), 0)
        XCTAssertTrue(source.state.withLock { $0.automaticDiscovery })
        XCTAssertEqual(source.state.withLock { $0.discoveryConfigurationCount }, 1)
        XCTAssertFalse(source.state.withLock { $0.running })
        XCTAssertFalse(context.read(maximum: 0).snapshot.isRunning)
        XCTAssertEqual(s2k_set_automatic_discovery(handle, 0), 0)
        XCTAssertFalse(source.state.withLock { $0.automaticDiscovery })
        XCTAssertEqual(source.state.withLock { $0.discoveryConfigurationCount }, 2)
    }

    func testPolicyChangesPreserveNativeFixtureSessionAndQueuedInput() throws {
        let (_, context, handle) = try make()
        defer { destroyContext(handle) }
        XCTAssertEqual(startContext(handle), 0)
        var report = S2KState()
        report.sequence = 1
        report.buttons = UInt32(S2K_BUTTON_A)
        fixtureReport(handle, 0, UInt32(S2K_GAMECUBE), &report)
        let before = try XCTUnwrap(context.read(maximum: 16).snapshot.controllers.first)
        report.sequence = 2
        report.buttons = 0
        fixtureReport(handle, 0, UInt32(S2K_GAMECUBE), &report)
        XCTAssertEqual(s2k_set_automatic_discovery(handle, 1), 0)
        XCTAssertEqual(s2k_set_automatic_discovery(handle, 0), 0)
        let batch = context.read(maximum: 16)
        XCTAssertFalse(batch.resync)
        XCTAssertEqual(batch.events.count, 1)
        let after = try XCTUnwrap(batch.snapshot.controllers.first)
        XCTAssertEqual(after.connectionID, before.connectionID)
        XCTAssertEqual(after.state.sequence, 2)
        XCTAssertTrue(after.state.buttons.isEmpty)
    }

    func testExplicitStopStaysStoppedAndPolicySurvivesRestart() throws {
        let (source, context, handle) = try make()
        defer { destroyContext(handle) }
        XCTAssertEqual(s2k_set_automatic_discovery(handle, 1), 0)
        XCTAssertEqual(startContext(handle), 0)
        XCTAssertEqual(stopContext(handle), 0)
        XCTAssertEqual(s2k_set_automatic_discovery(handle, 0), 5)
        XCTAssertEqual(startContext(handle), 5)
        XCTAssertFalse(source.state.withLock { $0.running })
        XCTAssertTrue(source.state.withLock { $0.automaticDiscovery })
        try finishStop(source)
        XCTAssertEqual(s2k_set_automatic_discovery(handle, 1), 0)
        XCTAssertFalse(context.read(maximum: 0).snapshot.isRunning)
        XCTAssertEqual(source.state.withLock { $0.discoveryConfigurationCount }, 1)
        XCTAssertEqual(startContext(handle), 0)
        XCTAssertTrue(source.state.withLock { $0.automaticDiscovery })
        XCTAssertEqual(stopContext(handle), 0)
        try finishStop(source)
        XCTAssertEqual(s2k_set_automatic_discovery(handle, 0), 0)
        XCTAssertFalse(source.state.withLock { $0.running })
        XCTAssertFalse(source.state.withLock { $0.automaticDiscovery })
    }
}
