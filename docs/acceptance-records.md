# Controller test records

Create a structured record for a Bluetooth controller test:

```sh
python3 scripts/check-acceptance.py template > baseline.json
python3 scripts/check-acceptance.py check baseline.json
python3 scripts/check-acceptance.py compare baseline.json candidate.json
```

Fill the template with the source revision, model, firmware, macOS patch, architecture, output, game build and test conditions. Use an anonymous label for the physical unit. Include workload, sensor profile, discovery mode, connection count, power/display state, radio conditions, warmup and measurement instrument.

## Behavior

Record pass, fail or not-run for initial connection, button wake, reconnect, sleep/wake, multiple controllers, active input and held input. Exercise reconnection while other controllers remain active. Record rumble, pointer, trigger travel and digital trigger clicks when supported by the selected model and output. Use not-applicable only for an actual model/output limitation, with an explanation.

The validator checks completeness, recognized fields and values, finite measurements, file size and duplicate JSON keys. Incomplete records can be saved; comparisons require completed behavior checks without failures.

## Power

Use at least three independent, equal-duration trials for each setting. Store average `host_watts` and `controller_watts` separately, with null for an unmeasured metric. Keep the physical unit, source revision, declared conditions and trial durations identical between baseline and candidate. Separate idle, active-input, rumble and pointer workloads.

The comparator reports means, ranges and differences for each measured metric. A zero baseline has no percentage difference. These are descriptive measurements, not battery-life estimates.

For local artifacts with SHA-256 verification, CSV power traces and generated matrices, use the [hardware test workflow](hardware-evidence.md). The scripts process supplied records and write results to stdout; they do not collect controller data.
