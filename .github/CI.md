# CI: one routine workflow, explicit qualification

`ci.yml` is the only automatic workflow. It checks pull requests, main pushes and merge-queue
commits; it can also be dispatched manually. The other eight workflow files are
on-demand qualification tools, not eight independent per-commit build pipelines.

## Routine budget

| Lane | Work | Job timeout |
| --- | --- | ---: |
| Preflight | CI-policy tests, repository links/identity, notices, signing guards, source boundaries, complete-PR change classification | 2 min |
| macOS 26 | Complete `tests/run.sh` (Swift package plus every portable shell suite), independent public Swift consumer, real demo/app, signing and current-runtime probe | 8 min |
| Linux / Swift 6.2.1 | Package tests, private-D-Bus BlueZ transport tests, one real SDL build for the adapter and automatic-discovery host consumers | 8 min |
| Windows 2022 / Swift 6.2.1 | Native WinRT transport/package tests and release C facade | 8 min |
| CI gate | Verify all expected outcomes, including intentional docs-only skips | 1 min |

Preflight must succeed before any compiler runner is allocated. The three native
lanes then run in parallel. All runs cancel superseded work for the same PR/ref.
There are no retries, extra automatic matrices, or scheduled qualification runs.

The configured maximum is **27 aggregate job-timeout minutes**, down from 230 in
the first cost-control revision and 925 in the original main configuration, per PR.
That is an 88.3% reduction from the first revision, or 97.1% from the original.
These are timeout budgets, not measured execution time, billable minutes, or
invoice savings. A PR followed by a main push has two bounded runs (up to 54
aggregate timeout minutes), not one. They do not cap runner queue/provisioning delays. A native job
exceeding eight minutes fails; the limit must not be mistaken for evidence that
the revised suite already passed within it.

Known documentation-only PR/main changes run just preflight and the gate: **two cheap
Linux jobs, zero compiler jobs, three aggregate timeout minutes**. The entire PR
merge-base diff is examined, not only its latest commit. Main pushes use the
complete before/after diff. Rename deletions are
included. Unknown paths, missing Git history, empty diffs, workflow changes,
source/test/build inputs, and material license changes conservatively run native
checks. Manual and merge-queue runs always run all three native lanes. Cheap
repository/link/notice/identity checks still run for documentation changes.

Do not replace this with a workflow-level `paths-ignore`: required workflows can
remain pending when filtered out. The always-reporting `CI gate` rejects failed,
cancelled, missing, or unexpectedly skipped jobs. `.github/ci/test_policy.py`
checks the budget, event policy, native coverage, dependency pins, artifact
policy, whole-PR/rename selection, and all 512 success/failure/cancel/skip gate
combinations. Policy tests run in preflight before expensive jobs.

## What is no longer rebuilt on every PR

The full portable shell suite runs once on macOS instead of again on Linux.
Linux retains its actual platform transport and real SDL/SDLHost integration
checks. Routine Windows retains the baseline compiler and real WinRT tests,
without rebuilding SDL and extracted consumers on two toolchains. Routine macOS
no longer adds separate Intel/ARM SDL builds or an upstream motion-consumer job.
The SDL before/after patch rebuild, Linux release/relocation/X11 qualification,
and full application/distribution matrices are explicit work below.

No production code or existing test assertion is removed. The eight existing
qualification workflows retain their job definitions, dependency pins, and
matrices. Moving work out of automatic CI is a coverage tradeoff, not proof that
the omitted configurations passed. Routine green CI does not establish full
platform compatibility, full emulator integration, or physical-controller and
gameplay acceptance.

## Required check and direct-main policy

Use `CI gate` as the routine required check, after its new-head run succeeds.
Retire requirements referring to the now-manual workflow jobs when adopting this
policy; do not treat absent old checks as passes. This source change does not
modify branch protection or merge anything.

The audit found main unprotected, with no required-check contexts or rulesets.
Therefore main pushes retain the same bounded pipeline: direct commits must not
silently bypass validation. There is no feature-branch push trigger duplicating
PR events. A PR merge intentionally validates its resulting main commit again.
Merge queues are supported by `merge_group` and validate their integration
commits with all native lanes. Configure `CI gate` as a required check to enforce
this policy at merge time; publishing this PR does not configure that setting.

## Explicit qualification

Run the relevant workflows before distributing artifacts or asserting support,
and when reviewing their affected integration/packaging/toolchain changes:

| Workflow file | Qualification retained |
| --- | --- |
| `macos-validation.yml` | Full development-app packaging and requested artifact |
| `linux-bluez.yml` | Full portable/release, relocation (lib/lib64), X11 and SDLHost checks; optional complete Dolphin/Cemu builds |
| `windows-native.yml` | Both Windows/Swift toolchains, real C/SDL consumers and extracted-runtime negative controls |
| `sdl-inprocess.yml` | Both Mac architectures and unrelated checkout paths containing spaces |
| `sdl-regressions.yml` | Before/after SDL patch regressions and requested corrected SDL library |
| `emulator-integration.yml` | Pinned actual upstream motion consumers; optional four full Mac apps and four clean-runner launch checks |
| `runtime-qualification.yml` | Full four-entry macOS version/architecture runtime matrix |
| `switch2kit-distribution.yml` | Universal C ABI/XCFramework and independent consumers |

For C ABI, SDL or host integration changes, review the relevant Windows/macOS
native qualifications as well as routine Linux coverage. Packaging, deployment,
X11 or loader changes need the affected platform's full workflow. Emulator patch
or dependency-pin changes need the real upstream consumers/full apps. These are
explicit reviewer qualification obligations, not automatic path-enforced gates.

Examples (replace `main` with the reviewed branch and verify the resolved SHA):

```sh
gh workflow run ci.yml --ref main
gh workflow run windows-native.yml --ref main
gh workflow run sdl-inprocess.yml --ref main
gh workflow run linux-bluez.yml --ref main
gh workflow run emulator-integration.yml --ref main -f full_emulators=true
gh workflow run linux-bluez.yml --ref main -f full_emulators=true
gh workflow run runtime-qualification.yml --ref main
gh workflow run switch2kit-distribution.yml --ref main
```

The two `full_emulators` inputs default to false. Heavy application jobs depend
on their baseline qualification job succeeding. Do not dispatch every manual
workflow for a prose or routine CI-policy change.

## Evidence, storage and billing limits

Historical step timing informed the split; it is not a benchmark of this change.
On September 19, 2026, macOS run `35460054677` spent 4m39s executing after roughly
30 minutes queued. Windows run `35452827984` used 8m36s / 9m13s across its two
jobs; native package/release steps took 2m43s / 2m12s, while C/SDL builds added
4m14s / 5m18s. Linux run `35452827978` spent 9m35s in its baseline job, including
repeated portable, release and relocation work. Re-measure the new exact head;
do not relabel these historical successes as new-head CI results.

Successful routine runs upload no artifacts and add no build cache. Failed Linux
and Windows native lanes retain small logs for one day. Manual workflow artifact
retention remains bounded at one to seven days. Normal Actions logs remain
available. No stale artifacts are deleted and no already-accrued charges change.

The repository was public with standard hosted runners at the audit; GitHub's
billing documentation distinguishes their free public-repository compute from
storage and other charged SKUs. No account invoice was accessible through this
repository audit. No dollar savings are inferred from these timeout budgets.

References: [workflow filtering](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/trigger-a-workflow),
[concurrency](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency),
[Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions).
