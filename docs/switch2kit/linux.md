# Linux / BlueZ

The experimental Linux backend runs the existing Switch2Kit controller engine against BlueZ's system D-Bus GATT API. Swift hosts use `Switch2ControllerManager`; native hosts use the same `Switch2KitC` ABI and in-process SDL3 adapter as on macOS. It is a real radio implementation, not a fixture-only factory or a network bridge. Windows and Android are not implemented by this backend.

## Requirements and connection

Build with Swift 6.2 or later on a supported glibc Linux distribution. Native hosts also need CMake 3.24+, a C/C++ compiler, and their normal dependencies. Runtime requires compatible Swift libraries, `libsystemd.so.0` (the sd-bus client library), a running BlueZ service, and a powered LE-capable adapter. The system itself need not use systemd as PID 1. The GATT characteristic `MTU` property must report a sufficient negotiated ATT MTU for complete controller commands; missing MTU uses the conservative 20-byte write limit rather than guessing or splitting protocol frames.

```sh
swift build --product Switch2KitC
swift test -Xswiftc -warnings-as-errors
```

Create the manager on the main actor, or call `s2k_create` on the main thread. Creation does not open the radio. Start support, request discovery, then hold Sync on the controller. The C polling API does not need a Linux GUI event loop; Swift hosts using main-actor presentation snapshots must keep their executor running. Combine/SwiftUI and the dashboard remain macOS features; use observation or `currentSnapshot` on Linux.

The process uses the normal system-bus address and BlueZ permissions. It does not change adapter power, install permissive D-Bus rules, invoke `sudo`, call BlueZ `Pair`/`RemoveDevice`, or erase stored device bonds. A denied bus or GATT operation is reported rather than bypassed. Nintendo's existing controller-protocol bond handshake is separate from operating-system pairing; on Sync discovery it uses the selected adapter's address. Stop another application's connection before claiming the same controller.

The first powered adapter is selected deterministically; an already-selected powered adapter is retained. Selection is automatic in this initial backend, not a public adapter-selection API. An adapter reset closes the current manual discovery window; request discovery again on the replacement adapter. A Bluetooth daemon restart invalidates connections and refreshes the object model. After a system-bus failure, resolve the underlying service/access problem and stop/start the manager.

## Ownership, identity and bounds

Native asynchronous D-Bus calls and notifications run on the existing serial Bluetooth queue. The existing handshake, input parser, motion profiles, rumble expiry, event hub and connection-generation checks are reused. No controller protocol is reimplemented in the BlueZ binding. Notification delivery is event-driven, not a subprocess or a fixed-rate polling loop.

Only fresh, recognized Nintendo manufacturer data observed during discovery admits a controller. Cached startup objects and already-connected devices are not silently claimed. Discovery sessions and connections are released explicitly. Cancellation fences delayed replies; teardown clears published input before releasing the radio. Disconnect completion can follow the API's logical stop boundary.

Physical IDs are name-based UUIDs of the adapter address, remote address type and remote address. They are stable across reconnects with that tuple, without a new settings file. They are not a cryptographic anonymization guarantee. A different adapter or rotating device address changes identity; migration from macOS CoreBluetooth IDs is not automatic. Connection IDs still change on every reconnect.

Writes are bounded to one outstanding D-Bus write per physical device and the characteristic's negotiated write limit. Existing motor coalescing and expiry remain authoritative; the adapter never accumulates a separate queue of old motor packets. D-Bus parsing, object storage, pending requests and service enumeration are bounded. Services, notification loss and radio changes retire the affected connection rather than retaining held input.

## Native emulators and installation

Follow the [Dolphin/Cemu source integration guide](../../Integrations/Emulators/README.md), using Linux dependencies instead of Xcode, Homebrew or MoltenVK. Both optional patches accept Linux with SDL enabled; Dolphin also requires Qt. The build helper selects Linux arguments and retains macOS bundle behavior on Apple hosts. The emulator owns the same discovery UI and controller lifecycle; no dashboard is required.

```sh
bash scripts/build-switch2kit-emulator.sh dolphin /path/to/patched/dolphin /path/to/build
cmake --install /path/to/build --prefix /path/to/install
```

`switch2kit_install_linux(target)` installs the C library and attribution notices and adds the relative library directory to the host's install RPATH. Host executables must be installed into `CMAKE_INSTALL_BINDIR`; the supplied integrations do so. Build-tree executables use CMake's normal build RPATH. The installation is **not a self-contained Linux app bundle**: compatible Swift runtime libraries and system dependencies must remain discoverable by the loader. A package maintainer must declare those dependencies or supply an appropriate runtime deployment; copying only the emulator executable is insufficient. `switch2kit_embed` remains the macOS bundle helper.

## Verification and hardware boundary

`bash tests/linux-bluez/run.sh` starts a private D-Bus daemon and synthetic BlueZ service, then exercises the actual Linux library through an independent C++ consumer. It covers all four controller models, full session handshakes and adapter-address bonding, button edges, raw motion, analog trigger data, motor writes, stable identity/reconnect, stale handles, ownership, permission failures, missing services, write limits, cancellation, invalidation and malformed input. It does not touch the system Bluetooth service or a physical controller. Python is only a test dependency.

The Linux workflow runs package, radio, retained portable and real-SDL tests and builds the pinned Dolphin application. A configured CI job is not a successful run until its results are checked. Full Linux Cemu execution, controller firmware/radio compatibility, measured motion, physical rumble and gameplay still require hardware qualification. Record Linux distribution/kernel, BlueZ version, adapter, controller model/firmware, source revision, input, reconnect and motor start/stop observations; do not relabel an existing macOS acceptance record as Linux evidence. Linux source/fixture success is not proof of those outcomes; retain the existing [hardware acceptance procedure](../hardware-evidence.md).

The existing [motion calibration tool](../../tools/motion-calibration/README.md) can discover and capture through this backend. The Linux path uses the same C reader, freshness checks and operator-supplied measurements; it does not supply premeasured profiles.
