#if canImport(CoreBluetooth) || os(Linux) || os(Windows)
import Foundation
import Switch2Kit

// C/C++ hosts consume the thread-safe hub, not a SwiftUI presentation snapshot.
// Reuse the same transport directly so Qt/wxWidgets do not need to run Swift's
// main dispatch queue just to maintain an unused presentation observer.
package final class ManagerSource: ControllerSource {
    package let hub: ControllerEventHub
    private let transport: ControllerTransport
    init(maximumControllers: Int) {
        let hub = ControllerEventHub()
        self.hub = hub
        transport = ControllerTransport(configuration: .init(maximumControllers: maximumControllers),
                                        hub: hub, diagnostics: Switch2Diagnostics())
    }
    deinit { transport.shutdown() }
    package func start() { transport.start() }
    package func stop(completion: @escaping @Sendable () -> Void) { transport.stop(completion: completion) }
    package func discover(seconds: Double) { transport.requestDiscoveryWindow(seconds: seconds) }
    package func setAutomaticDiscovery(_ enabled: Bool) {
        transport.configureDiscovery(mode: enabled ? .automatic : .onDemand, remembered: [])
    }
    package func disconnect(id: Switch2ControllerID, connection: UUID, forget: Bool) {
        transport.disconnect(id, forget: forget, expectedConnection: connection)
    }
    package func rumble(id: Switch2ControllerID, connection: UUID, strong: Double, weak: Double, duration: Double?, feedback: Bool) {
        transport.submitRumble(id, strong: strong, weak: weak, duration: duration,
                               feedback: feedback, expectedConnection: connection)
    }
    package func player(id: Switch2ControllerID, connection: UUID, number: Int) {
        transport.withSession(id, expectedConnection: connection) { $0.setPlayerNumber(number) }
    }
}
#endif
