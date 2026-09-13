# Dashboard discovery

The dashboard starts in automatic discovery mode. **Controller Discovery** offers `quietWhenReady`, which pauses broad scanning once every remembered physical controller is ready.

Enabling this option opens a full 60-second setup window. Up to eight ready physical controllers are remembered locally while the option is enabled. The window stays open when the first controller connects, allowing both halves of a Joy-Con pair to join. Once the window closes, a missing remembered controller keeps scanning active; reconnecting the complete set pauses it.

Use **Find New Controllers for 60 Seconds** before holding an unfamiliar controller's Sync button. This replaces the current discovery window without interrupting connected controllers. **Use Only Currently Connected Controllers** closes the window and replaces the remembered set with the current ready set. It does not erase controller bonds or mappings. The reset control clears the set and restores automatic discovery.

Stop, sleep and Bluetooth teardown cancel discovery windows. Pending expiry callbacks cannot close a replacement window, and advertisements queued before scanning stopped cannot start new connections while discovery is paused. Connected controllers continue receiving input, keep-alives and output independently of scanning.

Library hosts choose their own discovery policy. See the [Bluetooth lifecycle guide](switch2kit/bluetooth-lifecycle.md) for on-demand discovery, connection states and reconnect handling.
