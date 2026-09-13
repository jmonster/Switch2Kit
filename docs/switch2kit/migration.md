# Dashboard migration and source ownership

The extraction starts at `c98a15c5673d6d2f989e166dfc1056f4480d5da1`, preserving the latest direct-rumble routing fixes. No developer's local checkout was accessed. [The initial audit](extraction-audit.md) records the source graph and original identity/provenance discrepancies.

## Source moves and splits

| Original application source | New owner / retained responsibility |
| --- | --- |
| `Protocol/Switch2Protocol.swift` | `Sources/Switch2Kit/Protocol/Switch2Protocol.swift`: one implementation of models, framing, decoding and calibration. Complete manufacturer admission is shared through `AdvertisementRecognition.swift`. |
| `Bluetooth/ControllerSession.swift` | `Sources/Switch2Kit/Bluetooth/ControllerSession.swift`: sole GATT/handshake/command/keep-alive/session implementation. Research-only session operations move to `Switch2KitExperimental`. |
| ControllerState declared in the old session | Public named immutable values in `Public/ControllerTypes.swift`; package-only legacy value in `Protocol/DecodedState.swift`, not a second decoder. |
| Physical lifecycle in `Bluetooth/BridgeEngine.swift` | `Switch2Kit/Bluetooth/ControllerTransport.swift`: sole central, retry/cancel/deadline/session owner. |
| `Runtime/DiscoveryPolicy.swift` | Pure scan/window policy in the kit, preference adapter still in the app. |
| `Logging/LogStore.swift` | Remains application-owned. New kit diagnostics have no files, singleton or preferences. |
| NFC/audio/research orchestration | `Sources/Switch2KitExperimental`, explicitly unsupported and opt-in. |

The remaining `BridgeEngine` imports Switch2Kit and Switch2KitExperimental. Its `ApplicationController` records contain immutable snapshots plus application bookkeeping, not `CBPeripheral` or mutable Bluetooth sessions. A bounded kit observation delivers events onto the **application output queue**, distinct from the Bluetooth callback queue. `receiveController`, `reconcile` and `accept` update those records; `Switch2KitStateAdapter` converts public fields into the existing output value shape. It does not decode protocol bytes or perform calibration again.

## Capabilities retained in the application

The dashboard still owns four logical players and its eight-physical-controller resource choice, player memory, Joy-Con links and merging, custom names, stick/button mappings, idle/pointer policy, player LED preferences, status/support UI, throttled visualizers, party-game/gesture interactions and output lifecycle. It explicitly opts into legacy serial access for existing mapping keys, without enabling serials in kit logs.

Keyboard/mouse event posting and Accessibility permission handling remain in the app. So do UDP/SDL, browser/WebSocket, RetroArch and optional CoreHID sinks. Stable in-process consumers need none of them. The existing app's selected outputs and four-player behavior must not become a limit on arbitrary kit consumers.

Dashboard rumble uses physical IDs and current connection generations. Supported HD-rumble operations go through the stable manager. A finite GameCube diagnostic and unsupported NFC/audio/haptic experiments use the separate companion. GameCube preset submission cannot promise duration-controlled cancellation or stable rumble support. Explicit audio captures still require a host-selected directory; no capture file is created merely by initializing the stable kit.

The app's sensor-profile environment variables stay in `ApplicationSensorPolicy.swift`, not the library. Profiles are passed explicitly to the experimental companion for future sessions. Serial-keyed preferences, login registration, updater, signing and restricted-entitlement checks do not move into Switch2Kit.

## Deliberate identity correction

The task requires **`wabisabi.ware.gamecubed`**. The inspected GitHub baseline instead contained `io.github.jmonster.switch2mac`; README and its identity guide named still different values. This PR explicitly corrects the app plist and the runtime/release validators to the requested identifier. It is not accurately described as an unchanged baseline identity.

The executable remains `FinallyTheControllerWorks`, and `scripts/build-app.sh` still creates **`Finally the Controller Works (jmonster).app`**. Signing identities remain explicit host inputs; profile-bearing builds require a matching supplied entitlement plist. Existing ad-hoc/Developer ID/notarization safeguards and disabled updater behavior remain in force. No signing identity, provisioning profile, notarization account or update feed is added.

Compared with an installation using the old GitHub identifier, macOS privacy approval, login registration and the application preferences domain may need to be established for the requested identity. Preferences are not silently migrated. Existing log and settings-archive directory names are intentionally retained to avoid rewriting stored files. No controller bond is deliberately erased because of this identity correction. See [application identity](../app-identity.md).

## Tests and enforcement

SwiftPM tests cover public values, full advertisement admission, protocol fields, calibration, discovery, bounded observations, retirement, diagnostics and example navigation. Retained session/transport suites compile the **production methods** with fake Bluetooth boundary types; fixture preparation changes imports/platform guards/access control, not their algorithm bodies. Pointer/idle/output assertions moved into an application-adapter suite rather than disappearing from transport tests.

`tests/application-adapter` checks all public state fields, every trigger byte, release conversion, Joy-Con merging, multiple controllers, authoritative resynchronization, terminal records and stop/sleep policy. Existing output, signing/update, SDL and packaging regressions remain. Source-boundary CI rejects duplicate production protocol/session/transport files and forbidden library imports/coupling. Independent source/binary consumers prove that a different target imports the stable API without the dashboard.
