# Independent Switch2Kit example

`Switch2KitDemo` imports the stable library, not the dashboard. `NavigationSupport` is a package-only example helper shared with tests; it is not a public Switch2Kit product.

Build with macOS/Xcode 26+:

```sh
swift build --product Switch2KitDemo
bash scripts/build-switch2kit-demo.sh
open build/Switch2KitDemo.app
```

Quit the dashboard or any other process owning the same controller. The bundled demo supplies its own Bluetooth usage description and ad-hoc signature. Allow Bluetooth, choose **Find Controllers for 60 Seconds**, and hold Sync. It shows Bluetooth/discovery, physical models, live buttons/sticks/triggers/battery, disconnect and supported short rumble.

Use arrows/Return/Escape or D-pad/A/B to navigate the nine-item grid. Release controls after focus/reconnect changes. Native GameController.framework snapshots are another input provider to the same semantic router. No synthetic global keyboard/mouse events, Accessibility approval or virtual HID device are involved. Inactive navigation is suppressed; stop/sleep/termination cancel host timers/monitors and retire library sessions.

See [navigation behavior and tests](../docs/switch2kit/navigation.md), [permissions](../docs/switch2kit/README.md) and [lifecycle](../docs/switch2kit/bluetooth-lifecycle.md). Physical radio/controller behavior is not established by a successful example build.
