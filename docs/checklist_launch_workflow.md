# Checklist r/R: stage for review or stage and launch

**2026-10-29 demo correction:** Timing quick-launch after a completed synthesis
could silently reject a catalog-derived action as though it had to be advertised
by the old run observation. Catalog-derived Timing now uses fresh-endpoint
validation; explicit observed actions and asynchronous selection guards remain.
Shift-only ASCII/Unicode R events are also recognized. An isolated HTTP/PTY
regression reproduces the old no-op and now verifies exactly one Stage_fresh,
Launch_fresh and new timing workflow after raw R, without a manual launch.
Only the client needs restarting for this correction; no live daemon or real
physical run was started by the test.

**2026-10-26:** lowercase **r** retains the manual workflow below; uppercase **R**
stages the selected operation and automatically launches its exact ready plan.
Quick launch defaults to viewing the new run in the captured linked context. The
palette's **Quick-launch behavior: keep current context** option persists across
client restarts; **Quick-launch behavior: view launched run** restores
the default. Failed planning or changed captured context/selection prevents launch.

The **Elaboration** preparation row follows the same r/R split. Its input plan is
staged on the backend without building or emitting; launch then builds current
source and emits the selected bundle without EDA. Preparation does not allocate an
ASIC run, so it retains the context under either viewing preference. Its aligned
time column includes build and emission. See [project preparation](project_preparation.md).

Palette shortcuts now use action-first names: **Quick launch selected stage**, **Launch
synthesis and view**, and **Launch elaboration bundle**. The query prefixes `quick lau`,
`launch syn`, `launch elab` and `launch and vi` select their corresponding actions.
Named physical shortcuts always launch-and-view without changing the saved generic
quick-launch preference. Search edits select the best-ranked match; captured actions
remain subject to selection/capability/context revalidation.

Restored and verified 2026-10-17 for the actual ASIC example as well as synthetic
stage actions. This supersedes the earlier limitation that real normalized stage
rows could only report status. [Implementation plan](checklist_launch_workflow_plan.md).

## Use the restored workflow

1. Focus **stage checklist** and select Routing (or another stage) using j/k.
2. Press **r**. If discovery is absent after restart, this explicit action discovers
   current capabilities, resolves the captured stage and prepares a normal plan.
3. Wait for **ready** in planned-run. Check the resolved flow/profile/endpoint.
4. Open/reopen **Space c c** and choose **Launch** or **Launch and view in captured
   context**. In the lowercase-r workflow, only this step starts execution.

For `standard / balanced`, choosing Routing requests a **new fresh prefix through
routing**, not restart/resume of the selected historical execution. A stage marked
not requested in the old run may still be a supported endpoint for a new run.

Launch commands are now searchable even without a current preview. They are
disabled with a missing/pending/failed/stale preparation explanation rather than
silently absent. An already-open palette retains captured commands; reopen it after
the plan becomes ready to get the new exact launch action. Disabled commands never
carry a fabricated Preview or dispatch an execution.

If no run/stage rows are selected yet, the ordinary explicit Plan palette forms
remain available after Discover. This change does not manufacture an observed stage
row for a project with no selected execution.

## How the selection is resolved

An explicit provider `Stage.action` remains authoritative, preserving synthetic
behavior. Otherwise the resolver uses normalized current project capabilities:

- Recognized fresh physical recipe and complete-prefix endpoint semantics.
- The exact declared stage endpoint list; no guessed alias or directory name.
- Captured remembered launch inputs first, then the captured observed run selection
  when available, then the provider's actual declared catalog default pair.
- Replace only the endpoint with the selected stage; preserve explicit assignments.
- A stale explicit flow/profile is an error, not permission to silently choose a
  different default. Choose supported Plan inputs and retry in that case.

