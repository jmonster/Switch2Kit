#if canImport(CoreBluetooth)
import XCTest
@testable import Switch2Kit

final class ApplePlatformTests: XCTestCase {
    @MainActor
    func testConstructionDoesNotStartTheRadio() async {
        let manager = Switch2ControllerManager()
        XCTAssertFalse(manager.currentSnapshot.isRunning)
        XCTAssertTrue(manager.currentSnapshot.controllers.isEmpty)
    }

    func testHostAddressIsAbsentWithoutIOBluetooth() {
        #if !canImport(IOBluetooth)
        XCTAssertNil(HostBluetooth.macAddressBytesLE)
        #endif
    }
}
#endif
