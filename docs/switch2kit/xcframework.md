# XCFramework

SwiftPM source integration is the default. For binary integration, build a universal dynamic framework with the same public API.

## Build

Use macOS, full Xcode 26+, and Swift 6.2+. The script works from any directory:

```sh
bash /path/to/Switch2Kit/scripts/build-switch2kit-xcframework.sh
```

Select Xcode with `DEVELOPER_DIR` when needed. The script generates a framework-only Xcode project under `build/`, archives with `BUILD_LIBRARY_FOR_DISTRIBUTION=YES`, and runs `xcodebuild -create-xcframework`.

The native macOS slice contains **arm64 and x86_64**, with deployment target macOS 15. It includes textual Swift interfaces and matching dSYMs. The framework identifier is `org.switch2kit.framework`; it contains no application entitlements or provisioning profile.

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

Generated projects and binaries stay in ignored build directories. Source selection, project IDs, and build settings are deterministic; archive timestamps can differ between builds.

## Verify

The build verifies native architecture slices with `file` and `lipo`, validates plists, inspects linked dependencies with `otool`, matches dSYM UUIDs with `dwarfdump`, and checks both public Swift interfaces. Only a verified archive is moved to the output path.

```sh
bash scripts/verify-switch2kit-consumer.sh
```

This creates a fresh source-package consumer, then removes compiled Swift modules from a framework copy and builds both architecture consumers against its textual interfaces. CI runs these checks and stores the framework, checksum, build metadata, and diagnostics as artifacts.

## Link in Xcode

Add `Switch2Kit.xcframework` to the host target's **Frameworks, Libraries, and Embedded Content**, selecting **Embed & Sign**. Xcode selects the macOS slice and signs the embedded framework with the host identity. Keep the default framework runpath, normally `@executable_path/../Frameworks`.

Import `Switch2Kit` from Swift code. Supply the host's Bluetooth usage description and sandbox capability as described in the [library guide](README.md#configure-the-host-application). Link either the source product or the binary framework, not both.
