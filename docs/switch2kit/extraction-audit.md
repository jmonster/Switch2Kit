# Switch2Kit extraction audit

Baseline: `c98a15c5673d6d2f989e166dfc1056f4480d5da1` from GitHub, including the September 12 direct-rumble routing fixes. No developer's local working tree was used. The exact baseline was obtained from the `tested-source` artifact of macOS validation run `34710251916`; artifact SHA-256: `6f5823c986b609d6abdade39dd4532ec093d62e70edb55c7566f9c087d2702d0`.

This records the initial dependency/provenance audit. The implemented ownership boundary and explicit identity resolution are described in [migration](migration.md). Verification must refer to the exact PR head and CI results; this initial inventory is not hardware evidence.

## Identity discrepancy and explicit resolution

The requested identity is `wabisabi.ware.gamecubed`, but the baseline's `Resources/Info.plist` contained `io.github.jmonster.switch2mac` and named the application `Finally the Controller Works (jmonster)`. The build script used that app name. README and the prior identity guide instead described GameCubed and a third identifier, `io.github.switch2mac.gamecubed`. The requested `docs/fork-identity.md` did not exist in the baseline.

The implementation explicitly corrects the plist and runtime/release validators to the owner-requested `wabisabi.ware.gamecubed`, while retaining the actual app/executable names and signing/updater safeguards. This is not silently described as an unchanged baseline identity. Privacy approvals, login registration and preferences may differ for older installations; no preferences or controller bonds are silently migrated/erased. The new fork-identity guide points to the corrected authoritative [identity guide](../app-identity.md).

## Dependency and ownership inventory inspected before moving code

The original SwiftPM graph had one executable target and no dependencies. Its source-level graph crossed these boundaries:

| Sources | Controller-library responsibility | Application responsibility |
| --- | --- | --- |
| `Protocol/Switch2Protocol.swift` | Advertisement validation, model IDs, framing, identity/input decoding, calibration, motor packets | Remapping labels and experimental profile selection policy |
| `Bluetooth/ControllerSession.swift` | GATT discovery, correlated bounded command queue, ordered handshake, bonding, first-report readiness, calibration, state, keep-alive, terminal teardown | LED preferences must be passed by the host, not read from app defaults |
| `Bluetooth/BridgeEngine.swift` | Central, admission, deadlines, bounded retries, cancellation ownership, stale-input detection | Four logical players, eight-unit dashboard limit, Joy-Con links, settings/names, idle/pointer policy, sinks, games and visualizer |
| `Runtime/DiscoveryPolicy.swift` | Ready-set and replaceable-window state machine | UserDefaults keys, persistence and settings UI |
| `Logging/LogStore.swift` | Independent bounded diagnostic interface instead of moving this file | Dashboard presentation, explicit file persistence and rotation |
| `Output/*` | None | CoreHID, UDP, browser/WebSocket, RetroArch, keyboard, mouse and gestures |
| Other runtime/UI/app files | Immutable controller values are inputs only | Lifecycle, permission UI, settings/support, qualification, updater and login registration |

NFC/audio/research operations crossed the old engine/session boundary. They are now in the separately named, unsupported Switch2KitExperimental product, sharing the single session through package-only hooks. Stable Switch2Kit has no application preferences, required file logging, UI/output dependency or required singleton.

## Invariants retained and exercised

Advertisement admission validates Nintendo company/vendor/product, not a name. Command-response subscription precedes commands; identity precedes actuator choice; readiness requires handshake and an actual input report. Commands remain atomic, correlated, FIFO and bounded. Cancellation retires before requesting asynchronous radio cancellation; terminal callbacks release peripheral ownership. Retry caches and timers are bounded. GameCube never receives Pro/Joy-Con HD-motor packets.

Retained regressions compile production methods against fake Bluetooth boundaries rather than tests of reimplemented algorithms. New public-value, observation, diagnostic, operation-ingress and navigation tests exercise the extraction seams. Application pointer/idle/grouping/output assertions remain in an explicit adapter suite. See the migration guide and CI for commands/results; none of this is a physical-controller validation claim.

## Redistribution blocker

CREDITS says an application-wide license was not supplied and acknowledgments do not grant permission or relicense contributed code. The upstream tree and repository metadata likewise did not establish an application-wide grant. Research-project licenses alone do not license the separate Swift implementation. All notices are retained; no license is added or claimed. See [provenance](provenance.md) for the inspected sources and unresolved release gate.
