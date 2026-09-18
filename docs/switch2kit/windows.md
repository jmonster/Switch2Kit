# Windows x64 / WinRT

Switch2Kit connects Switch 2 Pro, NSO GameCube, and individual Joy-Con 2 controllers through Windows' native Bluetooth LE APIs. The transport feeds the existing controller session engine, C ABI, and in-process SDL3 adapter. It does not require a system virtual-controller driver, a separate dashboard, or a network bridge.

For games, start with the maintained [Dolphin](https://github.com/jmonster/dolphin#windows) or [Cemu](https://github.com/jmonster/Cemu#windows) fork. Their **Find Switch 2 Controllers** action owns discovery; their GameCube/Pro shortcuts apply recommended mappings. Use the controller-enabled fork build, not an ordinary upstream download.

## Requirements

Use x64 Windows with a working Bluetooth LE adapter and its Windows driver. Native ARM64, x86, cross-compilation, and Android are not supported by this implementation. Enable Bluetooth in Windows Settings. The application runs as a normal desktop process, not as administrator.

Source builds require the x64 Swift 6.2+ toolchain, CMake 3.24+, Ninja, Python 3, and Visual C++ tools with a Windows SDK. CI uses Swift **6.2.1**; use the matching runtime for those development downloads. Each emulator also needs its own build dependencies: Dolphin's current source requires Visual Studio 2026, while Cemu's helper uses its normal MSVC-compatible build. Follow [Swift's Windows installation instructions](https://www.swift.org/install/windows/).

The application-owned `Switch2KitC.dll` is copied next to the emulator. These development packages are **not self-contained**: install the matching Swift runtime and Microsoft Visual C++ runtime. They are not signed public releases. Do not disable SmartScreen, antivirus, or Bluetooth security to run them.

## Build the library or a native host

From the Switch2Kit checkout, in an x64 Visual C++ developer shell with Swift in `PATH`:

```powershell
swift test -Xswiftc -warnings-as-errors
swift build -c release --product Switch2KitC
```

For C/C++ applications, use the [CMake integration](cpp.md). Link `Switch2Kit::C`, then call `switch2kit_embed_windows(your_target)` in the CMake directory that creates that executable. CMake builds the native DLL and import library through SwiftPM. Do not link a second copy of the Swift engine into the host.

Creation does not start Bluetooth. Call `s2k_start`, request discovery, and hold the controller's **Sync** button while scanning. Close competing controller applications first. The C polling API does not rely on a Cocoa or Win32 UI event loop; application UI updates remain the host's responsibility. Stop input and wait for API callers to finish before destroying the context.

For a source-built program, the Swift toolchain reports its runtime locations:

```powershell
$target = swiftc -print-target-info | ConvertFrom-Json
$env:PATH = ($target.paths.runtimeLibraryPaths -join ';') + ';' + $env:PATH
# Launch the controller-enabled executable from this shell.
```

This changes only the current shell and child processes. The Windows emulator build helpers do the same lookup; no global `PATH` edit or replacement SDL DLL is needed.

## Connection and failure behavior

The backend uses active LE advertisements, the existing Nintendo manufacturer-data recognition, GATT service discovery, notifications, and bounded writes. It obtains the selected adapter's address for the existing controller-protocol handshake. Physical IDs remain stable for the adapter/device/address-type tuple; moving to another adapter or a rotating device address can change identity.

Connection tokens fence late callbacks and stale writes. Only one output write per controller is admitted at a time, and frames larger than the negotiated ATT payload are rejected rather than split. Overflow, service changes, notification failures, disconnects, and explicit stop invalidate affected input. The backend does not queue an unbounded stream of old rumble commands, silently alter pairing settings, or erase device bonds.

After an unavailable/denied radio state, restore Bluetooth or application access in Windows Settings, stop the backend, and use **Find Switch 2 Controllers** again. A missing Find button means the running app was built without Switch2Kit. A missing-DLL startup error is a runtime installation problem, not a pairing problem.

## Validation boundary

The Windows workflow compiles the production WinRT backend and shared Swift engine. Package tests exercise the real Windows adaptation layer against a controlled OS boundary. Native C and real SDL consumers separately check exported ABI/type metadata, creation without starting Bluetooth, input edges, mapping, bounded queues, rumble, calibration, and shutdown. Fork workflows build the full applications, relocate them, verify that they load their own controller DLL, and test normal window launch, quit, and relaunch.

A configured workflow is not a successful run until its checks pass. These tests do not claim physical Windows Bluetooth pairing, firmware compatibility, sleep/wake, measured motion, rumble on real hardware, or gameplay acceptance. Linux/macOS results are not substitutes for Windows hardware evidence. Record the OS, adapter/driver, controller firmware, source revision, controls, reconnect, and motor start/stop results during hardware qualification.
