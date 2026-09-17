# Public API and value semantics

The source's `///` comments document public declarations, including field units and delivery behavior. In Xcode, use Quick Help or Jump to Definition. Protocol and session implementation details use `package` or narrower access. Swift clients use the source package; native C/C++ clients use the documented C interface.

## Main surface

| Area | Public types |
| --- | --- |
| Ownership and observation | `Switch2ControllerManager`, `Switch2ControllerObservation`, `Switch2ControllerConfiguration`, `Switch2ManagerSnapshot` |
| Physical controllers | `Switch2ControllerID`, `Switch2Controller`, `Switch2ControllerModel`, `Switch2ControllerCapabilities` |
| Input | `Switch2ControllerState`, `Switch2Buttons`, `Switch2Stick`, `Switch2Trigger`, `Switch2Battery`, `Switch2Motion`, `Switch2RawVector3`, `Switch2OpticalState`, `Switch2Color` |
| Explicit motion conversion | `Switch2Vector3`, `Switch2MotionAxis`, `Switch2SensorCalibration`, `Switch2MotionCalibration`, `Switch2CalibratedMotion` |
| Lifecycle | `Switch2BluetoothState`, `Switch2DiscoveryState`, `Switch2DiscoveryMode`, `Switch2ConnectionState`, `Switch2DisconnectionReason`, `Switch2ControllerEvent`, `Switch2KitError` |
| Application actions | `Switch2ActionRouter`, `Switch2ActionBinding`, `Switch2ActionControl`, `Switch2ActionAxis`, `Switch2ActionSource`, `Switch2ActionEvent`, `Switch2NavigationAction` |
| Diagnostics | `Switch2LogLevel`, `Switch2LogCategory`, `Switch2LogRecord`, `Switch2LogHandler` |

The manager provides `start`, both async and callback `stop`, `discover(for:)`, `configureDiscovery`, `useOnlyConnectedControllersForDiscovery`, `observe`, `disconnect`, `forget`, `playRumble`, `setRumble`, `pulseRumble`, `setPlayerNumber`, `setPlayerLEDPattern` and `requestSignalStrength`. It exposes the main-actor presentation snapshot and an immediate thread-safe snapshot. There is no singleton requirement.

The public action router turns controller input and already-mapped local keyboard or external-provider input into host-defined pressed, released and repeated actions. `Switch2ActionRouter<Switch2NavigationAction>.navigation()` provides the optional navigation preset. Hosts own focus, timing and command execution, and must process returned releases on deactivation, source removal and rebinding. See [application actions](actions.md) for bindings, ownership and release guarantees, and [navigation](navigation.md) for the preset.

Application actions run in-process in the library. System keyboard/mouse injection, dashboard gesture handling and other external outputs are optional adapters, not requirements for an integrating application. Swift consumers use [SwiftPM source integration](README.md); [native C/C++ packaging and validation](cpp.md) remain supported separately.

## Input values

`buttons` is a 32-bit option set containing A/B/X/Y, D-pad, L/R/ZL/ZR, stick clicks, Plus/Minus/Home/Capture/C, GL/GR and handed Joy-Con SL/SR controls. Unknown bits survive value construction. Opposing D-pad bits may coexist; cancellation/remapping is host policy.

`leftStick` and `rightStick` are optional named two-dimensional vectors. Absence means no such physical stick, not `(0,0)`. Values are calibrated and normalized/clamped to `-1...1`, with positive x right and positive y up; no application dead zone or Joy-Con grouping rotation is applied. Calibration chooses the retained validated user/factory data and preserves the protocol's handed stick placement. Public constructors clamp finite coordinates and replace non-finite coordinates with zero.

Each `Switch2Trigger` separates `isPressed` (ZL/ZR report bit) from optional analog `travel`. Only GameCube supplies travel; it is the retained raw byte divided by 255, in `0...1`. Travel and click are independent. Do not infer a click from a nonzero travel value, and do not silently turn nil travel into a claim of an analog sensor.

`Switch2Battery.millivolts` is voltage, not percentage; zero/unavailable becomes nil. `estimatedCharge` is a rough clamped `0...1` voltage estimate using 3.30–4.15 V, not calibrated fuel state or battery health. Charge-state bits remain a raw UInt8. Current remains signed Int16 counts; positive indicates charging, but conversion to amperes is not qualified.

`Switch2Motion` exposes named accelerometer/gyroscope/magnetometer `Switch2RawVector3` values in signed 16-bit sensor-native counts. These are **not** calibrated acceleration, angular velocity, gravity-removed motion, world axes or orientation quaternions. Model/physical orientation determines axes. Retained research associates magnetometer counts with 0.15 µT/count, but the API deliberately exposes raw counts. IMU die temperature is the existing `25 + raw/127` Celsius estimate, not ambient temperature. A present all-zero sample does not prove that hardware sensing is active. Motion is nil when the selected configuration does not request it.

[Explicit motion calibration](motion.md) converts raw counts using host-supplied measured bias, gain and signed axis order. Acceleration output is in m/s² and retains gravity; angular velocity is in rad/s. No model-specific coefficients, sample timing, orientation fusion or SDL sensor registration are inferred. Raw state remains unchanged.

Joy-Con optical telemetry exposes UInt16 absolute x/y counters wrapping modulo 65536 and raw surface-quality/lift counts. These are not cursor pixels or millimeters. Compute wrap-aware deltas, interpret orientation in the host, and treat gaps/reconnects as a reset rather than a large pointer jump.

`receivedAt` is host monotonic seconds since boot, not controller time or a wall clock. `sequence` starts at one per physical connection; synthetic host values may use zero. `connectedAt` is host wall-clock readiness time. Do not compare monotonic times between machines or boots.

## Identity, metadata and capabilities

`Switch2ControllerID` wraps CoreBluetooth's locally scoped UUID, supports Codable restoration, and is potentially identifying data. It is not a serial, player slot or authentication proof. `connectionID` is a new transient token for each connection; do not persist it. Names are safe verified model labels; host custom names remain host state. Optional body/button colors contain eight-bit sRGB components, without alpha.

Serial numbers are nil by default. A legacy host can explicitly opt in through configuration to preserve existing serial-keyed mappings; the library still does not log them. `capabilities` describes understood physical-controller functions, not whether a game, browser or output adapter supports them. All models provide `.rumble` through `playRumble`. All models provide `.continuousRumble` (on/off for GameCube); GameCube also provides `.rumblePresets`. A paired Joy-Con grip is a host abstraction over two capability sets.

## Failure semantics

Parameter validation throws `invalidParameter` synchronously. Connection/handshake/timeouts, Bluetooth availability, absent sessions, unsupported operations and operation backpressure are typed events. Separate Bluetooth state from connection state, and distinguish an admitted attempt from first-report readiness. No public error contains raw frames, controller keys or arbitrary system error text.

All snapshot fields are immutable and Sendable. Manager presentation is main-actor isolated, commands enqueue transport work, and observations execute serially on a selected host queue. See the [delivery contract](concurrency-and-logging.md) for ordering, overflow and retirement rules; the public API intentionally makes no unbounded lossless-recording promise.
