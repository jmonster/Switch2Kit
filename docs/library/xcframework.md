# Building and consuming Switch2Kit.xcframework

Source SwiftPM integration remains primary. This optional build creates a real dynamic framework with Swift module interfaces; it does not relabel an arbitrary `.build` directory or replace the source target with a binary target.

## Prerequisites and build

Use macOS with full Xcode 26+ and Swift 6.2+. The script fails clearly on Linux, a Command Line Tools-only selection, an older compiler, or a missing macOS SDK. Select an installed Xcode with `DEVELOPER_DIR` when necessary. It does not choose signing credentials or modify your developer-directory selection.

```sh
bash /absolute/path/to/Switch2Kit/scripts/build-switch2kit-xcframework.sh
```

The script resolves its own repository root and works from any current directory. It generates a small framework-only Xcode project in an owned temporary directory under `build/`. The generator uses sorted `Sources/Switch2Kit/**/*.swift` paths, deterministic object IDs and an explicit shared scheme. There are no external project-generator dependencies. Only the stable target's sources are compiled; the dashboard, example and app controller tools are absent.

It runs `xcodebuild archive` for `generic/platform=macOS` with `ARCHS='arm64 x86_64'`, `ONLY_ACTIVE_ARCH=NO`, `SKIP_INSTALL=NO` and **`BUILD_LIBRARY_FOR_DISTRIBUTION=YES`**, then `xcodebuild -create-xcframework` with the archived framework and dSYM. This produces one universal native-macOS slice, not separate duplicate macOS platform entries. The deployment target is 15.0 for both architectures.

The framework's identifier is `org.switch2kit.framework`, not the dashboard's bundle ID. Code signing is disabled for this development artifact. No app entitlements, provisioning profile, signing identity, login item, updater or privacy Info.plist is embedded. The consuming host still supplies Bluetooth configuration.

## Outputs and verification

```text
build/
  Switch2Kit.xcframework/
    Info.plist
    macos-arm64_x86_64/
      Switch2Kit.framework/
      dSYMs/Switch2Kit.framework.dSYM/
  Switch2Kit.xcframework.zip
  Switch2Kit.xcframework.zip.sha256
  Switch2Kit-build.txt
  Switch2Kit-archive.log
```

The exact slice directory comes from Xcode's generated plist; scripts read that metadata instead of assuming it. Verification checks the framework name/identifier and native platform, compares advertised and actual arm64/x86_64 architectures with `file`/`lipo`, lints plists, inspects linked dependencies with `otool`, rejects app-only dependencies or signing material, and matches each binary UUID to its dSYM with `dwarfdump`. Both architecture-specific public `.swiftinterface` files must contain the public manager and must not expose raw peripheral/application types.

Only an archive that passes inspection is promoted to `build/Switch2Kit.xcframework`. The ZIP has a SHA-256 checksum and toolchain/source metadata. Xcode/build timestamps and Mach-O UUIDs can vary with toolchain/build environment; deterministic here means fixed source selection, explicit build settings and a repeatable standard build/verification process, not a promise of byte-identical ZIPs across Xcode versions. Generated products and wrapper projects stay under ignored build paths.

Run the independent integration checks:

```sh
bash scripts/verify-switch2kit-consumer.sh
```

That script creates a fresh temporary SwiftPM consumer importing only Switch2Kit. It also removes the copied compiled Swift modules and builds/links independent arm64 and x86_64 consumers from the textual interfaces, proving that the binary artifact is usable without access to the dashboard or same-toolchain module cache. The consumers do not open Bluetooth or claim hardware success.

## Add the framework to another Xcode application

Add `Switch2Kit.xcframework` to the host's target and choose **Embed & Sign** for the dynamic framework. Let Xcode select the macOS slice; do not manually copy an architecture-specific binary into source. Ensure the host's framework search/runpath settings remain appropriate for embedded frameworks (normally `@executable_path/../Frameworks`). Import `Switch2Kit` from host Swift code. Supply the host usage description, sandbox Bluetooth capability and permission UI exactly as with source integration.

The development XCFramework is unsigned. The host's signing/export pipeline signs its embedded framework using the host's own identity; the library build does not borrow the dashboard's credentials or restricted entitlements. Do not link both the source product and the binary framework into one application, because that duplicates the module/implementation. Source and binary integration are alternatives.

Standard mechanism: [Apple's multiplatform binary framework guide](https://developer.apple.com/documentation/xcode/creating-a-multi-platform-binary-framework-bundle).
