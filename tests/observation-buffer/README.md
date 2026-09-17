# Observation inbox microbenchmark

From any working directory:

```sh
bash /path/to/Switch2Kit/tests/observation-buffer/benchmark.sh
```

This optional benchmark compiles the real `EventMailbox` in release mode. It queues
exactly 256 or 4096 status envelopes while its delivery queue is suspended, then
measures resume-to-last-handler time for nine repetitions. The output contains all
samples and their median. It checks completion and delivered count, not a timing
threshold. It is not a Bluetooth, SDL, emulator-frame, or physical input latency test.

For a before/after comparison, run the identical `Benchmark.swift` and compile
command against each revision's `Observation.swift` and its own source dependencies
in separate checkouts. Do not compare a debug build against a release build. CPU
load, scheduler behavior and platform affect the measured times.

Correctness and storage-bound tests are in
`Tests/Switch2KitTests/PendingControllerEventsTests.swift`; the existing observation,
reader, generation and native consumer regressions remain mandatory. This optional
microbenchmark is deliberately not discovered as a timing-sensitive CI test.
