# Public API

Use Xcode Quick Help for declaration-level documentation. The library exposes immutable `Sendable` values, not CoreBluetooth peripherals or mutable sessions.

## Types and operations

| Area | Types |
| --- | --- |
| Ownership | `Switch2ControllerManager`, `Switch2ControllerObservation`, `Switch2ControllerConfiguration`, `Switch2ManagerSnapshot` |
| Controllers | `Switch2ControllerID`, `Switch2Controller`, `Switch2ControllerModel`, `Switch2ControllerCapabilities` |
| Input | `Switch2ControllerState`, `Switch2Buttons`, `Switch2Stick`, `Switch2Trigger`, `Switch2Battery`, `Switch2Motion`, `Switch2RawVector3`, `Switch2OpticalState`, `Switch2Color` |
| Lifecycle | `Switch2BluetoothState`, `Switch2DiscoveryState`, `Switch2DiscoveryMode`, `Switch2ConnectionState`, `Switch2DisconnectionReason`, `Switch2ControllerEvent`, `Switch2KitError` |
| Diagnostics | `Switch2LogLevel`, `Switch2LogCategory`, `Switch2LogRecord`, `Switch2LogHandler` |

The manager provides `start`, async/callback `stop`, `discover(for:)`, `configureDiscovery`, `useOnlyConnectedControllersForDiscovery`, `observe`, `disconnect`, `forget`, `setRumble`, `pulseRumble`, `setPlayerNumber`, `setPlayerLEDPattern` and `requestSignalStrength`. It has a main-actor observable presentation and an immediate thread-safe snapshot. Retain one manager and the observations your application uses.

## Input values

`buttons` is a 32-bit option set. It includes A/B/X/Y, D-pad, L/R/ZL/ZR, stick clicks, Plus/Minus/Home/Capture/C, GL/GR and handed Joy-Con SL/SR controls. Unknown bits survive construction; opposing D-pad bits may coexist.

`leftStick` and `rightStick` are optional two-dimensional vectors. Missing means the physical model has no such stick. Coordinates are calibrated and normalized to `-1...1`: positive x is right and positive y is up. The library applies neither an application dead zone nor Joy-Con grouping rotation. Public constructors clamp finite coordinates and replace non-finite coordinates with zero.

`Switch2Trigger.isPressed` is the digital ZL/ZR report bit. Optional `travel` is the GameCube analog byte divided by 255, in `0...1`. Travel and digital click are independent; other models have nil travel.

`Switch2Battery.millivolts` is voltage, with unavailable values represented by nil. `estimatedCharge` is a clamped `0...1` estimate over 3.30–4.15 V. Charge-state bits are raw UInt8. Current is signed Int16 sensor counts, positive while charging; no amperes conversion is applied.

`Switch2Motion` contains signed 16-bit accelerometer, gyroscope and magnetometer counts in named `Switch2RawVector3` values. These are sensor-native coordinates, not calibrated SI units or world-space orientation. Temperature is the IMU die estimate `25 + raw/127` degrees Celsius. Motion is nil when not requested by the sensor configuration.

Joy-Con optical x/y counters are UInt16 and wrap modulo 65536. Surface quality and lift distance are raw counts, not cursor pixels or millimeters. Reset host delta tracking on gaps or a new connection.

`receivedAt` is host monotonic seconds since boot. `sequence` starts at one per connection; host-constructed values may use zero. `connectedAt` is wall-clock readiness time.

## Identity and capabilities

`Switch2ControllerID` wraps a locally scoped UUID and supports Codable restoration. `connectionID` changes for each connection. Keep transient state by connection and saved preferences by controller ID. Serial numbers are nil unless explicitly requested in configuration; diagnostics omit them. Body/button colors use eight-bit sRGB components.

All supported models advertise `.rumble`. Pro and Joy-Con also advertise `.continuousRumble` for controllable-duration, cancellable motor effects. GameCube advertises `.analogTriggers` and uses finite soft/strong firmware rumble clips through the same manager API. A Joy-Con grip remains two physical controllers. See [rumble](../rumble.md) for model-specific timing and channel behavior.

## Delivery and failures

Invalid parameters throw `invalidParameter` synchronously. Bluetooth, connection, handshake, timeout, absent-session and operation-capacity failures arrive as typed events. `operationQueueFull` also reports busy or rate-limited GameCube preset requests.

Manager presentation is main-actor isolated. Commands enqueue transport work; observations execute serially on the selected host queue, away from Bluetooth callbacks. Buffers are bounded. On overflow, reconcile the authoritative `.snapshot`; clear cached input on disconnect or a new connection token. See [event delivery](concurrency-and-logging.md) and [Bluetooth lifecycle](bluetooth-lifecycle.md).
