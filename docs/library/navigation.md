# Semantic in-app navigation

The [compiled example helper](../../Examples/NavigationSupport/NavigationRouter.swift) is deliberately outside Switch2Kit's public product. Navigation is host policy, not controller transport. The [demo model](../../Examples/Switch2KitDemo/DemoModel.swift) supplies three adapters to one router:

```text
local NSEvent key changes ───────────┐
GameController.framework snapshots ├─ NavigationInput + source identity
Switch2Kit typed input events ───────┘             │
                                   NavigationRouter + monotonic clock
                                                  │
                                 up/down/left/right/activate/back
                                                  │
                                    application selection/actions
```

No adapter posts synthetic keyboard or mouse events. `activate` directly updates the application model; it is not a global Return key. This works without Accessibility approval or a virtual HID device.

## Input adapters

**Keyboard:** an AppKit local monitor handles arrows, Return/Space and Escape only within this application. It leaves unrelated keys, modified shortcuts and text-editor key-downs alone. The adapter tracks physical key codes, so releasing Space cannot release a simultaneously held Return. It suppresses native repeat for handled keys because the router owns repetition. Key-up releases a previously owned key even if focus/modifiers changed. On deactivation it clears ownership. The monitor is removed on stop/termination; there is no global monitor.

**GameController.framework:** the demo reads up to 32 native extended-gamepad snapshots on a main-thread 30 Hz timer, converting the D-pad, A/B and left thumbstick into the same semantic value. This is an independent input provider: it does not register Switch2Kit's devices as `GCController`. Snapshot polling bounds callback work; a production host requiring shorter native-controller taps may instead use a bounded native-event adapter. Do not open a competing CoreBluetooth connection for a controller already owned by another provider/process.

**Switch2Kit:** a retained `.main` observation delivers typed input through a capacity-256 mailbox. D-pad and A/B become direction/activate/back commands. The left stick is preferred, falling back to the right when a single right Joy-Con has no left stick. This is a sample choice, not a remapping rule in the library. Full-rate reports go directly to the router; no per-report `Task` is created.

## Edges, dead zones and repeat

The router's named `NavigationInput` has a semantic action set and a normalized stick. Positive x is right; positive y is up. An analog direction engages at magnitude **0.55** and releases below **0.35**, using hysteresis to avoid chatter. The helper accepts diagonals as two semantic directions, in fixed command order. Opposing directions cancel.

Direction commands emit on an edge, then repeat after **400 ms** and every **90 ms**. `activate` and `back` never repeat. `tick(at:)` takes host monotonic seconds. A stalled timer emits at most one repeat per held direction at its next tick; it does not replay a backlog. The host timer's cadence quantizes actual repeat delivery.

Sources are distinct (`keyboard`, native-controller UUID, Switch2Kit physical ID), with at most 64 admitted sources. Unioning their held controls prevents one source's release/disconnect from releasing another's held direction. Remove a disconnected source explicitly.

## Focus, reconnect and overflow

Navigation is enabled only when the demo is the active app and has a key window. Deactivation clears held/repeat state. After activation, a connection change or authoritative snapshot resynchronization, a source must be **neutral** before it can trigger actions. A button held while the app was inactive must not unexpectedly activate the newly focused UI.

The kit adapter tracks `connectionID` and `state.sequence`. A new connection token or a sequence gap resets that source. `.disconnected` removes it. `.snapshot` rebuilds identity/sequence bookkeeping and resets navigation rather than manufacturing an edge from an already-held button. This is important because bounded delivery intentionally discards history for slow consumers.

## Tests and extension points

`NavigationTests` exercises threshold boundaries, hysteresis, neutral arming, edge-only actions, timed repeats, timer stalls, opposing directions, multiple-source ownership, disconnection, focus resets, source-capacity rejection and adapter field mapping. These are deterministic model tests, not physical latency measurements.

To adapt this example, keep the semantic router separate from hardware providers and UI widgets. Change the command mapping or selection model in the host. For a different UI, implement actions such as moving focus, selecting a menu item or backing out of a view directly; do not translate navigation into synthetic global keyboard events.
