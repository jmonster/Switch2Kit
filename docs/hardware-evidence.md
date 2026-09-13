# Hardware tests and power measurements

Create a local record and attach observations:

```sh
mkdir -p qualification
python3 scripts/hardware-evidence.py template > qualification/controller.json
python3 scripts/hardware-evidence.py --root qualification check controller.json
```

Fill `record.context` with the source revision, controller model and firmware, macOS patch, architecture, output and game build. Describe the workload, anonymous physical-unit label, instrument, calibration, warmup and radio conditions. Record actual pass/fail results under `record.checks`; leave unperformed checks as `not-run`.

For each pass or fail, `evidence[check]` names a local artifact and its hash:

```json
{"path": "observations/reconnect.txt", "sha256": "<SHA-256 of the file>"}
```

Paths are relative to the explicit root. Use `shasum -a 256 FILE` to obtain the hash. The validator checks file contents against the recorded hashes. Physical, simulation and packaged-runtime records remain separate.

## Instrumented power

Export each trial as UTF-8 CSV with increasing timestamps and these columns:

```text
time_seconds,power_watts
```

Use separate traces for the host and controller. Convert instrument units before exporting.

```sh
python3 scripts/hardware-evidence.py --root qualification trace traces/host-1.csv
```

The result contains a hash reference, duration, sample count, largest gap and time-weighted mean calculated by trapezoidal integration. Copy the mean and duration into `record.trials` and the reference into the matching `power_traces` entry under `host_watts` or `controller_watts`. Unmeasured metrics are null in both places. Validation recomputes the means and durations from the referenced traces.

```sh
python3 scripts/hardware-evidence.py --root qualification compare baseline.json candidate.json
```

Comparison requires passing behavior checks, identical declared context, at least three distinct equal-duration traces per setting, and one changed factor: sensor profile or discovery mode. The output reports descriptive differences; sampling gaps and instrument resolution still matter.

## Compatibility matrix

```sh
python3 scripts/hardware-evidence.py --root qualification matrix controller.json other.json
```

Rows include record kind, status, revision, model, firmware, OS, architecture, output/game, profile, discovery mode and record hash. Failed or incomplete observations remain visible. The tool writes JSON to stdout; redirect it to save a matrix.

## Limits and tests

Records are limited to 64 KiB, artifacts to 2 MiB, and one command's distinct-file snapshot to 32 MiB. Limits also include 256 matrix records, 100 trials per record, eight artifacts per behavior check, 100,000 samples per CSV and 24-hour traces. Paths are opened relative to the selected root without following symlinks. Invalid values, changed files, hash mismatches and unsupported file types are rejected.

`bash tests/hardware-evidence/run.sh` tests validation and arithmetic with synthetic fixtures. See [controller test records](acceptance-records.md) for behavior checks and [runtime checks](runtime-qualification.md) for packaged application testing.
