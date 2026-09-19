# Windows x64 / WinRT

Switch2Kit connects Switch 2 Pro, NSO GameCube, and individual Joy-Con 2 controllers through Windows' native Bluetooth LE APIs. The transport feeds the existing controller session engine, C ABI, and in-process SDL3 adapter. It does not require a system virtual-controller driver, a separate dashboard, or a network bridge.

For games, start with the maintained [Dolphin](https://github.com/jmonster/dolphin/blob/041a158aea44abb8b9625ce3359b8c231ad931da/Readme.md#windows) or [Cemu](https://github.com/jmonster/Cemu/blob/9a8a563c93791634bc2a5288fde885a25fbcddd4/README.md#windows) fork. Their **Find Switch 2 Controllers** action owns discovery; their GameCube/Pro shortcuts apply recommended mappings. Use the controller-enabled fork build, not an ordinary upstream download.

## Requirements

Use x64 Windows with a working Bluetooth LE adapter and its Windows driver. Native ARM64, x86, cross-compilation, and Android are not supported by this implementation. Enable Bluetooth in Windows Settings. The application runs as a normal desktop process, not as administrator.

Source builds require the x64 Swift 6.2+ toolchain, CMake 3.24+, Ninja, Python 3, and Visual C++ tools with a Windows SDK. The Windows CI matrix builds with Swift **6.2.1** on Windows Server 2022/Visual Studio 2022 and **6.3.3** on the Visual Studio 2026 runner. These are build/consumer test environments, not physical-controller qualifications. Each emulator also needs its own build dependencies: Dolphin's current source requires Visual Studio 2026, while Cemu's helper uses its normal MSVC-compatible build. Follow [Swift's Windows installation instructions](https://www.swift.org/install/windows/).

Hosts using the CMake embedding helper package `Switch2KitC.dll` and its compiler-selected Swift runtime dependencies next to the executable, together with the required Swift/ICU license texts and Switch2Kit notices. Keep those files together when extracting or moving the application. A successfully staged package does **not** require the Swift compiler installation or a Swift-specific `PATH` setting to launch.

Windows system libraries, the Microsoft Visual C++ runtime, and Bluetooth/graphics drivers remain prerequisites; this is not a promise of a fully self-contained application. The development artifacts are not signed public releases. Use only a controller-enabled application artifact whose native build and extracted-package checks succeeded for the same revision; source and diagnostic archives are not applications. Do not disable SmartScreen, antivirus, or Bluetooth security to run them.

## Build the library or a native host

From the Switch2Kit checkout, in an x64 Visual C++ developer shell with Swift in `PATH`:

```powershell
swift test -Xswiftc -warnings-as-errors
swift build -c release --product Switch2KitC
```

For C/C++ applications, use the [CMake integration](cpp.md). Link `Switch2Kit::C`, then call `switch2kit_embed_windows(your_target)` in the CMake directory that creates that executable. CMake builds the native DLL and import library through SwiftPM. Do not link a second copy of the Swift engine into the host.

Creation does not start Bluetooth. Call `s2k_start`, request discovery, and hold the controller's **Sync** button while scanning. Close competing controller applications first. The C polling API does not rely on a Cocoa or Win32 UI event loop; application UI updates remain the host's responsibility. Stop input and wait for API callers to finish before destroying the context.

`swift build` alone produces the library and import library, not an application package. The embedding helper resolves the DLL dependency graph and copies only the selected runtime files into the host output directory. It stops at resolved Windows system DLLs, and fails the build for missing or ambiguous non-system dependencies; it does not hide missing DLLs by adding directories to a user's global `PATH`.

Runtime-license selection is provided for Swift 6.2.1 and 6.3.3. For another distribution, supply its complete license and ICU third-party notices using `SWITCH2KIT_SWIFT_LICENSE` and `SWITCH2KIT_RUNTIME_ICU_LICENSE`. Offline packagers can preseed the verified license cache described in `Integrations/CMake/RuntimeNotices.cmake`. Do not omit the notices to work around a staging failure.

## Connection and failure behavior

The backend uses active LE advertisements, the existing Nintendo manufacturer-data recognition, GATT service discovery, notifications, and bounded writes. It obtains the selected adapter's address for the existing controller-protocol handshake. Physical IDs remain stable for the adapter/device/address-type tuple; moving to another adapter or a rotating device address can change identity.

Connection tokens fence late callbacks and stale writes. Only one output write per controller is admitted at a time, and frames larger than the negotiated ATT payload are rejected rather than split. Overflow, service changes, notification failures, disconnects, and explicit stop invalidate affected input. The backend does not queue an unbounded stream of old rumble commands, silently alter pairing settings, or erase device bonds.

After an unavailable/denied radio state, restore Bluetooth or application access in Windows Settings, stop the backend, and use **Find Switch 2 Controllers** again. A missing Find button means the running app was built without Switch2Kit. A missing-DLL startup error is a packaging or runtime-prerequisite problem, not a pairing problem. Re-extract the entire controller-enabled artifact and check its native CI result; copying only the executable or `Switch2KitC.dll` is insufficient.

## Validation boundary

The Windows workflow compiles the production WinRT backend and shared Swift engine. Package tests exercise the real Windows adaptation layer against a controlled OS boundary. Native C and real SDL consumers separately check exported ABI/type metadata, creation without starting Bluetooth, input edges, mapping, bounded queues, rumble, calibration, and shutdown. Fork workflows build the full applications, relocate them, verify that they load their own controller DLL, and test normal window launch, quit, and relaunch.

A configured workflow is not a successful run until its checks pass. These tests do not claim physical Windows Bluetooth pairing, firmware compatibility, sleep/wake, measured motion, rumble on real hardware, or gameplay acceptance. Linux/macOS results are not substitutes for Windows hardware evidence. Record the OS, adapter/driver, controller firmware, source revision, controls, reconnect, and motor start/stop results during hardware qualification.
