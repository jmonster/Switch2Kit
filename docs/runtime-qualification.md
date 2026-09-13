# Runtime checks

The package and application require macOS 15 or later. CI builds and runs the packaged loader on macOS 15 and 26, on both Apple Silicon and Intel. Each result records the actual OS patch, architecture, source revision and Xcode version.

```sh
bash tests/runtime-qualification/run.sh
bash scripts/build-app.sh
bash scripts/check-runtime.sh
```

`--runtime-check` validates bundle identity, source revision, architecture and minimum-version metadata, then exercises the report parser and endian helpers. It runs before application construction and exits without opening Bluetooth or output listeners. The wrapper checks the signature and compares package, plist and Mach-O deployment metadata.

The macOS 15 jobs select Xcode 26.3 explicitly. All code must remain available on the deployment target even when compiled with a newer SDK. CI artifacts identify the exact tested runtime and toolchain.

Test interactive behavior separately: first launch and Bluetooth permission, controller connection, button wake, sleep/wake, login registration and input in the intended application. Use the [hardware test workflow](hardware-evidence.md) to record those observations.
