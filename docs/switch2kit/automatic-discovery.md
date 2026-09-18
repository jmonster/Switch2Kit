# Automatic discovery for native hosts

The C facade defaults to a finite, explicitly requested discovery window. That
is appropriate for manual pairing, but a controller that powers off and returns
after the window expires cannot be rediscovered until the host requests another
window. Pausing emulation does not extend that window.

A native host can now opt in with `s2k_set_automatic_discovery(context, 1)` and
then call `s2k_start(context)`. This selects the existing Swift `.automatic`
policy: supported advertising controllers can connect whenever the transport
has capacity, including after a long absence. It is not a known-device allowlist.
It does not pair arbitrary Bluetooth devices or change the host's port mappings.

Discovery is event-driven on the private Bluetooth queue. The host does not need
a timer that repeatedly calls `s2k_discover`, or to reopen its settings window.
The transport still serializes handshakes, uses duplicate-filtered scans, bounds
retry work and pauses discovery while connecting or at capacity. Continuous
scanning still uses radio resources; hosts should make this an explicit option.

The setter is idempotent, accepts only 0/1, and is serialized with lifecycle
commands. It does not start a stopped manager or consume input. Configuration
while asynchronous stop is finishing returns `S2K_BUSY`. The mode survives
stop/start on the same context. Destroy/create restores the off default; the
host owns saved preferences and main-thread creation.

Setting 0 returns to on-demand discovery without disconnecting ready sessions.
An already admitted handshake can finish. For an explicit Disconnect action,
call `s2k_stop` and keep the host's stopped-state fence: do not automatically
restart from an input poll, settings refresh or resume event. Only a deliberate
start, or a later application launch with prior user consent, should restart it.

The function is an additive ABI-v1 symbol; all existing structures and defaults
are unchanged. Hosts using it must pin/link a library revision that supplies it.
Existing C/C++ consumers that do not call it retain manual discovery behavior.

## Validation boundary

The regression suite checks argument validation through the C declaration,
radio-free configuration, live-session/input-reader preservation, stop/restart,
concurrent configuration and simulated long-absence policy behavior. These are
not physical Bluetooth tests. On a Mac, verify controller power-off/wake after
more than 60 seconds, repeated cycles, a paused game, Bluetooth off/on, two
controllers reconnecting in reverse order, and explicit Disconnect followed by
wake. Initial pairing, permissions and actual hardware availability still apply.
