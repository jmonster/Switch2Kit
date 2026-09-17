# Rumble

## Short feedback on every controller

```swift
try manager.playRumble(for: controller.id, intensity: 0.4)
```

Intensity is finite `0...1`; zero is mute. Switch 2 Pro Controller and Joy-Con 2 play a 400 ms HD pulse. Pro drives both actuators; a Joy-Con drives its one actuator without doubling the gain.

The NSO GameCube controller plays firmware clips: intensity below `0.5` selects soft (preset 3), and `0.5...1` selects strong (preset 2). The controller determines the duration. A submitted clip cannot be cancelled or turned into an arbitrary-duration effect. These commands use the command characteristic, never the HD-motor characteristic.

Every supported model advertises `.rumble`. At most one feedback action per controller is admitted each 500 ms. On every model, a busy command lane or blocked radio reports `.operationBusy` instead of storing delayed feedback. A missing characteristic or insufficient write size reports `.protocolFailure`. Rejected feedback does not replace an existing game effect or consume the rate allowance. Requests coalesce per physical controller, expire after 500 ms, and cannot cross connection generations. The inbox holds at most 64 controllers; overflow reports `.operationQueueFull`, while updates to an already-pending controller still replace its intent.

## Continuous and duration-controlled effects

All four supported models advertise `.continuousRumble`:

```swift
if controller.capabilities.contains(.continuousRumble) {
    try manager.pulseRumble(for: controller.id, strong: 0.5, weak: 0.2, duration: 0.15)
    // Renew this intent within 500 ms for a longer effect.
    try manager.setRumble(for: controller.id, strong: 0.3, weak: 0.1)
    try manager.setRumble(for: controller.id, strong: 0)
}
```

Strong and weak address Pro's left and right actuators; Joy-Con combines them into its one actuator. Pulse durations accept `0.01...0.5` seconds. A newer pulse or continuous intent supersedes the previous one. Each physical session reuses one stop timer, including when pulses are replaced rapidly. A queued timer event checks the current deadline and generation before stopping an effect. Continuous intent parks the timer, and disconnect cancels it. Continuous intent expires after 500 ms when the host stops renewing it.

GameCube also retains `.rumblePresets` for short feedback. Continuous/pulse requests use its **separate on/off motor**: either active channel turns it on, both zero turn it off. Nonzero intensity is not proportional motor strength. `playRumble` continues to use the existing device-timed preset commands for compatibility.

The GameCube motor-only Bluetooth characteristic is `3f8fb670-ab25-45bf-b540-38c72834d064`, not the Pro's HD channel. The payload is `[00, 50 | sequence, on, 00, 00]`, with sequence wrapping modulo 16 and on equal to 0 or 1. Layout references: [ndeadly's HID report documentation](https://github.com/ndeadly/switch2_controller_research/blob/master/hid_reports.md#output-report-0x03) and [BlueRetro's GameCube motor block](https://github.com/darthcloud/BlueRetro/blob/master/main/bluetooth/hidp/sw2.c) / [on-off encoding](https://github.com/darthcloud/BlueRetro/blob/master/main/adapter/wireless/sw2.c). BlueRetro sends that motor block with a command on the combined characteristic; this implementation uses the separately documented motor-only characteristic. No BlueRetro source is copied.

Backpressure replaces pending motor state (including stop); expired requests cannot re-enable it. Retirement attempts an immediate stop only while writable, never queues work after retirement. Radio loss cannot guarantee physical receipt of a stop. Automated packet, session, transport, C and SDL tests do **not** establish physical rumble; verify Test Rumble, actual gameplay, and stopping on your NSO controller.

## Dashboard and examples

The dashboard's Test Rumble action and the demo use the same library operation. Test Rumble respects the saved intensity, addresses the selected physical controller even without a player assignment, and sends to both members of a selected Joy-Con pair. Game outputs retain their channel/duration contracts and use `.continuousRumble` where required.

## Tests

`bash tests/rumble/run.sh` exercises exact preset bytes, acknowledgements, busy/rate limits, mute, actuator selection, FIFO ordering, pulse replacement, grouping and stale identities against production session methods. Transport tests cover bounded ingress and retirement. They use fake radio boundaries; physical effect testing requires a connected controller.
