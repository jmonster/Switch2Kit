import Foundation
import Synchronization
import XCTest
@testable import Switch2Kit

final class DiagnosticsTests: XCTestCase {
    func testSlowDiagnosticHandlerHasBoundedStorageAndReportsDrops() {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        let records = Mutex<[Switch2LogRecord]>([])
        let diagnostics = Switch2Diagnostics(minimum: .warning) { record in
            let count = records.withLock { $0.append(record); return $0.count }
            if count == 1 { entered.signal(); release.wait() }
            if count == 130 { done.signal() }
        }
        diagnostics.emit(.debug, .session, "filtered")
        XCTAssertEqual(diagnostics.pendingCount, 0)
        diagnostics.emit(.warning, .session, "safe lifecycle warning")
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        for _ in 0..<10_000 {
            diagnostics.emit(.error, .session, String(repeating: "x", count: 1024))
            XCTAssertLessThanOrEqual(diagnostics.pendingCount, 128)
        }
        release.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 2), .success)
        let received = records.withLock { $0 }
        XCTAssertEqual(received.count, 130)
        XCTAssertTrue(received.allSatisfy { $0.message.count <= 512 })
        XCTAssertEqual(received.filter { $0.category == .diagnostics }.count, 1)
        XCTAssertTrue(received.contains { $0.message.contains("9872") })
        XCTAssertFalse(received.contains { $0.message == "filtered" })
    }
}
