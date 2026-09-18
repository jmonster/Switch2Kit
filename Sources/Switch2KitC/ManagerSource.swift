#if canImport(CoreBluetooth) || os(Linux)
import Foundation
import Switch2Kit

package final class ManagerSource: ControllerSource {
    let manager: Switch2ControllerManager
    package var hub: ControllerEventHub { manager.hub }
    @MainActor init(maximumControllers: Int) {
        manager = Switch2ControllerManager(configuration: .init(maximumControllers: maximumControllers))
    }
    package func start() { manager.start() }
    package func stop(completion: @escaping @Sendable () -> Void) { manager.stop(completion: completion) }
    package func discover(seconds: Double) { try? manager.discover(for: seconds) }
    package func setAutomaticDiscovery(_ enabled: Bool) {
        manager.configureDiscovery(enabled ? .automatic : .onDemand)
    }
    package func disconnect(id: Switch2ControllerID, connection: UUID, forget: Bool) {
        manager.transport.disconnect(id, forget: forget, expectedConnection: connection)
    }
    package func rumble(id: Switch2ControllerID, connection: UUID, strong: Double, weak: Double, duration: Double?, feedback: Bool) {
        manager.transport.submitRumble(id, strong: strong, weak: weak, duration: duration,
                                       feedback: feedback, expectedConnection: connection)
    }
    package func player(id: Switch2ControllerID, connection: UUID, number: Int) {
        manager.transport.withSession(id, expectedConnection: connection) { $0.setPlayerNumber(number) }
    }
}
#endif
