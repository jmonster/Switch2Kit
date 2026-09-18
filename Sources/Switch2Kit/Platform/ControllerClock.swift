import Foundation
#if os(Windows)
import WinSDK
#endif

/// Shared host receive/deadline clock. Never use wall-clock time for input.
/// Windows Foundation uptime is too coarse for consecutive controller reports;
/// QPC supplies the same high-resolution clock domain to the engine and C ABI.
package enum ControllerClock {
#if os(Windows)
    private static let frequency: Double = {
        var value = LARGE_INTEGER()
        guard QueryPerformanceFrequency(&value) != 0, value.QuadPart > 0 else { return .nan }
        return Double(value.QuadPart)
    }()
#endif
    package static var now: TimeInterval {
#if os(Windows)
        var value = LARGE_INTEGER()
        guard QueryPerformanceCounter(&value) != 0, value.QuadPart >= 0 else { return .nan }
        return Double(value.QuadPart) / frequency
#else
        return ProcessInfo.processInfo.systemUptime
#endif
    }
}
