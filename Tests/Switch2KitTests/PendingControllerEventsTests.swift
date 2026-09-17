import Foundation
import Synchronization
import XCTest
@testable import Switch2Kit

final class PendingControllerEventsTests: XCTestCase {
    private func envelope(_ sequence: UInt64, lifetime: SessionLifetime? = nil) -> EventEnvelope {
        .init(sequence: sequence, event: .status(.init()), lifetime: lifetime)
    }

    func testLazyGrowthAndRepeatedWrapStayWithinConfiguredCapacity() {
        for capacity in [1, 2, 3, 7, 256, 4096] {
            var inbox = PendingControllerEvents(capacity: capacity)
            var expected: [UInt64] = []
            XCTAssertEqual(inbox.allocatedCount, 0, "Idle observers must not preallocate their maximum backlog")
            for sequence in UInt64(1)...10_000 {
                if expected.count == capacity {
                    XCTAssertEqual(inbox.popFirst()?.sequence, expected.removeFirst())
                }
                inbox.append(envelope(sequence)); expected.append(sequence)
                if sequence % 3 == 0 {
                    XCTAssertEqual(inbox.popFirst()?.sequence, expected.removeFirst())
                }
                XCTAssertEqual(inbox.count, expected.count)
                XCTAssertLessThanOrEqual(inbox.allocatedCount, capacity)
            }
            XCTAssertEqual(inbox.takeFirst(capacity).map(\.sequence), expected)
            XCTAssertTrue(inbox.isEmpty)
            XCTAssertNil(inbox.popFirst())
        }
    }

    func testGrowthPreservesWrappedEntriesAndPartialReads() {
        var inbox = PendingControllerEvents(capacity: 7)
        for n in UInt64(1)...4 { inbox.append(envelope(n)) }
        XCTAssertEqual(inbox.takeFirst(3).map(\.sequence), [1, 2, 3])
        for n in UInt64(5)...10 { inbox.append(envelope(n)) }
        XCTAssertEqual(inbox.allocatedCount, 7)
        XCTAssertTrue(inbox.takeFirst(0).isEmpty)
        XCTAssertEqual(inbox.takeFirst(2).map(\.sequence), [4, 5])
        XCTAssertEqual(inbox.takeFirst(100).map(\.sequence), [6, 7, 8, 9, 10])
        XCTAssertTrue(inbox.isEmpty)
    }

    func testResynchronizationDiscardsOnlyObsoletePrefixAfterWrap() {
        var inbox = PendingControllerEvents(capacity: 4)
        for n in UInt64(1)...4 { inbox.append(envelope(n)) }
        _ = inbox.takeFirst(3)
        for n in UInt64(5)...7 { inbox.append(envelope(n)) }
        inbox.discard(through: 3)
        XCTAssertEqual(inbox.count, 4)
        inbox.discard(through: 5)
        XCTAssertEqual(inbox.takeFirst(4).map(\.sequence), [6, 7])
        inbox.append(envelope(8)); inbox.discard(through: .max)
        XCTAssertTrue(inbox.isEmpty)
    }

    func testPoppedAndDiscardedEnvelopesReleaseTheirLifetimeImmediately() {
        var inbox = PendingControllerEvents(capacity: 8)
        weak var popped: SessionLifetime?
        weak var discarded: SessionLifetime?
        do {
            let first = SessionLifetime(), second = SessionLifetime()
            popped = first; discarded = second
            inbox.append(envelope(1, lifetime: first))
            inbox.append(envelope(2, lifetime: second))
        }
        XCTAssertNotNil(popped); XCTAssertNotNil(discarded)
        _ = inbox.popFirst()
        XCTAssertNil(popped, "Consumed storage must not pin a retired attempt")
        XCTAssertNotNil(discarded)
        inbox.discard(through: 2)
        XCTAssertNil(discarded)
    }

    func testClearReleasesSnapshotTokensAndOptionallyRetainsOnlyEmptySlots() {
        for keep in [true, false] {
            var inbox = PendingControllerEvents(capacity: 4)
            weak var token: SessionLifetime?
            do {
                let lifetime = SessionLifetime(); token = lifetime
                var item = envelope(1)
                item.snapshotLifetimes = [lifetime]
                inbox.append(item)
            }
            XCTAssertNotNil(token)
            inbox.removeAll(keepingCapacity: keep)
            XCTAssertNil(token)
            XCTAssertTrue(inbox.isEmpty)
            XCTAssertEqual(inbox.allocatedCount, keep ? 1 : 0)
            inbox.append(envelope(2))
            XCTAssertEqual(inbox.popFirst()?.sequence, 2)
        }
    }

    func testFullRateObservationDrainsRepeatedMaximumBacklogsInOrder() throws {
        let hub = ControllerEventHub(), lifetime = SessionLifetime()
        let id = Switch2ControllerID(rawValue: UUID())
        let queue = DispatchQueue(label: "test.observation.circular")
        let reports = Mutex<[UInt64]>([])
        let done = DispatchSemaphore(value: 0)
        let observation = try hub.observe(queue: queue, capacity: 4096) { event in
            if case .input(let controller) = event {
                reports.withLock { $0.append(controller.state.sequence) }
                if controller.state.sequence % 4095 == 0 { done.signal() }
            }
        }
        defer { observation.cancel() }
        for round in 0..<3 {
            queue.suspend()
            for n in 1...4095 {
                let sequence = UInt64(round * 4095 + n)
                let value = Switch2Controller(id: id, model: .joyCon2Left,
                    state: .init(buttons: sequence % 2 == 0 ? [] : .slL, sequence: sequence),
                    connectedAt: Date(timeIntervalSince1970: 0), bodyColor: nil, buttonColor: nil,
                    serialNumber: nil, sessionGeneration: lifetime.id, lastActivityAt: 0)
                hub.publish(.init(controllers: [value]), event: .input(value), lifetime: lifetime)
            }
            queue.resume()
            XCTAssertEqual(done.wait(timeout: .now() + 10), .success)
        }
        XCTAssertEqual(reports.withLock { $0 }, Array(UInt64(1)...12_285))
    }

    func testPullReaderPreservesPartialReadFlagsAndOverflowRecovery() throws {
        let hub = ControllerEventHub(), reader = try hub.makeReader(capacity: 7)
        defer { reader.cancel() }
        XCTAssertTrue(reader.read(maximum: 1).resync)
        for _ in 0..<1000 {
            for _ in 0..<7 { hub.publish(.init(), event: .status(.init())) }
            for count in [3, 2, 2] {
                let batch = reader.read(maximum: count)
                XCTAssertFalse(batch.resync)
                XCTAssertEqual(batch.events.count, count)
                XCTAssertEqual(batch.more, reader.pendingCount > 0)
            }
            XCTAssertEqual(reader.pendingCount, 0)
        }
        for _ in 0..<100 { hub.publish(.init(), event: .status(.init())) }
        let recovered = reader.read(maximum: 7)
        XCTAssertTrue(recovered.resync); XCTAssertTrue(recovered.events.isEmpty)
        XCTAssertFalse(recovered.more)
        hub.publish(.init(), event: .status(.init()))
        XCTAssertEqual(reader.read(maximum: 1).events.count, 1)
        reader.cancel()
        hub.publish(.init(), event: .status(.init()))
        XCTAssertTrue(reader.read(maximum: 7).events.isEmpty)
    }
}
