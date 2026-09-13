# Development

Build Apple-platform targets with Xcode 26+ and Swift 6.2+. The deployment minimum is macOS 15.

```sh
swift package describe
swift build
swift test -Xswiftc -warnings-as-errors
bash tests/run.sh
python3 scripts/switch2kit/check-boundaries.py
```

`Tests/Switch2KitTests` covers public values, decoding, calibration, discovery, bounded observations, logging, and navigation. The `tests` runner adds fake-Bluetooth session/transport tests and application/output regressions. It compiles production methods against fakes rather than maintaining a second implementation. Hardware is not opened by the automated tests.

Build the applications and distribution artifact:

```sh
bash scripts/build-app.sh
bash scripts/build-switch2kit-demo.sh
bash scripts/build-switch2kit-xcframework.sh
bash scripts/verify-switch2kit-consumer.sh
```

CoreBluetooth and mutable sessions belong to the library's serial transport queue. App policy, output adapters, and NFC/headset tools belong to `Switch2KitApp`. Keep the library free of application preferences, output frameworks, and UI types. The boundary check enforces source ownership and unique protocol/session implementations.

CI builds both applications, checks Swift 6 concurrency, runs regressions, builds the universal framework, imports it from fresh consumers, and runs packaged loader checks on arm64 and Intel. Controller pairing, radio timing, and motor response require separate hardware tests.
