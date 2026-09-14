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

## Public application-action acceptance

Check [the recorded matrix](hardware-matrix.json) first. An empty matrix is no physical evidence; synthetic tests and CI builds are not gameplay or controller qualification. Use an actual host of the [public action router](switch2kit/actions.md), not only the dashboard visualizer. On a suitable Mac, the existing demo is the starting host:

```sh
# From the repository root; quit other controller-owning hosts first.
git rev-parse HEAD
sw_vers
uname -m
bash scripts/build-switch2kit-demo.sh
open build/Switch2KitDemo.app
mkdir -p qualification/observations
python3 scripts/hardware-evidence.py template > qualification/action-router.json
```

Record the exact revision, model, firmware when available, macOS patch, architecture and host application/build. Use `game_build` for the host build and `conditions` for its action mapping, discovery policy and actual session duration. This schema's `output` field describes external adapters only: leave it null for a purely in-process host, rather than calling it HID or SDL. Such a record remains explicitly incomplete, but its observations can still be checked and retained. Do not add serials, peripheral UUIDs or bond data; leave unknown firmware null and unperformed checks `not-run`.

- **Input and ownership (`active_input`, `held_input`):** exercise press/release, D-pad/stick navigation, activate/back, directional repeat and edge-only activation. Hold the same action with a local key and a controller; release each in both orders. In a host exposing rebinding, replace a held binding and check release-before-rearm; the demo has no rebinding UI, so leave that part untested there. Observe returned release phases in the host, not just selection movement.
- **Lifecycle (`new_pairing`, `button_wake`, `reconnect`, `sleep_wake`, `multiplayer`, `held_input`):** test initial Sync pairing, normal-button wake, reconnect, Bluetooth off/on, application stop/restart and multiple controllers. Lose focus, disconnect and sleep while controls are held. Expect no stuck actions or unintended activation; neutralize before rearming. Record whether a fresh discovery window or Sync was needed.
- **Model and sustained use (`rumble`, `pointer`, `trigger_travel`, `trigger_clicks`, `active_input`, `held_input`):** test only available models. Check each Joy-Con's handed controls, GameCube analog travel separately from digital clicks, and supported feedback without claiming cancellable GameCube clips. Use a pointer-capable host for optical checks. Run a sustained session and record its duration, delayed effects, dropped releases, pointer jumps where applicable, and host memory/CPU observations. Resource observations are not instrumented power measurements.

Attach concise, real observation files and their SHA-256 references only to completed checks. Do not mark a whole check passed when a listed subcase remains untested: describe partial results in `record.checks[check].evidence`, keep it `not-run`, and leave `evidence[check]` empty as the validator requires. Then validate and inspect a candidate matrix without replacing the repository's recorded matrix with a template:

```sh
python3 scripts/hardware-evidence.py --root qualification check action-router.json
python3 scripts/hardware-evidence.py --root qualification matrix action-router.json
```

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
