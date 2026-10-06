# Apple deployment and qualification

The source library declares iOS 17, tvOS 17, and macOS 14 as minimum deployment
targets. Swift 6.2 and Xcode 26 or newer are build-tool requirements, independent
of the operating system on which the host app runs. Linux and Windows retain
native `Synchronization.Mutex` and their existing radio backends.

The library uses Apple's `OSAllocatedUnfairLock`, available since iOS/tvOS 16 and
macOS 13. Its checked initializer, closure, and result retain compiler-enforced
Sendable boundaries. No raw lock pointers, unchecked state transfers, per-report
Tasks, or additional dispatch queues are introduced.

- [OSAllocatedUnfairLock](https://developer.apple.com/documentation/os/osallocatedunfairlock)
- [Checked state access](https://developer.apple.com/documentation/os/osallocatedunfairlock/withlock(_:)-1uy7m)
- [Synchronization.Mutex](https://developer.apple.com/documentation/synchronization/mutex)

## CoreBluetooth and bonding

The same manager, full-rate `observe(on:bufferingNewest:handler:)`, discovery,
stop, and cancellation APIs are available to iOS and tvOS source consumers.
Presentation snapshots remain coalesced separately from game input.

Only macOS imports IOBluetooth to obtain the local adapter address. CoreBluetooth
does not expose that address on iOS or tvOS. These platforms keep the existing
Sync-mode connection path and skip protocol bonding that requires the address;
they never write a fabricated address. This does not establish persistent bonding,
reconnection, controller pairing, background operation, or physical-controller
support on either mobile platform. Hosts provide their Bluetooth usage description.

## Optional dashboard

The macOS dashboard retains its macOS 15 minimum and existing packaging metadata.
Its CoreHID sink and SwiftUI launch behavior are availability-gated in source so
the package's lower library minimum does not apply those APIs to macOS 14 hosts.
The library and its independent source consumer do not link CoreHID.

## Validation required before support claims

Linux Swift 6 tests exercise the portable state and concurrency contracts, but
cannot validate Apple frameworks, deployment targets, or radio behavior. Before
shipping a lower-floor host, build the library and that host with Xcode for:

- macOS 14, including the intended Intel/Apple Silicon architectures
- iOS 17 device and simulator
- tvOS 17 device and simulator

Run `swift test -Xswiftc -warnings-as-errors` and
`bash scripts/verify-switch2kit-consumer.sh` on the Mac. Build the dashboard at
its existing minimum. Actual minimum-OS launches and physical controller tests
remain separate qualification; successful compilation is not evidence of pairing.
