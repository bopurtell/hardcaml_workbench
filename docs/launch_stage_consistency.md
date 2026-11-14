# Plan/launch lifecycle and real stage observations

Fixed and verified2026-10-17 after the owner launched real synthesis runs and saw
both `Plan ready; ... no job allocated` and an entirely unreported checklist.
The implementation plan is [launch_stage_consistency_plan.md](launch_stage_consistency_plan.md).

## What was wrong

The planned-run view described only the retained preview, not its subsequent exact
submission/allocation. Retaining a reusable preview was valid; asserting no job was
allocated was not. The real provider also already exposed requested stages and
per-stage occurrences in its public observation snapshot, but Workbench only read
the optional synthetic-provider `stage_plan` extension.

Neither issue required rerunning EDA or changing producer records. The adapter now
consumes the existing public structured evidence, and the daemon exposes exact
durable launch associations to the client.

## Planned-run display

The panel keeps two distinct facts:

- **Plan readiness:** empty, pending, failed, stale or ready.
- **Associated launch lifecycle:** submitting, allocated, running, completed,
  launch failed, cancelled, detached or unavailable.

For a completed execution with a retained valid preview, it can say:

```text
ready: plan / last launch: completed
endpoint: synthesis
last launch using this plan: Producer completed; no active launch owner
exact allocated run: <provider-returned identity>
submission key: <exact reservation key>
```

The preview can be deliberately reused for a new launch with a new key; the UI
does not silently replay it. While a local submission is unresolved, a matching
launch is active, or producer ownership is detached/unknown, launch availability
remains guarded. Transport failure means allocation is unknown until exact server
evidence resolves it, not proof no process started.

`Asic.Snapshot.launches` projects the existing bounded durable reservation list:
key, full exact Preview, and optional allocated run ID. The order is authoritative
reservation order, not guessed directory/ID ordering. The client matches complete
preview identity and resolves only the exact allocated run. Historical registration
does not invent a launch association. Another client's launch can be observed via
the same ledger; changing inspected run selection does not retarget it.

After daemon restart the current preview may be absent. The newest durable
reservation is then labeled **last launch reference (no current plan)**, with its
recorded run/ownership state. This is not a freshly reusable plan. Discover/Plan
must still be explicit before another execution.

## Checklist normalization

For a supported public stage-observation snapshot with a schema3 recipe, Workbench
normalizes `state.plan` and the exact `implementation.<stage>` occurrences:

- Completed requires the recorded completed occurrence and exit0.
- Publishing a checkpoint while the occurrence is running does not make it complete.
- Stages outside the explicit recipe are **not requested**.
- Resume input boundaries and explicit carried-forward occurrences are labeled
  separately from newly measured work.
- Missing, malformed, inconsistent or unknown stage facts cannot become passes.
- Explicit interruption is mapped to the cancellation display category with a reason
  identifying interruption; it is not evidence that the user requested cancellation.
- Exact stream/attempt/occurrence and cursor fences remain in force. A newer inspect
  response cannot attach its checklist to an older observation cursor.

Supported optional stage-plan v1 continues to take precedence. Unsupported extension
versions remain opaque; no report scraping, aggregate success inference or historical
result rewriting was introduced.

The owner's exact real runs now normalize as follows:

| Stream | Evidence-backed checklist |
| --- | --- |
| `fac7d0bc5aaf42daab72d381b6e653e5` | Synthesis completed; floorplan/placement/CTS/routing/signoff not requested |
| `6c006def1f794542a1c4cf481e8eba2f` | Synthesis completed; remaining five not requested |
| `344ac175531e46fcbd021a1d4c79c361` | All six requested stages completed |

Timing slack/terminal checks can still be unavailable for a synthesis-only run.
Completion is not timing measurement or acceptance. View categories such as Timing
and Checks are not themselves canonical physical stage IDs.

**Subsequent stage-action integration:** the real observation still does not
advertise an action directly, but the project catalog explicitly declares fresh
prefix endpoints. Checklist r now resolves from those typed capabilities, performing
discovery as part of the explicit command when needed, then invokes normal Plan.
Launch remains separate and visible with availability reasons. See
[the restored checklist workflow](checklist_launch_workflow.md). This does not infer
an action from status or guess endpoint names.

## Load the fix without rerunning your jobs

The normal build and persistent demo copies are updated. No live user process was
stopped. Once active jobs are finished, close the old client and stop its old demo
daemon normally, then restart both matching binaries:

**Terminal1:**

```sh
cd /home/wayne/devel/jane/silver
python3 -B scripts/real-asic-example-demo.py daemon
```

**Terminal2:**

```sh
cd /home/wayne/devel/jane/silver
python3 -B scripts/real-asic-example-demo.py client
```

Select the existing synthesis run, open Space c c and choose
**Refresh evidence asic/6c006def1f794542a1c4cf481e8eba2f** (or the other exact run).
This reads its existing journal/reports and replaces cached empty stage data. It
does not rerun synthesis. Refresh the other retained runs if desired.

Do not reseed just to refresh these runs: seed imports/selects the prepared historical
reference. Your saved current runs and workspace selection are retained already.
If Plan commands are missing after restart, use **Discover ASIC flows and runs**;
flow discovery is distinct from historical cached evidence reopening.

Daemon and client must be upgraded together because the live snapshot gained the
launch ledger field. Older S-expression snapshots without it default to an empty
ledger; stored provider records and existing Workbench submission records are unchanged.

## Implementation and verification

- `backend/asic_public.ml`: supported structured observation normalization.
- `protocol/asic.ml`, `backend/asic_service.ml`: additive bounded launch projection.
- `terminal/planned_run.ml`, `main.ml`, `workspace_host.ml`, `host_view.ml`: exact
  intent/receipt/launch state and presentation, independent plan/launch generations.
- `backend/test/stage_normalization/`: live, terminal, missing/unknown, resume and
  extension-compatibility fixtures.
- `scripts/test-launch-stage-consistency.py`: private real-read and synthetic
  lifecycle HTTP/PTY acceptance; no real execution or canonical edits.

Final normal format/lint, full tests and build passed serially at `-j 2`.
Final normal-binary acceptance passed **27 checks** at:
`/tmp/opencode/launch-stage-consistency-a2201a488574/result.json`.

Real-read tests use the exact three public observation identities with an explicit
read-only command allowlist; their before/after canonical inventories match. Private
response-clone fixtures cover running/failed/interrupted states while preserving real
execution/checkpoint references, proving those references alone do not imply success.
Synthetic HTTP/PTY verifies early allocation, explicit launch, same-preview reuse,
unread receipt/idempotent recovery, failure/cancel, replan isolation and restart
without implicit relaunch. These fixture states are not claimed as new real EDA.

Latest agent regressions under `/tmp/opencode`: `synthetic-flow-1d7hjkat`,
`overview-sidebar-6b84e0178880`, `fs2-native-k2qejcxq`, and all five interrupt cases
at `workbench-terminal-interrupt-d_wtybg3` passed. Synthetic Testing also passed at
`synthetic-flow-rjby_acw` before the final restart-display refinement.

Persistent demo refresh receipt: example
`.dev/workbench-real-demo/receipts/refresh-binaries-41aeaccdc12c40d0b5ff40344f569753/`.
Matching actual-project Overview/Timing/rich inspection acceptance passed again at
`.dev/workbench-real-demo/receipts/acceptance-d3e1eff8c1c5468eae729968cf05eabe/`.
No provider installation, source result edits, Git staging/commits or real flow
launches were required for this fix.
