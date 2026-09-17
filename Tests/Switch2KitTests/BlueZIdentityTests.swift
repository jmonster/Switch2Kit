#if os(Linux)
import XCTest
@testable import Switch2Kit

final class BlueZIdentityTests: XCTestCase {
    func testNameBasedIdentityVectors() {
        // Independent RFC UUIDv5-compatible values, including multi-block SHA-1 input.
        let vectors = [
            ("www.widgets.com", "21F7F8DE-8051-5B89-8680-0195EF798B6A"),
            ("", "4EBD0208-8328-5D69-8C44-EC50939C0967"),
            (String(repeating: "x", count: 60), "F7A7B7A9-E0C0-5062-875B-7505B6B8AADD")
        ]
        for (name, expected) in vectors { XCTAssertEqual(BlueZIdentity.uuid(name: name).uuidString, expected) }
        XCTAssertNotEqual(BlueZIdentity.uuid(name: "adapter1/public/device"), BlueZIdentity.uuid(name: "adapter2/public/device"))
        XCTAssertNotEqual(BlueZIdentity.uuid(name: "adapter/public/device"), BlueZIdentity.uuid(name: "adapter/random/device"))
    }
    func testAddressValidationAndControllerByteOrder() {
        XCTAssertEqual(BlueZIdentity.addressBytes("12:34:56:78:9a:bC"), Data([0xbc, 0x9a, 0x78, 0x56, 0x34, 0x12]))
        for invalid in ["", "12:34", "GG:34:56:78:9A:BC", "1:34:56:78:9A:BC", ":12:34:56:78:9A:BC", "12:34:56:78:9A:BC:", "12::34:56:78:9A:BC"] {
            XCTAssertNil(BlueZIdentity.addressBytes(invalid), invalid)
        }
    }
    func testConservativeATTWriteLimits() {
        let uuid = UUID()
        for (mtu, expected) in [(0, 0), (2, 0), (23, 20), (247, 244), (517, 512)] {
            XCTAssertEqual(BlueZCharacteristic(path: "/test", uuid: uuid, flags: [], mtu: mtu).writeLimit, expected)
        }
    }
}
#endif
