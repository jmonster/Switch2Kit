import XCTest
import Switch2KitC
import Switch2KitCABI
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class ConfigurationValidationTests: XCTestCase {
    func testIncompatibleHeaderTakesPrecedenceOverInvalidLimits() {
        for (version, size) in [(UInt32(2), UInt32(MemoryLayout<S2KConfig>.size)),
                                (UInt32(1), UInt32(8))] {
            var config = S2KConfig(abi_version: version, struct_size: size,
                                   maximum_controllers: 0, event_capacity: 0)
            var result: Int32 = -1
            XCTAssertNil(createContext(&config, &result))
            XCTAssertEqual(result, Int32(S2K_ABI_MISMATCH))
        }
    }

    #if canImport(Darwin) || canImport(Glibc)
    private func withGuardedHeader(_ body: (UnsafeMutableRawPointer) -> Void) throws {
        let pageSize = Int(sysconf(Int32(_SC_PAGESIZE)))
        XCTAssertGreaterThan(pageSize, 8)
        guard pageSize > 8 else { return }
        #if canImport(Darwin)
        let anonymous = MAP_ANON
        #else
        let anonymous = MAP_ANONYMOUS
        #endif
        let allocation = mmap(nil, pageSize * 2, PROT_READ | PROT_WRITE,
                              MAP_PRIVATE | anonymous, -1, 0)
        XCTAssertNotEqual(allocation, MAP_FAILED)
        let memory = try XCTUnwrap(allocation)
        guard memory != MAP_FAILED else { return }
        defer { _ = munmap(memory, pageSize * 2) }
        let protected = memory.advanced(by: pageSize)
        let protection = mprotect(protected, pageSize, PROT_NONE)
        XCTAssertEqual(protection, 0)
        guard protection == 0 else { return }

        // Only the two-field header is readable. Accessing version-specific
        // fields before rejecting the incompatible ABI would hit the guard page.
        body(protected.advanced(by: -8))
    }

    func testIncompatibleConfigurationDoesNotReadBeyondItsHeader() throws {
        try withGuardedHeader { header in
            let config = header.assumingMemoryBound(to: S2KConfig.self)
            for (version, size) in [(UInt32(1), UInt32(8)),
                                    (UInt32(2), UInt32(MemoryLayout<S2KConfig>.size))] {
                header.storeBytes(of: version, as: UInt32.self)
                header.storeBytes(of: size, toByteOffset: 4, as: UInt32.self)
                var result: Int32 = -1
                XCTAssertNil(createContext(config, &result))
                XCTAssertEqual(result, Int32(S2K_ABI_MISMATCH))
                XCTAssertNil(createContext(config, nil))
            }
        }
    }

    func testIncompatibleMotionProfileDoesNotReadBeyondItsHeader() throws {
        try withGuardedHeader { header in
            let profile = header.assumingMemoryBound(to: S2KMotionProfile.self)
            for (version, size) in [(UInt32(1), UInt32(8)),
                                    (UInt32(2), UInt32(MemoryLayout<S2KMotionProfile>.size))] {
                header.storeBytes(of: version, as: UInt32.self)
                header.storeBytes(of: size, toByteOffset: 4, as: UInt32.self)
                var output = S2KMotionCalibration()
                output.version = 42
                XCTAssertEqual(motionProfileCalibration(profile, nil, &output,
                    UInt32(MemoryLayout<S2KMotionCalibration>.size)), Int32(S2K_ABI_MISMATCH))
                XCTAssertEqual(output.version, 42)
            }
        }
    }
    #endif
}
