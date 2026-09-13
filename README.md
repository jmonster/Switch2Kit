# Switch2Kit

Nintendo Switch 2 controllers on macOS. Use the Swift library in your application or run the Switch2Kit menu-bar app for controller setup, live input, mappings, and game output.

**macOS 15+ · Swift 6.2+ · Xcode 26+**

## Library

Add the source package and select the `Switch2Kit` product:

```swift
.package(url: "https://github.com/jmonster/Switch2Kit.git", branch: "main")
```

Import `Switch2Kit`, retain a `Switch2ControllerManager`, observe input, and open a discovery window. Pro Controller 2, left and right Joy-Con 2, and NSO GameCube controllers use one API for input, rumble, player LEDs, and connection management.

[Installation and examples](docs/library/README.md) · [API](docs/library/api.md) · [Bluetooth lifecycle](docs/library/bluetooth-lifecycle.md) · [SwiftUI](docs/library/swiftui.md) · [AppKit](docs/library/appkit.md)

The host supplies its Bluetooth usage description and sandbox Bluetooth capability. In-process input requires neither Accessibility permission nor CoreHID. Output mappings belong to the host; the library does not register a system `GCController`.

## App

```sh
bash scripts/build-app.sh
open build/Switch2Kit.app
```

Hold the controller's Sync button, choose **Find New Controllers**, and verify input in Dashboard. Set up the output used by your game:

| Output | Setup |
| --- | --- |
| SDL game or emulator | [SDL integration](sdl/README.md) |
| RetroArch | [Network gamepad](docs/retroarch-integration.md) |
| Chromium web game | [Browser extension](browser/README.md) |

[Quick start](docs/quick-start.md) · [Rumble](docs/rumble.md) · [App configuration](docs/app-identity.md)

## Build and test

```sh
swift build
swift test
bash tests/run.sh
bash scripts/build-switch2kit-demo.sh
bash scripts/build-switch2kit-xcframework.sh
bash scripts/verify-switch2kit-consumer.sh
```

The independent demo shows live input and local semantic navigation. The XCFramework includes macOS arm64 and x86_64 with textual Swift interfaces. SwiftPM source integration is the default.

[Development](docs/development.md) · [XCFramework integration](docs/library/xcframework.md) · [Troubleshooting](docs/library/troubleshooting.md)

## Repository

```text
Sources/Switch2Kit/          Controller library
Sources/Switch2KitApp/       Menu-bar app, output adapters, and controller tools
Examples/                   Independent demo and navigation router
Tests/Switch2KitTests/       Library tests
tests/                      Transport fakes and integration regressions
docs/                       User and developer guides
scripts/                    Build, packaging, and verification tools
browser/                    Browser integration
sdl/                        SDL patches and build tools
```

[Contributors](CREDITS.md)
