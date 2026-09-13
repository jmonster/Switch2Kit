# Swift library distribution

Swift clients use Switch2Kit as SwiftPM source. The standalone Swift XCFramework build,
project generator, archive inspection, and binary-interface consumer pipeline
have been retired to keep one supported Swift integration path.

This does not retire the optional [C/C++ integration](cpp.md). Its dynamic
library, CMake integration, universal C ABI packaging, and fresh C/C++ consumer
checks remain supported. C/C++ hosts do not consume Swift textual interfaces.

Use the source package from Xcode or SwiftPM; see the [library guide](README.md)
for dependency setup and the host's Bluetooth usage description and sandbox
capability. Applications own their lifecycle and permissions. The source
library does not depend on the dashboard or CoreHID.

```sh
bash scripts/verify-switch2kit-consumer.sh
```

This builds an independent macOS source consumer with warnings as errors and
checks that it does not link CoreHID. It neither opens Bluetooth nor requires
a previously built framework. CI runs the same check.

Previously generated frameworks are not deleted from anyone's machine by this
change. Rebuild consumers against the source package; do not link a historical
framework and the source product into the same target.
