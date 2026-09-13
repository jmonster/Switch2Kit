# Rumble

## Short feedback on every controller

```swift
try manager.playRumble(for: controller.id, intensity: 0.4)
```

Intensity is finite `0...1`; zero is mute. Switch 2 Pro Controller and Joy-Con 2 play a 400 ms HD pulse. Pro drives both actuators; a Joy-Con drives its one actuator without doubling the gain.

The NSO GameCube controller plays firmware clips: intensity below `0.5` selects soft (preset 3), and `0.5...1` selects strong (preset 2). The controller determines the duration. A submitted clip cannot be cancelled or turned into an arbitrary-duration effect. These commands use the command characteristic, never the HD-motor characteristic.

Every supported model advertises `.rumble`. At most one feedback action per controller is admitted each 500 ms. A busy command lane or blocked radio reports `.operationBusy` instead of storing a delayed clip. Requests are bounded, coalesced per physical controller, expire after 500 ms, and cannot cross connection generations.

## Continuous and duration-controlled effects

Pro and Joy-Con additionally advertise `.continuousRumble`:

```swift
if controller.capabilities.contains(.continuousRumble) {
    try manager.pulseRumble(for: controller.id, strong: 0.5, weak: 0.2, duration: 0.15)
    // Renew this intent within 500 ms for a longer effect.
    try manager.setRumble(for: controller.id, strong: 0.3, weak: 0.1)
    try manager.setRumble(for: controller.id, strong: 0)
}
```

Strong and weak address Pro's left and right actuators; Joy-Con combines them into its one actuator. Pulse durations accept `0.01...0.5` seconds. A newer pulse or continuous intent supersedes the previous one. Old stop callbacks cannot stop a newer effect. Continuous intent expires after 500 ms when the host stops renewing it.

GameCube advertises `.rumblePresets` rather than `.continuousRumble`. Use `playRumble` on that model; `setRumble` and `pulseRumble` report `.unsupportedOperation` instead of sending incompatible HD packets.

## Dashboard and examples

The dashboard's Test Rumble action and the demo use the same library operation. Test Rumble respects the saved intensity, addresses the selected physical controller even without a player assignment, and sends to both members of a selected Joy-Con pair. Game outputs retain their channel/duration contracts and use `.continuousRumble` where required.

## Tests

`bash tests/rumble/run.sh` exercises exact preset bytes, acknowledgements, busy/rate limits, mute, actuator selection, FIFO ordering, pulse replacement, grouping and stale identities against production session methods. Transport tests cover bounded ingress and retirement. They use fake radio boundaries; physical effect testing requires a connected controller.
