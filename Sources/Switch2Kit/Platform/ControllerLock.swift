#if canImport(os)
import os

// Native scoped locks own their state; no caller-managed lock address or storage.
// Apple platforms use the checked Sendable API available before our OS floors.
package typealias ControllerLock<State: Sendable> = OSAllocatedUnfairLock<State>

extension OSAllocatedUnfairLock where State: Sendable {
    package init(_ initialState: State) { self.init(initialState: initialState) }
}
#else
import Synchronization

// Keep the native noncopyable lock and its inlined fast path on Linux/Windows.
package typealias ControllerLock<State: Sendable> = Mutex<State>
#endif
