import Foundation
import XCTest
@testable import Switch2Kit

final class ObservationConcurrencyTests: XCTestCase {
    func testFullRateDeliveryIsOrderedAndSerialOnConcurrentQueue() throws {
        struct Delivery: Sendable {
            var sequences: [UInt64] = []
            var active = 0
            var overlapped = false
        }
        let queue = DispatchQueue(label: "test.observation.full-rate", attributes: .concurrent)
        let delivered = ControllerLock(Delivery())
        let done = expectation(description: "All reports delivered")
        let hub = ControllerEventHub(), lifetime = SessionLifetime()
        let id = Switch2ControllerID(rawValue: UUID())
        let count: UInt64 = 2_048
        let observation = try hub.observe(queue: queue, capacity: 4096) { event in
            guard case .input(let controller) = event else { return }
            delivered.withLock {
                $0.active += 1
                if $0.active != 1 { $0.overlapped = true }
                $0.sequences.append(controller.state.sequence)
            }
            delivered.withLock { $0.active -= 1 }
            if controller.state.sequence == count { done.fulfill() }
        }
        for sequence in 1...count {
            let controller = Switch2Controller(id: id, model: .proController2,
                state: .init(buttons: sequence.isMultiple(of: 2) ? [] : .a, sequence: sequence),
                connectedAt: Date(timeIntervalSince1970: 0), bodyColor: nil, buttonColor: nil,
                serialNumber: nil, sessionGeneration: lifetime.id, lastActivityAt: 0)
            hub.publish(.init(controllers: [controller]), event: .input(controller), lifetime: lifetime)
        }
        wait(for: [done], timeout: 5)
        observation.cancel()
        let result = delivered.withLock { $0 }
        XCTAssertEqual(result.sequences, Array(1...count))
        XCTAssertFalse(result.overlapped)
    }

    func testConcurrentCancellationDiscardsQueuedWorkAndReleasesAdmission() throws {
        let queue = DispatchQueue(label: "test.observation.cancel-race", attributes: .concurrent)
        queue.suspend()
        let calls = ControllerLock(0)
        let hub = ControllerEventHub()
        let observation = try hub.observe(queue: queue, capacity: 4096) { _ in
            calls.withLock { $0 += 1 }
        }
        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            for _ in 0..<512 {
                if worker.isMultiple(of: 2) { observation.cancel() }
                else { hub.publish(.init(), event: .status(.init())) }
            }
        }
        queue.resume()
        queue.sync(flags: .barrier) {}
        XCTAssertEqual(calls.withLock { $0 }, 0)
        var replacements: [Switch2ControllerObservation] = []
        for _ in 0..<32 { replacements.append(try hub.observe(queue: queue, capacity: 1) { _ in }) }
        replacements.forEach { $0.cancel() }
    }

    func testHandlerCanCancelItsOwnObservation() throws {
        let queue = DispatchQueue(label: "test.observation.self-cancel")
        queue.suspend()
        let token = ControllerLock<Switch2ControllerObservation?>(nil)
        let calls = ControllerLock(0)
        let done = expectation(description: "Handler canceled without deadlock")
        let hub = ControllerEventHub()
        let observation = try hub.observe(queue: queue, capacity: 64) { _ in
            calls.withLock { $0 += 1 }
            let observation = token.withLock { $0 }
            observation?.cancel()
            done.fulfill()
        }
        token.withLock { $0 = observation }
        for _ in 0..<32 { hub.publish(.init(), event: .status(.init())) }
        queue.resume()
        wait(for: [done], timeout: 5)
        queue.sync {}
        XCTAssertEqual(calls.withLock { $0 }, 1)
        token.withLock { $0 = nil }
    }
}
