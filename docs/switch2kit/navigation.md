# Navigation and application control

The normal library exposes `Switch2ActionRouter<Action>` and the optional
`Switch2NavigationAction` vocabulary. The standalone demo uses that public API;
the old package-only `Switch2KitNavigationExample` module has been removed.
There is no second implementation of the navigation state machine.

The navigation preset maps D-pad and the first available stick to up/down/left/right,
A to activate and B to back. Axis engagement is 0.55, release is below 0.35,
and directional repeat starts after 400 ms and continues at 90 ms. Activate/back
are edge-only. Opposite directions suppress one another. All these mechanics
can be reused with the host's own named actions and bindings.

The router owns per-source input, aggregate pressed/released/repeated events,
controller-generation and sequence-gap recovery, and overflow resynchronization.
The host owns selection, command execution, focus and text-entry policy, its
monotonic clock, observations, and local input-provider lifetimes. It must process
returned releases when a context deactivates, a source disappears or bindings change.

`ActionRoutingTests` retains the prior navigation cases and adds custom bindings,
chords, analog-trigger/click separation, atomic rebinding, context releases,
controller overflow/generation handling, bounded metadata and 10,000 ordered reports.
The independent consumer build uses public declarations only.

See [application actions](actions.md) for the API contract and
[the demo](../../Examples/README.md) for the complete host.
