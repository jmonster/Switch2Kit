# Release readiness for native hosts

Use this checklist before sharing a controller-enabled application as a release.
A green library test, a packaged executable, and a successful game session establish
different things. Record the exact SDK and application revisions for each result;
do not carry acceptance forward automatically after changing a transport, adapter,
toolchain, or packaging path.

## Verification layers

| Layer | Required evidence | What it does not establish |
| --- | --- | --- |
| Swift/C library | Package tests with warnings as errors on macOS, Linux, and Windows; debug and optimized ABI validation | Physical Bluetooth, application packaging, or gameplay |
| In-process SDL host | Actual pinned SDL consumers exercising input edges, hotplug, neutral rearming, rumble, motion, and shutdown | A complete Dolphin/Cemu application or measured controller latency |
| Emulator integration | Enabled build of each intended application/platform using the candidate SDK revision; native motion consumers where applicable | A disabled-backend upstream build is not evidence for Switch2Kit |
| Extracted application | Relocation, dependency/license inspection, launch, normal quit and relaunch without developer dependency paths | First-run permissions, signing trust, or a physical controller session |
| Physical acceptance | Exact OS/build, architecture, Bluetooth adapter/driver, controller model/firmware, app/SDK revision, game and observed results | Untested platforms, controller models, transport modes, or firmware |
| Distribution | Appropriate signing/trust checks, required notices, checksums, documented prerequisites and a reproducible download | A development Actions artifact is not automatically a supported public release |

The routine [CI workflow](../../.github/workflows/ci.yml) is intentionally bounded.
It runs package/platform checks and Linux native SDL-host tests, plus Apple builds
and unsigned iOS compile checks. Full application, clean-runtime, and expanded
Windows-toolchain qualification are separate opt-in workflows. A workflow file
or an old successful run does not prove the candidate passed: inspect the exact
head SHA, failed/skipped jobs, and retained evidence. If Actions is unavailable,
record CI as blocked rather than interpreting absent checks as success.

## Reproduce the core checks

Use Swift 6.2 or newer and the platform prerequisites from [macOS/Swift](README.md),
[Linux](linux.md), or [Windows](windows.md):

```sh
swift test -Xswiftc -warnings-as-errors
swift test -c release -Xswiftc -warnings-as-errors
bash tests/run.sh
```

`tests/run.sh` includes platform-specific suites; an OS guard can legitimately
skip a stage. Review those limits. On Linux, the BlueZ test needs permission to
start a private D-Bus socket; a sandbox refusal is a blocked transport test,
not a failed physical controller and not a pass. Do not loosen host Bluetooth
security or alter global bus permissions to make a test pass.

For actual SDL consumers, the routine Linux CI lane currently pins SDL 3.4.16
(`fa2c02bb6e21974a89ea9824bc53c9932abe5f9c`):

```sh
S2K_SDL_SOURCE=/path/to/pinned/SDL \
S2K_EXPECT_SDL_VERSION=3004016 \
bash tests/emulator-host/verify.sh
```

That command builds the real SDL adapter and host fixtures. Adding
`S2K_CEMU_SOURCE` and `S2K_DOLPHIN_SOURCE` enables consumers of the pinned emulators'
actual motion implementations; use [the integration revisions and patch steps](../../Integrations/Emulators/README.md).
These are targeted native consumers, not full emulator builds. The maintained
forks may use different source revisions and must be qualified separately.

## Promote the same revision into each application

1. Finish SDK tests and review first. Record its immutable commit SHA.
2. Update the intended fork's pinned SDK revision in a reviewable change; do not
   assume that a branch name, a successful SDK PR, or a similarly named artifact
   changed the emulator's dependency.
3. Build with Switch2Kit explicitly enabled. Verify the expected native library
   and notices are in the extracted application, and the actual controller UI is
   present. Keep upstream/default-off builds working as an independent check.
4. Run clean-runtime launch/quit/relaunch and physical acceptance for every platform
   that the proposed release claims. Repeat affected checks after later edits.
5. Publish only the tested artifact from that exact revision, with checksums,
   prerequisites, platform limitations and a rollback path. Merging, signing,
   notarization and release publication are separate decisions.

## Candidate dependency record (2026-10-02)

These are review dependencies, not released binaries or completed qualification.
Recheck their exact heads before using this record:

- [Switch2Kit #79](https://github.com/jmonster/Switch2Kit/pull/79) contains SDK
  hardening and this checklist. Record the final reviewed SDK SHA only after
  its required checks finish; do not point applications at an untested moving branch.
- [Cemu #6](https://github.com/jmonster/Cemu/pull/6) hardens Windows toolchain
  selection. A successful backend-disabled smoke check does not qualify the
  enabled app. Its SDK pin must be reviewed separately after SDK validation.
- [Dolphin #10](https://github.com/jmonster/dolphin/pull/10) improves fork setup
  documentation and is stacked on [Dolphin #9](https://github.com/jmonster/dolphin/pull/9).
  The underlying enabled native build matrix and the final SDK pin remain
  release gates; a passing documentation check is not a substitute.

No stable application release, complete cross-platform hardware matrix, or
signing/notarization acceptance is asserted by this record. Preserve the
[hardware matrix](../hardware-matrix.json) as actual evidence, not a roadmap.

## Physical testing and performance

Use [hardware evidence](../hardware-evidence.md) and [controller test records](../acceptance-records.md)
for observations. The existing structured record tools are macOS-oriented; for
Linux and Windows retain a separate platform-specific observation record with
the fields above, rather than putting another OS into a macOS-version field or
claiming the current matrix validator covers it. Never fill unknown fields by guessing. A reported successful
Dolphin game session is valuable, but without its OS, controller identity/firmware,
connection mode and revisions it does not qualify Cemu or all desktop platforms.
Keep partial observations partial, and leave unperformed checks `not-run`.

For each supported model, test short taps, held-button releases, stick/trigger
travel and clicks, rumble start/stop, disconnect/reconnect, adapter power changes,
sleep/wake, application shutdown and multiple controllers. Include focus loss
and motion-profile replacement while controls are held. Inactive input must
remain suppressed, and profile replacement must preserve any pending
neutral-rearm requirement.

Measure performance in the intended application before changing hot paths.
Record workload, controller count, report rate, frame/poll cadence, session duration,
CPU/memory, input latency and dropped/reordered events using the same setup for
baseline and candidate. Separate host delivery timing from radio/game/rendering
latency. Preserve bounded queues, generation checks, fairness and release events;
a faster synthetic loop is not an improvement if it creates stale input or
unbounded backlog. See the [delivery contract](concurrency-and-logging.md).
