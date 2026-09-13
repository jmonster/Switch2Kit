# Switch2Kit and the controller dashboard

**Switch2Kit** is a reusable source Swift package for discovering and using Nintendo Switch 2 controllers **inside a macOS application**. The existing **Finally the Controller Works (jmonster)** menu-bar dashboard remains buildable and consumes the library; its SDL, browser, RetroArch, keyboard/mouse and optional virtual-HID outputs remain application features.

**Library users: [Switch2Kit installation, permissions, examples and API](docs/switch2kit/README.md).**

> Redistribution rights are unresolved: an application-wide license has not been supplied. No license is invented by the extraction. See [provenance](docs/switch2kit/provenance.md) before distributing source or an XCFramework.

## Use Switch2Kit in your own application

Add this repository as a Swift package and select the **Switch2Kit** library product. SwiftPM source integration is primary. Import the library, retain one manager and a bounded observation, start support and request a discovery window. Your host supplies its own Bluetooth usage description, sandbox capability and permission UI. It does not need CoreHID or Accessibility permission for in-process controller use.

The supported protocol models are Switch 2 Pro Controller, both Joy-Con 2 units and the NSO GameCube controller. Joy-Con grouping and logical players belong to the host. Stable rumble covers established Pro/Joy-Con HD operations; GameCube presets and NFC/audio research are separated into the unsupported **Switch2KitExperimental** product.

```sh
swift package describe
swift build
swift test
bash scripts/build-switch2kit-demo.sh
bash scripts/build-switch2kit-xcframework.sh
bash scripts/verify-switch2kit-consumer.sh
```

Use macOS with Swift 6.2+ and full Xcode 26+ for Apple-SDK builds. macOS 15 is the declared deployment minimum. The [independent demo](Examples/Switch2KitDemo) displays live input and semantic UI navigation. The [distribution guide](docs/switch2kit/xcframework.md) explains the real universal arm64/x86_64 archive and interface checks. Build/test checks are not physical-controller qualification.

## Build and use the existing dashboard

Connecting a controller and getting its input into a game are separate steps. Start with [From installation to input in a game](docs/quick-start.md). Some historical guides use the GameCubed name; the actual app output remains **`build/Finally the Controller Works (jmonster).app`**.

```sh
bash tests/run.sh
bash scripts/build-app.sh
```

The dashboard needs an Apple SDK providing CoreHID to compile its optional output; the stable library does not link it. Development builds are ad-hoc signed, not notarized releases. Automatic updates remain disabled. The required dashboard bundle ID is **`wabisabi.ware.gamecubed`**; [identity and signing](docs/app-identity.md) explains the explicit correction from the inconsistent GitHub baseline and its privacy/preferences implications.

Successful macOS build checks provide a development-app ZIP, checksum and source revision. Extract the app and place it in Applications before loading its bundled browser extension. About shows the source revision and whether the build includes local changes.

## Choose an application output

| Intended consumer | Setup | Limits |
| --- | --- | --- |
| Compatible SDL3 game or emulator | [SDL bridge](sdl/README.md) | Requires the custom library; not a system-wide driver. Rebuild after changing patches. |
| RetroArch | [Network gamepad output](docs/retroarch-integration.md) | Disabled by default. No rumble return path; GameCube travel maps to digital L2/R2. Use a trusted network. |
| Chromium web game | [Browser bridge](browser/README.md) | Disabled by default. Allow the extension's exact ID and apply settings. No Safari/Firefox package. |

CoreHID virtual-controller output still requires Apple's restricted entitlement. Verify compatibility in the intended game rather than assuming a Bluetooth connection or build proves it. Run only one controller-owning bridge/host at a time. Switch2Kit does not make its devices system `GCController` instances or grant unrelated applications access.

The [Pro Controller guide](docs/pro-controller-support.md) covers input, calibration, rumble and output capabilities. NFC/headset audio remain experimental. The browser does not forward GameCube HD-motor commands; GameCube preset diagnostics still need hardware verification. Check analog travel and digital clicks separately.

## Testing and reporting

SwiftPM tests cover the stable API, decoding, discovery, bounded observations/logging and navigation policy. `bash tests/run.sh` retains the protocol, fake Bluetooth boundary and application/output suites. SDL regressions exercise the pinned driver; macOS checks build and verify app bundles, the framework and independent consumers. See [migration and test ownership](docs/switch2kit/migration.md).

Automated checks do not replace physical pairing/reconnection, sleep/wake, multiplayer, latency or real-game testing. Include source revision, macOS and controller firmware, transport/output path and observed behavior in reports. Review logs for sensitive data before sharing. Do not submit raw serials, bond material or experimental sensor/NFC/audio contents by default.

## Credits

See [CREDITS.md](CREDITS.md) for contributors and retained third-party notices. Those acknowledgments do not grant a new application-wide license.
