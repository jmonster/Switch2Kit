# Architecture

```text
Switch2KitApp ─────┐
Switch2KitDemo ────┼── Switch2Kit ── CoreBluetooth
Your application ─┘
```

## Library

`Sources/Switch2Kit/Public` defines physical controller snapshots, lifecycle events, bounded observations, and the manager API. `Bluetooth` owns the central and session state machines on one serial queue. `Protocol` owns advertisement validation, command framing, input decoding, and calibration. `Diagnostics` delivers bounded, privacy-conscious log records without file IO.

A controller becomes ready only after its handshake and first valid input report. Immutable snapshots cross the Bluetooth queue boundary. Each observation has a bounded mailbox and serial delivery on a host-selected queue. Overflow resynchronizes to current state; retired generations cannot send stale input or control commands to a replacement session. See [concurrency and logging](concurrency-and-logging.md).

## Dashboard

`Sources/Switch2KitApp` consumes the library through `Switch2KitAdapter` and `Switch2KitStateAdapter`. `BridgeEngine` assigns logical players, merges Joy-Con pairs, applies mappings, and routes output. It does not parse advertisements, decode reports, or own Bluetooth sessions.

The app owns its four-player policy, preferences, visualizers, optional outputs, permissions UI, and lifecycle. Library users do not inherit those dependencies or limits. NFC/audio tools live in `Sources/Switch2KitApp/Tools` and share package-scoped session hooks; the source library has no second companion product.

## Tests

`Tests/Switch2KitTests` covers public values, decoding, calibration, discovery, observations, diagnostics, and example navigation. `tests/session` and `tests/engine` exercise production state-machine methods using fake Bluetooth boundaries. `tests/application-adapter` covers state conversion, Joy-Con grouping, input release, resynchronization, and application lifecycle. Output suites test their respective adapters and wire protocols.

CI builds the package, example, dashboard, universal XCFramework, and independent source/interface consumers. Source-boundary checks enforce one production protocol/session/transport implementation and prevent application imports in the library.
