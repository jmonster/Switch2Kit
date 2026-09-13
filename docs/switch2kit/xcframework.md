# Library distribution

Switch2Kit is distributed as SwiftPM source. The separate XCFramework build,
project generator, archive inspection, and binary-interface consumer pipeline
have been retired to keep one supported library-distribution path.

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
