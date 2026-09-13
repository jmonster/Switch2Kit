# Sensor profiles

The dashboard selects one sensor profile for feature initialization and enablement during each connection. The default `compatibility` profile enables all available sensors. Other profiles select only the sensors needed by a workload.

| Profile | Joy-Con mask | Other models | Sensors |
| --- | --- | --- | --- |
| `compatibility` | `0xB7` | `0xA7` | Motion, magnetometer, battery, optical sensor where present |
| `gamepad` | `0x23` | `0x23` | Battery |
| `motion` | `0x27` | `0x27` | Motion and battery |
| `pointer` | `0x33` | `0x23` | Battery and optical sensor where present |

Buttons, sticks and triggers remain available with every profile. A profile applies at the next connection. Outputs that need an omitted sensor will not receive it.

Quit other running copies and launch a selected profile:

```sh
SWITCH2KIT_ACKNOWLEDGE_UNQUALIFIED_POWER=1 \
SWITCH2KIT_EXPERIMENTAL_SENSORS=gamepad \
'build/Switch2Kit.app/Contents/MacOS/Switch2KitApp'
```

Both environment variables are required; an unknown profile or missing acknowledgment selects `compatibility`. Launch normally to restore the default. Add `--sensor-profile` to print the resolved profile, model masks, requested sensors and source revision, then exit without opening Bluetooth.

Measure profiles on the same controller, firmware, OS, output and workload. Record host and controller power separately, with active input, idle input, held controls, rumble, reconnect and sleep/wake checks. See [test records](acceptance-records.md) and [instrumented comparisons](hardware-evidence.md).

`bash tests/power-profiles/run.sh` verifies the model masks and handshake frames using fake Bluetooth boundaries. Actual sensor availability and power consumption are measured on the device.
