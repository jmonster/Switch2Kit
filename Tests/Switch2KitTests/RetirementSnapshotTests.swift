import Foundation
import Synchronization
import XCTest
@testable import Switch2Kit

final class RetirementSnapshotTests: XCTestCase {
    private func controller(_ lifetime: SessionLifetime, id: Switch2ControllerID = .init(rawValue: UUID()),
                            sequence: UInt64 = 1) -> Switch2Controller {
        .init(id: id, model: .proController2, state: .init(buttons: .a, sequence: sequence),
              connectedAt: Date(timeIntervalSince1970: 0), bodyColor: nil, buttonColor: nil,
              serialNumber: nil, sessionGeneration: lifetime.id, lastActivityAt: 0)
    }

    func testRetirementBeforeDisconnectPublicationDoesNotExposeReadySnapshot() throws {
        let queue = DispatchQueue(label: "test.observation.retirement-publication-gap")
        queue.suspend()
        let hub = ControllerEventHub(), lifetime = SessionLifetime()
        let value = controller(lifetime)
        hub.publish(.init(controllers: [value]), event: .connected(value), lifetime: lifetime)
        let delivered = Mutex<[Switch2ControllerEvent]>([])
        let observation = try hub.observe(queue: queue, capacity: 64) { event in
            delivered.withLock { $0.append(event) }
        }
        // The observer queue can run between session teardown and transport publication.
        lifetime.retire()
        let readyDuringRetirement = hub.snapshot.controllers
        queue.resume(); queue.sync {}; queue.sync {}
        observation.cancel()
        XCTAssertTrue(readyDuringRetirement.isEmpty)
        for event in delivered.withLock({ $0 }) {
            switch event {
            case .input, .connected: XCTFail("Retired controller was delivered")
            case .snapshot(let state), .status(let state): XCTAssertTrue(state.controllers.isEmpty)
            default: break
            }
        }
    }

    func testRetirementProjectionPreservesOtherControllersAndManagerMetadata() {
        let hub = ControllerEventHub(), retired = SessionLifetime(), active = SessionLifetime()
        let first = controller(retired), second = controller(active)
        hub.publish(.init(controllers: [first]), event: .connected(first), lifetime: retired)
        hub.publish(.init(isRunning: true, bluetooth: .poweredOn, discovery: .scanning(until: 60),
                          controllers: [first, second], rememberedControllers: [first.id, second.id]),
                    event: .connected(second), lifetime: active)
        retired.retire()
        let snapshot = hub.snapshot
        XCTAssertEqual(snapshot.controllers, [second])
        XCTAssertTrue(snapshot.isRunning)
        XCTAssertEqual(snapshot.bluetooth, .poweredOn)
        XCTAssertEqual(snapshot.discovery, .scanning(until: 60))
        XCTAssertEqual(snapshot.rememberedControllers, [first.id, second.id])
        let envelope = hub.current()
        XCTAssertEqual(envelope.snapshotLifetimes.map(\.id), [active.id])
        guard case .snapshot(let current) = envelope.event else { return XCTFail("Expected snapshot") }
        XCTAssertEqual(current, snapshot)
    }

    func testObserverJoiningDuringRetirementKeepsHealthyInputInOrder() throws {
        let queue = DispatchQueue(label: "test.observation.retirement-join")
        queue.suspend()
        let hub = ControllerEventHub(), retired = SessionLifetime(), active = SessionLifetime()
        let first = controller(retired), second = controller(active)
        hub.publish(.init(controllers: [first]), event: .connected(first), lifetime: retired)
        hub.publish(.init(controllers: [first, second]), event: .connected(second), lifetime: active)
        retired.retire()
        let delivered = Mutex<[Switch2ControllerEvent]>([])
        let observation = try hub.observe(queue: queue, capacity: 256) { event in
            delivered.withLock { $0.append(event) }
        }
        for sequence in 1...100 {
            let input = controller(active, id: second.id, sequence: UInt64(sequence))
            hub.publish(.init(controllers: [first, input]), event: .input(input), lifetime: active)
        }
        queue.resume()
        for _ in 0..<8 { queue.sync {} }
        observation.cancel()
        let events = delivered.withLock { $0 }
        guard case .snapshot(let initial) = events.first else { return XCTFail("Expected initial snapshot") }
        XCTAssertEqual(initial.controllers.map(\.id), [second.id])
        let sequences = events.compactMap { event -> UInt64? in
            guard case .input(let value) = event else { return nil }
            XCTAssertEqual(value.id, second.id)
            return value.state.sequence
        }
        XCTAssertEqual(sequences, Array(UInt64(1)...100))
    }

    func testOverflowDuringRetirementResynchronizesWithoutRetiredControllers() throws {
        let queue = DispatchQueue(label: "test.observation.retirement-overflow")
        queue.suspend()
        let hub = ControllerEventHub(), lifetime = SessionLifetime()
        let value = controller(lifetime)
        hub.publish(.init(controllers: [value]), event: .connected(value), lifetime: lifetime)
        let delivered = Mutex<[Switch2ControllerEvent]>([])
        let observation = try hub.observe(queue: queue, capacity: 1) { event in
            delivered.withLock { $0.append(event) }
        }
        for _ in 0..<10_000 {
            hub.publish(.init(controllers: [value]), event: .input(value), lifetime: lifetime)
        }
        lifetime.retire()
        queue.resume(); queue.sync {}; queue.sync {}
        observation.cancel()
        let events = delivered.withLock { $0 }
        XCTAssertEqual(events.count, 1)
        guard case .snapshot(let snapshot) = events.first else { return XCTFail("Expected resynchronization") }
        XCTAssertTrue(snapshot.controllers.isEmpty)
    }

    func testReplacementGenerationSurvivesDelayedOldRetirement() {
        let hub = ControllerEventHub(), old = SessionLifetime(), replacement = SessionLifetime()
        let id = Switch2ControllerID(rawValue: UUID())
        let previous = controller(old, id: id), current = controller(replacement, id: id)
        hub.publish(.init(controllers: [previous]), event: .connected(previous), lifetime: old)
        old.retire()
        XCTAssertTrue(hub.snapshot.controllers.isEmpty)
        hub.publish(.init(controllers: [current]), event: .connected(current), lifetime: replacement)
        old.retire()
        XCTAssertEqual(hub.snapshot.controllers, [current])
        XCTAssertEqual(hub.current().snapshotLifetimes.map(\.id), [replacement.id])
        replacement.retire()
        XCTAssertTrue(hub.snapshot.controllers.isEmpty)
    }
}
