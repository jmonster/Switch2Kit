# Troubleshooting in-process controller support

## Bluetooth permission or power

Inspect the manager's Bluetooth state, not just its ready-controller list. `.unauthorized` needs a host permission explanation and the appropriate macOS privacy settings; `.poweredOff` needs Bluetooth enabled. A usage string belongs in the host Info.plist, and a sandboxed host supplies its own Bluetooth entitlement where required. A library cannot grant those permissions or provide another app's privacy identity.

Run a correctly bundled application when checking a privacy prompt. The sample build script creates that bundle. Repeatedly constructing managers or reinstalling output adapters does not repair denied Bluetooth permission. After the dashboard's explicit bundle-ID correction, approval for an older identifier is not evidence that the requested identifier is approved. Do not disable macOS security controls as a troubleshooting step.

## Controller does not appear

Start support and open a discovery window. The default library manager does not scan indefinitely. Hold Sync until the controller advertises; a silent controller cannot be discovered from a saved UUID alone. In quiet discovery, an unfamiliar controller cannot join while scanning is paused. Open another bounded window. For a previously bonded unit, try a normal button first while scanning, then Sync if it does not advertise.

Advertisement admission rejects the wrong company, vendor, product or truncated payload. It does not trust a Nintendo-like name. Check the model support table and the host's physical resource limit. A `connecting` or `handshaking` event is not first-report readiness. Connection failures and first-report timeouts retire attempts instead of leaving stale dashboard entries indefinitely.

## Dashboard receives input but the host UI does not

Connection and consumption are separate checks. The kit enables input only in the process that owns its manager; the dashboard does not grant another application controller access. Quit the dashboard before independently connecting from the demo/host. Merely importing Switch2Kit does not cause events to reach arbitrary views.

Verify that the host retains its manager and observation token, starts support, registers the correct queue handler and handles `.input`. SwiftUI presentation is sampled around 10 Hz; use the bounded observation for short button edges. Do not create an unbounded `Task` per input event. Handle `.snapshot` resynchronization and clear held state on disconnect, sequence gaps and new connection tokens. A local navigation router should require neutral controls after focus changes, as the sample does.

For the dashboard's SDL/browser/RetroArch/keyboard/optional virtual-HID outputs, use their separate setup guides. A working kit connection does not prove that a game has the correct SDL library, extension permissions, network endpoint, mappings or restricted HID entitlement. Do not repeatedly bond a controller to fix an output-only configuration problem.

## Competing owners

Run only one controller-owning bridge/sample/host at a time. Multiple independent managers are legal for isolated owners, but they do not coordinate ownership across processes and can compete for the same device. SwiftUI window duplication must not accidentally construct another manager. Keep one application-level coordinator and share its immutable state with views.

A native GameController.framework input provider is another adapter, not a promise that the same Nintendo device is simultaneously available through both APIs. The example polls native controller snapshots separately and never synthesizes a native controller from a kit snapshot.

## Reconnect, stale sessions and command failures

A controller that disconnects during a handshake may leave a pending CoreBluetooth cancellation. The library waits for the matching terminal callback before reusing that peripheral; bypassing this guard can let a late callback corrupt a replacement. Cached retry advertisements expire, and quiet-window expiry callbacks are generation-checked. Reopen discovery or re-enter Sync to obtain a fresh advertisement rather than forcing reuse of an old attempt.

The library's safe diagnostics report lifecycle phases, timeout/gap events, bond completion/skip and backpressure without dumping identifying payloads. Track typed connection states and error reasons in the host; logs are diagnostics, not a stable parsing interface. `operationQueueFull` means the host issued more than 128 pending transport operations, such as LED or signal-strength requests; reduce request frequency. Input/log overflow likewise calls for a faster or coalescing host consumer, not a larger unbounded queue.

If input stalls, stop support, clear the host's held actions, await teardown, then start and request discovery again. A replacement uses a new `connectionID`. Never cache mutable session references; none are public. `forget` removes local remembrance, not the controller's stored bond or an operating-system pairing record.

## Rumble and sensors

Use `playRumble` for short feedback on any model. GameCube plays device-timed soft/strong clips rather than duration-controlled HD effects. Check `.continuousRumble` before using `pulseRumble` or `setRumble`. A busy radio, occupied command lane or repeated feedback within 500 ms produces `.operationBusy`; retry only after the current action finishes. Old queued commands cannot operate on a replacement connection.

Raw motion/current/optical values are not calibrated SI quantities. Zero is not proof of a sensor being enabled. Analog trigger travel and digital clicks must be checked separately. Report model and firmware along with the failing field; do not label synthetic decoder tests as hardware validation.

## Useful problem reports

Include the source revision, host macOS/toolchain, physical model and firmware when known, discovery policy, whether Sync or button wake was used, and the typed lifecycle/error sequence. Describe whether failure is discovery, handshake/first report, ongoing input, host UI or a dashboard output adapter. Review logs before sharing; do not include raw serials, peripheral IDs, advertisements, bond keys, tag contents or sensor/audio captures by default.
