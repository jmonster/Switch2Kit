# Bluetooth lifecycle and pairing semantics

## First connection: advertise with Sync

Own one `Switch2ControllerManager` in your host, attach an observation, call `start()`, then `try manager.discover(for: 60)`. Hold the controller's Sync button until its lights sweep. The library validates the complete Nintendo advertisement and connects directly with CoreBluetooth. It discovers services/characteristics, subscribes to command responses, reads identity and calibration, configures LEDs/features, performs the existing protocol bond when appropriate, subscribes to input, and waits for a valid input report.

`.connectionChanged(id, .connecting)` means only an admitted attempt. `.handshaking` means the link is open but is not yet usable. `.connected(controller)` and inclusion in `controllers` require **both the handshake and the first report**. An input-notification subscription alone is not readiness. Do not display a usable pad solely because a Bluetooth connection succeeded.

## Protocol bond is not normal macOS pairing

A Sync advertisement causes the retained application-level bond sequence. This is distinct from Bluetooth SMP pairing and from a normal device entry in Bluetooth Settings. The library does not initiate SMP pairing. Do not add an encrypted-characteristic/SMP pairing flow to try to make a Settings entry appear; that is not the protocol implemented here.

The protocol bond stores host material on the controller for subsequent button-wake advertising. The retained implementation queries the host Bluetooth address through IOBluetooth. When that address is unavailable it skips the bond operation rather than inventing an address; the current link can still work, but later button-wake behavior is not guaranteed. Use Sync again if needed. A successful bond command sequence emits a diagnostic without printing its address/key material. Skipping the sequence does not emit a separate bond-status event; absence of a completion log is not proof of failure, and connection readiness alone is not proof that a new bond was written.

No Settings entry is required as proof of this in-process connection. Converselyely, a Settings entry does not prove that a host owns a live Switch2Kit session. Only one process should try to own the controller at a time.

## Reconnect and discovery modes

For a previously protocol-bonded controller, try a normal button press while the host is scanning. The controller must actually advertise; the library does not remotely wake a silent device. Model/vendor validation applies equally to Sync and wake advertisements.

`onDemand` is the library default. It scans only inside a bounded request and leaves existing controllers active when the window ends. `automatic` is an explicit host choice for continued scanning; a bounded request does not override that mode's continuous behavior. The dashboard explicitly selects automatic mode by default, retaining its previous behavior.

`quietWhenReady` preserves the repository's ready-set policy. Entering it opens a full 60-second setup window, even when the first controller or first Joy-Con half becomes ready. Ready physical identities populate a bounded remembered set. Once the window ends, scanning pauses only when the remembered set is ready; a missing remembered unit resumes scanning. An unknown controller cannot join while scanning is paused. Open another window before Syncing it.

Supply saved IDs through configuration or `configureDiscovery(_:remembered:)`, and persist `currentSnapshot.rememberedControllers` yourself only with an appropriate user-facing choice. Switch2Kit never reads UserDefaults. The default physical resource bound is 16, configurable and clamped to 1–64; this is not a four-player policy. IDs are locally scoped, potentially identifying data, not serials or authentication credentials. `useOnlyConnectedControllersForDiscovery()` closes the window and removes missing IDs from that set without unpairing controllers.

## Power and permission states

Observe `bluetoothState` independently of discovery. `.unknown` can occur before a callback; `.resetting`, `.unsupported`, `.unauthorized` and `.poweredOff` must not be presented as an empty list of available controllers. A started manager remains logically started while Bluetooth is off; when power returns its selected discovery policy applies. Do not repeatedly recreate managers to trigger more permission prompts. The host provides its usage description, sandbox capability and explanatory UI.

The library reports typed errors without forwarding arbitrary platform error strings or persistent identifiers into logs. Show actionable host text such as enabling Bluetooth, granting this application's permission, opening a new discovery window or trying Sync. Inspect `.failure` and disconnection reasons rather than parsing log messages as API.

## Stop, disconnect, forget and termination

`disconnect(id)` retires a pending or ready attempt, clears its ownership and asks CoreBluetooth to cancel. A later valid advertisement may reconnect while discovery permits it. `forget(id)` additionally removes the ID from the library's local remembered set. Neither operation erases controller-stored bond material, removes a macOS pairing entry, or deletes the host's mappings/preferences. Remove persisted mappings separately when that is the intended user action.

`await manager.stop()` stops scanning, cancels windows/retry/deadline/keep-alive work, retires sessions and waits for transport teardown. It refreshes the observable presentation before returning. Repeated starts/stops are safe. A later start creates new session generations; a retired session cannot become active again. Callers that retained already-delivered immutable values still own those values, and a handler already executing may finish; no pending retired input is newly admitted to an observation.

The callback overload `stop(completion:)` runs completion off the Bluetooth queue. AppKit hosts can use `.terminateLater` and reply to termination on the main actor after completion. Do not block the main actor waiting on a semaphore. Manager deallocation also requests shutdown, but an explicit awaited stop gives the host a deterministic lifecycle boundary.

Switch2Kit has no workspace/menu-bar policy. The host listens for sleep and termination and decides what inactivity means. The sample stops on workspace sleep, restarts support on wake only when the user had it enabled, and uses on-demand discovery rather than silently scanning forever. Reopen discovery as needed after wake. The dashboard retains its existing suspend/resume and automatic-discovery policy.

## Retry and retirement safeguards

Only one connection attempt is admitted at a time while ready controllers continue streaming. Connection and handshake/first-report phases have deadlines; stale input triggers retirement. Cancellation ownership is retained until the terminal CoreBluetooth callback so an old callback cannot retire or revive a replacement. Remembered retry advertisements expire after ten seconds, backoff is bounded, retry storage is resource-limited, and stale expiry callbacks cannot close replacement discovery windows. A fresh Sync advertisement is preferable to repeatedly retrying an expired observation.

Tests drive these production methods with fake Bluetooth boundaries. They establish deterministic state-machine behavior, not radio timing, range, actual bonding or physical button-wake success.
