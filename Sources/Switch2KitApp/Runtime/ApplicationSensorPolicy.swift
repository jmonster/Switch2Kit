import Foundation

// Process environment selection remains an explicit application experiment, not library policy.
enum ApplicationSensorPolicy {
    static let selectedProfile = Switch2.Feature.SensorProfile.resolve(
        ProcessInfo.processInfo.environment["SWITCH2KIT_EXPERIMENTAL_SENSORS"],
        acknowledged: ProcessInfo.processInfo.environment["SWITCH2KIT_ACKNOWLEDGE_UNQUALIFIED_POWER"] == "1")
}