The current real example explicitly advertises `librelane.classic.v1`, fresh input,
complete-prefix-through-declared-endpoint semantics, endpoints synthesis/floorplan/
placement/cts/routing/signoff, profiles balanced/synth_delay, and default pair
standard/balanced. These are public project declarations, not inferred from stage
completion or the run's name.

Unsupported/legacy providers keep ordinary explicit Plan/Run support; they do not
gain checklist shortcuts unless they advertise a valid mapping or explicit action.

## State and safety semantics

Pressing r captures the stage, project/daemon/context and launch input choice before
asynchronous discovery. Preparation immediately blocks the old preview's Launch
action. Changed context, workspace roundtrip, newer intent or failed discovery
cannot retarget the captured request or enable the old plan accidentally.

Catalog refresh clears stale mappings and publishes validated flows/default together.
There is no provider JSON parsing in tiles. Normal rendering, palette opening and
passive polling do not auto-discover or run tools; discovery is part of the explicit
r action. The existing Plan/Run contracts, exact Preview comparison, submission
idempotency and launch ledger remain authoritative.

## Upgrade the running demo

Normal binaries and persistent real-demo copies have been rebuilt/refreshed. No live
user process was stopped. After active jobs finish, close the old client and stop
the old daemon normally, then restart both matching copies:

**Terminal 1:**

```sh
cd /home/wayne/devel/jane/silver
python3 -B scripts/real-asic-example-demo.py daemon
```

**Terminal 2:**

```sh
cd /home/wayne/devel/jane/silver
python3 -B scripts/real-asic-example-demo.py client
```

Your current runs and selection remain saved. Do not reseed just to use this fix.
If an old cached checklist is empty, select the run and use **Refresh evidence**
once; no EDA rerun is needed. Then use j/k/r directly: manual Discover is no longer
a prerequisite when the real supported mapping has not yet been loaded.

Backend/client snapshot fields changed additively, with legacy S-expression
defaults; upgrade the pair together rather than mixing live old/new binaries.

## Source map and verification

- `Asic.Flow.fresh_stage_endpoints`, `Asic.Flow_default`, and
  `Asic.Snapshot.catalog_default`: typed, bounded current capability data.
- `backend/asic_public.ml`, `asic_service.ml`: strict schema/capability/default
  validation and coherent discovery publication.
- `terminal/stage_action.ml`: pure exact selection resolver.
- `workspace_host.ml`, `main.ml`, `host_view.ml`: captured preparation, status,
  disabled/ready launch catalog entries and normal Plan dispatch.
- `scripts/test-checklist-launch-workflow.py`: bounded native HTTP/PTY proof.

Final normal format/lint, full tests and full build passed serially at `-j 2`.
Final native acceptance passed **61 assertions**:

```text
/tmp/opencode/checklist-workflow-7dbc9ab8d388/result.json
```

The real side restarted with a retained synthesis observation, no catalog and no
preview. Actual keyboard j/k/r on Routing issued exactly one flow-list query and
one real Plan, yielding standard/balanced/routing. Launch became available but was
**not pressed for the real provider**. Canonical records remained unchanged.
Additional tests cover declared-default-not-first, remembered synth_delay plus
`SYNTH_ABC_BUFFERING=true`, stale profile, nonfresh mapping, unsupported endpoint
and changed-context/late-discovery rejection.

The synthetic side proves pending/failed replacement cannot launch an old preview,
then explicit retry and Launch create exactly one producer with the correct exact
Preview/key/allocation. No new real EDA was executed.

Agent regression evidence under `/tmp/opencode`: `checklist-regression-consistency`,
`checklist-regression-sidebar`, `checklist-regression-synthetic`, `fs2-native-n3hpx881`,
and all five interrupts at `workbench-terminal-interrupt-cq5mhehs` passed.
Persistent refresh receipt is in the example at
`.dev/workbench-real-demo/receipts/refresh-binaries-fbf48f50e49b43e798084ffb63a53578/`.
Existing user files/index/history and live state were preserved; no staging, commits
or pushes were performed.
