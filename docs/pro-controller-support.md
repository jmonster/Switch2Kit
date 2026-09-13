# Switch 2 Pro Controller

Switch2Kit recognizes Nintendo VID `057e`, PID `2069`. Hold Sync while discovery is active to connect. The library reads identity and stick calibration, configures LEDs and sensors, performs protocol bonding when the host Bluetooth address is available, and starts input notifications. Readiness requires both the handshake and the first valid report. See [Bluetooth lifecycle](switch2kit/bluetooth-lifecycle.md).

## Input

The decoder exposes A/B/X/Y, four D-pad directions, L/R, ZL/ZR, Minus/Plus, Home, Capture, C, both stick clicks, and GL/GR. ZL/ZR are digital buttons. Both sticks have independent user, factory and nominal calibration fallback.

The dashboard can remap C, GL and GR along with the other buttons. Battery voltage/current, charging state, IMU temperature, gyro, acceleration and magnetometer readings are available in controller state. The selected output determines which fields reach another application.

## Rumble

```swift
try manager.playRumble(for: controller.id, intensity: 0.4)
try manager.pulseRumble(for: controller.id, strong: 0.5, weak: 0.2, duration: 0.15)
```

Strong and weak control the left and right motors. Motor frames are atomic, have one sequence number per submitted write, and replace stale intent under backpressure. Continuous intent expires after 500 ms unless renewed. Missing motor characteristics or insufficient write size do not stop input keep-alives. See [rumble](rumble.md) for all model mappings.

## Outputs

| Output | Controls | Rumble | Motion |
| --- | --- | --- | --- |
| SDL3 bridge | 19 buttons and two digital trigger axes | Two channels | Opt-in gyro/accelerometer |
| Chromium extension | Gamepad controls and extra buttons | Browser vibration return path | Not forwarded |
| RetroArch network gamepad | Standard controls and remapping | No return channel | Not forwarded |
| CoreHID virtual gamepad | Sticks, triggers, hat, GL/GR/C | No output report | Not forwarded |

CoreHID requires Apple's restricted virtual-device entitlement. USB controller support belongs to the patched SDL HIDAPI driver; the Switch2Kit library manages Bluetooth connections.

## SDL motion

Build the library with `bash sdl/build-sdl.sh`. Games must explicitly enable SDL sensors. The 44-byte S2B1 report carries raw gyro and acceleration. Conversion uses the pinned SDL driver's nominal Pro convention: `(X,Y,Z)` becomes `(X,Z,-Y)`, gyro scales by `34.8 / 32767` radians/s per count, and acceleration by `9.80665 * 8 / 32767` m/s² per count.

Samples use host receipt time and report an unknown sample rate (`0`). The wire format does not carry IMU calibration, device timestamps or firmware sensitivity metadata. See the [protocol reference](protocol.md).

## Tests

`bash tests/pro-controller/run.sh` covers identity, handshake, button decoding, calibration, telemetry, rumble channels, backpressure, expiry and keep-alive using fake Bluetooth boundaries. The SDL workflow exercises gamepad and sensor APIs through localhost UDP. Physical checks include stick endpoints, button releases, motion orientation, rumble, reconnect, sleep/wake and the intended game.
