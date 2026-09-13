# Application actions

`Switch2ActionRouter<Action>` turns controller input into host-defined commands.
It is part of the normal `Switch2Kit` library, not an application dependency or
a separate product. Keyboard/mouse injection and the dashboard's gesture/output
adapters remain optional application features.

## Bind your application's vocabulary

```swift
import Switch2Kit

enum Command: Hashable, Sendable { case previous, next, open, back }

var router = try Switch2ActionRouter(actions: [Command.previous, .next, .open, .back], bindings: [
    .init(.previous, from: .buttons(.dpadLeft)),
    .init(.next, from: .buttons(.dpadRight)),
    .init(.previous, from: .axis(.primaryX, positive: false)),
    .init(.next, from: .axis(.primaryX, positive: true)),
    .init(.open, from: .buttons(.a)),
    .init(.back, from: .buttons(.b))
], repeating: [.previous, .next], opposing: [[.previous, .next]])
```

The declaration order determines event order.
An application can use any `Hashable & Sendable` action type. Multiple bindings
may produce the same action; a multi-button mask is an all-buttons-required chord.
No preferences, physical-controller remapping or application commands execute
merely by constructing a router.

For standard navigation, use
`Switch2ActionRouter<Switch2NavigationAction>.navigation()`: D-pad/primary stick,
A for activate, B for back, directional repeat, and opposite-direction suppression.
`primaryX`/`primaryY` use the left stick when available, otherwise the right stick.
Trigger-axis bindings use analog travel only; bind `.buttons(.zl)`/`.buttons(.zr)`
for independent digital clicks. Missing analog travel does not fabricate a value
from a digital click. Existing continuous stick, motion and optical state remain
available directly for pointer or other analog interaction.

## Own the context; let the router own input mechanics

Keep one router on the host's actor or serial executor per input context.
Route the **full-rate** `Switch2ControllerEvent` observation, not the manager's
10 Hz presentation snapshot. For every callback, process
`router.receive(event, at: ProcessInfo.processInfo.systemUptime)` synchronously
on that executor. Do not add an unbounded per-report task queue.

Every result is a `Switch2ActionEvent` containing an action and a phase:
`pressed`, `released`, or `repeated`. Apply all releases even during focus loss,
stop, rebinding and source removal. A discrete navigation UI may explicitly ignore
release phases; a host maintaining held state must not. Releases precede presses
within a returned batch. Input from multiple sources aggregates: one controller
cannot release an action still held by another controller or a local key.

Call `setActive(true)` when the context acquires input focus. On focus loss, text
entry, a modal/context switch, stop or sleep, handle `setActive(false)` immediately.
It emits releases and clears held/repeat state; it does not stop Bluetooth. New
or reactivated sources must first report neutral mapped controls. A partially
held chord or a stick outside the release threshold does not count as neutral.

The event overload handles controller connect/disconnect, connection-generation
changes, report-sequence gaps and authoritative overflow snapshots. It releases
and rearms affected controller input without manufacturing presses from snapshot
contents. Overflow resets controller sources but does not release local keyboard
or other external ownership. Forward library events in their original order.

## Repeat, external providers and rebinding

Call `tick(at:)` from the existing host loop using the same monotonic clock.
Default repeat timing is 400 ms initially, then 90 ms. A delayed tick emits at
most one repeat per action rather than replaying a backlog. No worker, timer or
callback is created by the router. Invalid/backward timestamps release all state
and require neutral rearming.

Feed already-mapped local keys or gesture actions as a `Set<Action>` with a stable
`.keyboard` or `.external(UUID)` source. Independent providers need independent
source IDs. Hosts with normalized controller-style input can use the state
overload and the same bindings. External providers still own their sampling,
focus policy and disconnect detection; call `remove(source)` and process releases
when one disappears. The demo adapts native GameController input this way.

`replaceBindings` validates atomically, returns releases for the old mapping,
and requires neutral before the replacement is active. Invalid replacements
throw without changing the existing mapping or held state. Before replacing an
entire router, process `reset()` on the old instance. The host decides what each
action means, which view owns it, and whether mappings should be saved.

## Bounds and validation

A router admits 1–128 unique actions, up to 256 bindings, up to 64 opposing pairs
and 1–64 sources (64 by default). Excess sources are ignored without evicting
existing owners; `sourceCount` includes unarmed sources and controller metadata.
Remove retired sources to reclaim capacity. Unknown semantic actions are ignored.
Configuration errors throw `Switch2KitError.invalidParameter`.

Default stick/axis hysteresis engages at 0.55 and releases below 0.35. Thresholds
and repeat timing are configurable. All stored input/repeat state is bounded by
the declared actions, bindings and source count. No history or repeat backlog is
retained. These are synthetic-tested mechanics, not physical hardware validation.

See the [standalone demo](../../Examples/README.md) and
[SwiftUI host lifecycle](swiftui.md) for observation and context ownership.
