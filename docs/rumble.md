# Rumble

Rumble is part of `Switch2Kit`; no additional package product is required.

```swift
try manager.pulseRumble(for: controller.id, strong: 0.5, weak: 0.5, duration: 0.15)
```

| Model | Routing | Control |
| --- | --- | --- |
| Pro Controller 2 | Left and right HD actuators | Independent normalized channels, timed pulses, stop |
| Joy-Con 2 | One HD actuator per physical unit | Mixed channels, timed pulses, stop |
| NSO GameCube | Vibration command `0x0A/0x02` | Finite soft or strong firmware clip |

All models advertise `.rumble`. Pro and Joy-Con also advertise `.continuousRumble`. GameCube maps the larger channel to soft below 0.5 and strong at or above 0.5. Zero is silent. Its command has no duration or stop field: `duration` does not change the clip, and an already submitted clip finishes in firmware. GameCube never receives HD motor packets.

`setRumble` renews HD intent; it expires after 500 ms without a refresh. On GameCube it requests one firmware clip. Preset admission is bounded to two per second, and busy commands are rejected rather than queued for delayed playback. Observe `.failure(_, .operationQueueFull)` to detect backpressure.

The app's **Test** button uses this same library API and the saved intensity. Pro tests both motors; a linked Joy-Con pair tests both physical units. Tests do not depend on a game-player slot.

Game output is separate from direct SDK control. SDL and browser outputs return Pro/Joy-Con HD requests; their GameCube motor-format requests remain disabled. RetroArch network output and the current virtual-HID output have no rumble return path.

Run `bash tests/rumble/run.sh` and `bash tests/engine/run.sh` for command framing, ACK correlation, mute, busy/capacity bounds, independent actuators, ordering, and retirement. These use simulated Bluetooth boundaries; physical motor response is tested on a connected controller.
