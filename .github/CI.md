# CI execution and artifact policy

Routine pull requests validate the SDK, platform transports, and real consumers.
They do not rebuild and archive complete upstream emulator applications. Full
application and distribution qualification remains available explicitly.

## Routine checks

| Workflow | Automatic work |
| --- | --- |
| `macos-validation.yml` | Strict Swift build, public Swift consumer, demo, package/output regressions, signed development bundle, and the existing packaged runtime probe on macOS 26. |
| `linux-bluez.yml` | Package/BlueZ tests, release tests, relocation, X11 observer, and the combined SDL/SDLHost native suite. Also runs on main pushes. |
| `windows-native.yml` | Both existing Windows/Swift toolchains, native transport, C/SDL consumers, and relocated runtime checks. |
| `sdl-inprocess.yml` | Both macOS architectures; one unrelated checkout path containing spaces, rather than three fresh builds of the same tests on each runner. |
| `emulator-integration.yml` | The native host and actual pinned Cemu/Dolphin motion consumers, not the complete applications. |
| `sdl-regressions.yml` | Before/after SDL patch regressions, only when this workflow or its SDL/test/version-check inputs change. |

The former concurrency workflow's warnings-as-errors build and the distribution
workflow's source-boundary/public Swift consumer checks now live in macOS
validation. `tests/run.sh` still runs the package and every `tests/*/run.sh`
suite; Linux no longer invokes the package and BlueZ suites twice.

The former SDLHost workflow is folded into Linux validation:
`tests/emulator-host/CMakeLists.txt` includes `tests/sdl-inprocess`, so its native
build executes both suites without building SDL again in a separate workflow.
No production code or test assertions are removed.

Core checks deliberately still run for all PRs. Broad documentation exclusions
could silently skip license/notice or repository checks. Only the isolated SDL
patch workflow has a narrow path filter; do not make that path-filtered workflow
a required check without arranging an always-reporting gate.

## Explicit full qualification

Use Actions > Run workflow on the branch being qualified. For the two emulator
workflows, `full_emulators` defaults to **false**. Only explicitly setting it to
true enables full upstream builds, after their baseline job succeeds:

```sh
gh workflow run emulator-integration.yml --ref main -f full_emulators=true
gh workflow run linux-bluez.yml --ref main -f full_emulators=true
gh workflow run runtime-qualification.yml --ref main
gh workflow run switch2kit-distribution.yml --ref main
```

Replace `main` with the branch being reviewed and verify the resolved commit SHA
in the run. The Mac emulator workflow retains all four application builds and
all four separate clean-runner launch checks. Linux retains both complete
emulator builds and relocation inspections. The runtime workflow retains all
four macOS version/architecture combinations; distribution retains the universal
C ABI/XCFramework and independent consumers.

Run the relevant full workflows before distributing artifacts or asserting full
platform compatibility, and when reviewing emulator patches, packaging, deployment
targets, toolchains, or pinned dependency updates. They are intentionally **not**
automatic merge gates: routine green CI alone does not establish full application,
minimum-OS, hardware, or gameplay qualification. No scheduled full builds are added.

For only a development app, dispatch `macos-validation.yml`. The SDL patch
workflow also publishes its corrected library when explicitly dispatched.

## Storage and cancellation

Successful automatic PR/main runs upload no artifacts. Failed native-host, SDL
patch, and Windows runs retain small diagnostics for three days; ordinary Actions
logs remain available. Repeated SDK and SDL source archives are removed from
routine runs; the checkout/dependency SHAs identify the tested inputs.

Explicit Mac emulator builds retain intermediate apps, upstream source archives,
and diagnostics for one day, including the artifacts consumed by launch jobs.
Requested SDK app/universal distributions and runtime reports are retained for
seven days. Linux/Windows diagnostics and the requested SDL library use three days.
Every workflow cancels superseded runs on the same ref and every job has a timeout.

Changing these workflows affects future uploads, not existing artifacts or
previously accrued charges. This change does not delete old artifacts, change
account billing/budgets, or merge itself.

## Audit baseline and billing caveat

At main `d9129e3876f0d68aa7d13395dcff8e2abb38d609` (2026-09-19), ten workflows
could schedule 25 jobs per PR, with a sum of configured job timeouts of 925
runner-minutes. This policy has six automatic workflows and at most eight
runner jobs (seven when the SDL patch workflow is not relevant), with a sum of
230 configured timeout minutes. That is 68% fewer potential automatic jobs and
about 75% less timeout exposure, **not measured runtime or invoice savings**.
The two remaining workflows are manual-only. Skipped qualification jobs do not
allocate runners.

This repository was public at the audit, and its runner labels were standard
GitHub-hosted labels, not paid larger runners. GitHub documents standard-runner
compute as free for public repositories. High run counts are waste and queue
pressure, but are not by themselves evidence of invoiced compute charges.
Actual billing attribution requires the account's usage by repository and SKU;
artifact storage, cache allowance/settings, and historical billing must be checked
separately. No invoice total is inferred from workflow elapsed time.

References:
- [Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions)
- [Standard runner labels](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
- [Usage details and reports](https://docs.github.com/en/billing/how-tos/products/view-productlicense-use)
- [Budgets and spending controls](https://docs.github.com/en/billing/how-tos/set-up-budgets)
