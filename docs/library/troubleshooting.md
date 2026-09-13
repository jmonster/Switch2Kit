# Troubleshooting

## Bluetooth permission or power

Check `bluetoothState`: `.unauthorized` means the host needs Bluetooth approval; `.poweredOff` means Bluetooth must be enabled. Supply `NSBluetoothAlwaysUsageDescription` in the host Info.plist and the sandbox Bluetooth capability when required. Check permission prompts using a correctly bundled app, such as the demo built by `scripts/build-switch2kit-demo.sh`.

## Controller does not appear

Call `start()` and open a discovery window. Hold Sync until the controller advertises. For a bonded unit, try a normal button press while scanning, then Sync. In quiet discovery mode, open a new window before adding a controller.

Admission requires the Nintendo company ID, vendor ID and a supported product ID. Names alone do not authorize a connection. Check the supported-model table and configured physical-controller limit. A connecting or handshaking event is not readiness: the handshake and first valid input report must both complete.

## Input appears in Dashboard but not another UI

Switch2Kit delivers input inside the process that owns its manager. Quit Dashboard before connecting the same controller from an independent host or the demo.

Retain the manager and observation token, start support, and handle `.input` on the intended queue. SwiftUI presentation is sampled around 10 Hz; use the bounded observation for button edges. Reconcile `.snapshot` events and clear held actions on disconnect, sequence gaps and replacement connection tokens. The navigation example requires neutral input after focus changes.

For game output, check the selected SDL library, browser extension, RetroArch endpoint or input mapping. Reconnecting Bluetooth does not repair an output configuration issue. The output-specific guides are linked from the root README.

## Competing processes

Use one owner per physical controller. Separate processes and managers do not coordinate ownership. Keep a shared application-level manager rather than constructing one per SwiftUI window. The navigation example consumes native GameController.framework devices separately from Switch2Kit devices.

## Reconnect and stale sessions

After cancellation, the library waits for the matching CoreBluetooth terminal callback before reusing the peripheral. Retry advertisements expire and discovery-window callbacks carry generation checks. Open another window or use Sync for a fresh advertisement.

Inspect typed connection states and errors. Diagnostics record phases, timeouts, input gaps and backpressure without raw identifying payloads. Reduce LED/RSSI/tool request frequency when the bounded operation queue fills. Input overflow requires snapshot reconciliation, not an unbounded event buffer.

For stalled input, clear host actions, await `stop()`, then start and request discovery. A replacement has a new `connectionID`. `forget` removes local remembrance; it does not erase the controller's stored bond.

## Rumble

All four supported models provide `.rumble`. Pro and Joy-Con also provide `.continuousRumble`: pulses honor 0.01–0.5 seconds, zero stops the motor, and continuous intent needs renewal before the 500 ms failsafe.

GameCube routes through the same API using firmware soft/strong clips. Its command has no duration or stop field. Zero submits no clip. The command lane must be idle, and at most two clips are admitted per second; busy requests emit `.operationQueueFull` rather than playing later. See [rumble](../rumble.md).

## Sensor values and reports

Motion/current/optical fields are raw sensor counts. Test analog trigger travel separately from digital clicks. Include the source revision, macOS version, model, firmware when known, discovery mode and typed lifecycle/error sequence in a problem report. Identify whether the failure is discovery, handshake, ongoing input, host UI or game output. Review diagnostics before sharing; omit serials, peripheral IDs, bond material and captures.
