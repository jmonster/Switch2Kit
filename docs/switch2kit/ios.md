# iOS package integration

The `Switch2Kit` library product can be imported directly by iOS/iPadOS 18+
applications built with Swift 6.2 or newer. No replacement manifest, copied
sources, SDL adapter, or macOS application target is required. Add this
repository as a Swift package dependency and select its `Switch2Kit` product.

The host app supplies `NSBluetoothAlwaysUsageDescription`, owns its controller
manager and observation, and stops or suspends input with its scene lifecycle.
See [the public API](api.md) and [delivery contract](concurrency-and-logging.md).

CoreBluetooth on iOS does not expose the local Bluetooth adapter address.
Address lookup therefore returns `nil`; the existing handshake skips the
address-dependent protocol bond rather than inventing one. Use explicit
`start()` / `discover(for:)` and the controller's Sync button. Automatic
button-wake reconnection is not promised. This is compile-supported,
experimental integration, not physical pairing/gameplay qualification.

The normal macOS CI lane also compiles the actual library for both iOS
Simulator architectures and the device SDK. Existing desktop tests and
transport behavior remain unchanged.
