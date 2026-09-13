import Foundation

// Commands and audio use the production app companion. Rumble uses the library
// session directly; only the optional tool orchestration boundary is a fake.
final class ControllerToolOperations { func cancel() {} }

extension ControllerSession {
    var experimentalFixture: ControllerToolSession {
        if let value = companion as? ControllerToolSession { return value }
        let value = ControllerToolSession(base: self)
        companion = value
        return value
    }
    func experimentalCommand(_ command: UInt8, _ subcommand: UInt8, payload: Data,
                             flag: UInt8 = 0x01, completion: @escaping (Data?) -> Void) {
        experimentalFixture.experimentalCommand(command, subcommand, payload: payload, flag: flag, completion: completion)
    }
    func experimentalCommandResult(_ command: UInt8, _ subcommand: UInt8, payload: Data,
                                   flag: UInt8 = 0x01, completion: @escaping (CommandResult) -> Void) {
        experimentalFixture.experimentalCommandResult(command, subcommand, payload: payload, flag: flag, completion: completion)
    }
    func testRumble(intensity: Double) {
        let level = intensity.isFinite ? max(0, min(1, intensity)) : 0
        guard level > 0 else { return }
        pulseRumble(strong: level, weak: model == .proController2 ? level : 0, duration: 0.4)
    }
}
