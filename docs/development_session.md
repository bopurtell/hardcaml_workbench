# One example development session: FIFO, PT.8, ASIC and waveforms

**Post-refactor update, 2026-11-10:** use the example's
[ownership-v1 continuation](../../hardcaml_asic_example/docs/migration_plans/workbench_continuation.md)
for current source layout/new-store preparation. The old store is not automatically
migrated. [Developer workflow closeout](developer_workflow_refactored_closeout.md)
now records actual synthesis, collection, report/check inspection and restart on a
new private capture. Launch commands/generations below describe the earlier session.

2026-11-05. **Implemented and independently accepted in the bounded development
scope.** This is the recommended everyday example entry point. It replaces the
need to create another numbered demo session for each feature; all earlier
sessions, configurations and evidence remain intact.

## Roadmap orientation

The ASIC PT.0–PT.8 track is nine numbered entries (including PT.0), not a complete
first-release/deployment checklist. The authoritative
[ASIC phase plan](../../hardcaml_asic/docs/phase_plan.md) marks PT.0–PT.2 and
PT.4–PT.8 complete in their supported library/example scopes. **PT.3 remains partial:
PT.3a/b are complete; PT.3c routed functional replay passes, but physical acceptance
is blocked.** PT.7 consumer timing review and PT.8 Protemu configuration selection
remain separate open obligations. No Protemu acceptance follows from this example
session, and no PT.9 has been adopted. Follow the
[phase plan's status terminology](../../hardcaml_asic/docs/phase_plan.md#status-terminology):
“complete” means required gates passed for the stated scope; implementation awaiting
required acceptance must say so explicitly, rather than use “delivered”.

The [Workbench construction plan](construction_phase_plan.md) records the implemented
UI/daemon integrations and remaining manual acceptance. The unified session adds
the existing FIFO and PT.8 suites, exact result/waveform handoffs and normal ASIC
preparation; it is not another hardware-feature phase.

For a developer-first release, the next recommended closeout is ordinary end-to-end
workflow acceptance plus setup/environment/compatibility hardening, rather than
automatically expanding the backend feature list. Recent synthesis Git-context
checks establish corrected metadata/preparation, **not a completed new synthesis
run**; confirm actual run/report/reopen outcomes before claiming that workflow's
release acceptance. Historical
[ASIC P6 installation/source-identity obligations](../../hardcaml_asic/docs/archive/phase-plan-2026-10-24.md#asic-p6--shared-tooling-distribution)
remain open at their recorded scope; local captures are not a completed independent
installation/source-attestation release. Promote any new implementation slice
through the active queue instead of treating this orientation as a second queue.

Workspace interface consistency, actionable errors and owner usability review can
be the main focus while closing those deployment gaps. Restoring connected waveform
strokes is a deferred presentation follow-up, as the owner requested; general
N-workload composition and a matched physical Flops/SRAM study are separate future
extensions, not automatic prerequisites for the current developer workflow.

**Synthesis Git-context correction:** earlier captures exported source Git selectors
globally, causing collateral revision checks to read the example's revision. If
using the earlier prepared generation, stop its daemon and apply this one-time
same-store correction before restarting:

```bash
opam exec --switch=5.2.0+ox -- python3 -B scripts/workbench_dev.py prepare \
  --refresh --update-owned-support --git /usr/bin/git
```

This scopes source Git context to the actual source query, preserving collateral
revision validation. It does not change support-tools/PDK checkouts or retry failed
runs. [Diagnosis, verified preflight and limits](development_git_context_recovery.md).

## Start it

The stable development project has already been prepared. Terminal1:

```bash
cd /home/wayne/devel/jane/hardcaml_asic_example
opam exec --switch=5.2.0+ox -- python3 -B scripts/workbench_dev.py daemon
```

Terminal2:

```bash
cd /home/wayne/devel/jane/hardcaml_asic_example
opam exec --switch=5.2.0+ox -- python3 -B scripts/workbench_dev.py client
```

The daemon stays in the foreground and publishes an available port; the client
reads its endpoint. Reuse these exact commands on subsequent days. They select
matching captured binaries, pinned ASIC libraries/SDK and private fixed state.
Client startup never starts another daemon. No existing pair is stopped or
reconfigured automatically; exit an old client/server yourself if no longer needed.

Optional checks:

```bash
opam exec --switch=5.2.0+ox -- python3 -B scripts/workbench_dev.py status
opam exec --switch=5.2.0+ox -- python3 -B scripts/workbench_dev.py prepare
```

Repeated `prepare` verifies the prepared capture without rebuilding, recopying
sources or resetting state. The initial Runs/history can be empty; subsequent
work persists at the same project/state identity.

## What is available together

For the distinction between stimulus, workload, test/case, suite and attempt, see
[PT.8 terminology](pt8_workloads.md#what-workload-means-here). Workload requirements
include checking/measurement semantics beyond raw stimulus; existing Testing cases
execute them through the same FS2 runner. This session adds no arbitrary workload
composition API.

| Workflow | What to use |
| --- | --- |
| FIFO assertions/regression | Testing suite `controlled-fifo`, cases `directed` / `seeded` |
| FIFO options | Seed42 initially; `checker=normal`; cycles64/4096/20000 for seeded traffic |
| Deliberate checker failure | Same FIFO suite with `checker=mismatch`; one expected occupancy check is changed, not the DUT/stimulus |
| Memory implementation workload | Testing suite `pt8-memory-workloads`, `flops256` / `exact256`, supported fixed seed34097 |
| Workload results/comparison | Completed case → **Inspect workload result**, then explicit Workloads A/B capture and axis |
| Actual simulation traces | Testing Artifacts → **w** quick waveform / **Shift-W** dedicated Waveforms |
| Normal ASIC development | **Plan ASIC standard / balanced** → prefilled `synthesis` → preparation and launch controls |

Use **Space c c** for the command palette. The PT.8-specific fresh-launch shortcut
opens the shared Testing catalog; the catalog now contains BOTH suites. One FS2
attempt selects one suite; switching suites does not replace the shared history.

FIFO is the original real Cyclesim DUT with an independent ordered-list checker.
Its report records checks, seed, stimulus context and detailed failures. Its VCD
contains push/pop, occupancy, full/empty, data and acceptance behavior—not just
the six PT.8 interface signals. Directed exercises the full directed generator;
the cycles option controls seeded traffic only. A mismatch is a semantic Failed
case with a valid report/VCD, distinct from provider-process failure.

PT.8 still runs actual emitted Flops/Exact implementation RTL and unchanged stock
SRAM functional models. Its logical memory workload is fixed; other seeds/options
reject instead of being ignored. Result-reference JSON and VCD are distinct
case/attempt-bound artifacts. Inspecting a result or opening a waveform never
launches execution.

## Waveforms at a useful timescale

The initial extent targets **eight inferred clock periods**, only after bounded
consistent clock detection. A short trace explicitly says the target was clipped;
an ambiguous/irregular/missing clock falls back to Fit. The basis is a presentation
heuristic, not a new timing constraint or measured frequency claim.

- **f** — Fit the entire retained trace.
- **d** — return to the useful Default extent.
- **+ / -** — zoom in/out; **[ / ]** pan.
- **h / l**, arrows — move one **original VCD tick**.
- **:** — enter an exact original timestamp.
- **j / k**, Enter — browse and select signals as before.

Physical duration/timescale and exact cursor ticks stay visible. Requested bounds
survive resize. PT.8 opens around80ns instead of128ps; Fit covers the full13.07µs.
The real FIFO trace has its own1ns timebase and10-tick period; it also opens around
eight periods without altering its evidence timebase. No magic timestamp is needed
to make the clock visibly active.

Graph compression is event-aware: **`|`** marks a transition and **`#`** marks dense
multiple transitions within a display cell, including short pulses that return to
the sampled value. The UI states that dense ordering is hidden at that resolution.
Cursor values still come from original exact history. Unknown/uninitialized lanes
retain their marked row and exact X/Z values while known lanes remain visible.
This is not full temporal four-state plotting. Fit is bounded by events/payload,
not by allocating one sample per picosecond; exhausted limits report unavailable
without silently shortening the requested trace.

## Where to edit and how to refresh

The **editable source project** is:

```text
/home/wayne/devel/jane/hardcaml_asic_example/.dev/workbench-development/project
```

It is an independent source-complete development copy. The owner checkout's root
configuration remains unchanged, and edits in that checkout are **not automatically
mirrored** into this project. The launcher/status print the selected source root,
provider/environment and app identities. Captured source versus editable source
are identified separately; enclosing Git revision context does not certify the copy.

After editing the development copy, stop its daemon explicitly, then:

```bash
opam exec --switch=5.2.0+ox -- python3 -B scripts/workbench_dev.py prepare --refresh
```

Refresh builds a new immutable generation FROM those editable files and captures
the explicitly selected prebuilt Workbench app pair. It keeps the same project,
daemon state/history, result/artifact stores, client preferences and earlier
generations. Frozen simulation programs reject relevant source drift with this
refresh instruction instead of claiming to execute new source. Normal ASIC Fresh
preparation independently builds current editable source under its usual contract.

Failed refresh leaves the previous selection intact. An interrupted configuration
transaction blocks launch with an explicit recovery instruction; unknown config
edits are refused rather than overwritten. Refresh is refused while daemon
ownership locks are held. It never stops the daemon for you. Normal preparation
does not overwrite user source edits or import root changes. The explicit
missing-source/owned-support migration options are documented in the
[example handoff](../../hardcaml_asic_example/docs/workbench_development_handoff.md).

## Acceptance and provenance

Final prepared generation: `26f0d5e474bc4d45b5fc5859325c162d`.

| Captured app | SHA256 |
| --- | --- |
| Client | `896cee9b6546be5c5d7fcd132306a55cf33cbc43d1c25edbd7cea9c467bd7a42` |
| Daemon | `ec0108fd3ae65ac8bc8113462bfc1eb4dcdcbecf6410c144fbc982113f495a38` |

The corrected native acceptance runs in a separate private verification store;
it is not relabelled as an execution in the prepared user store. A final read-only
audit verifies identical app/child/provider/model/SDK bytes, equivalent configs
after explicit local-path substitution, and unchanged router runtime AST. The
router's final differences add authored-source inventory entries only.

Actual native evidence:

- `/tmp/opencode/development-c-native-09/receipt.json`: same-session FIFO pass/fail
  reports/VCD, both PT.8 cases, Workloads handoff/seven zero deltas, Default/Fit,
  resize and exact cursor; restart/artifact history/preferences and targeted rerun;
  standard source-only Plan/staging and private source build/elaboration emission.
- `/tmp/opencode/development-c-native-audit-09/receipt.json`: independently replayed
  retained artifact/trace/oracle evidence, without new hardware execution.
- `/tmp/opencode/development-c-waveform-deep-04/receipt.json`:86 adversarial checks,
  including high-int64 windows/cursors, subcell/same-time glitches, aliases, unknown
  excursions, narrow views, budgets and truthful clipped defaults.
- `/tmp/opencode/development-c-refresh-04/receipt.json` and `-05/receipt.json`:
  refresh preserves actual history/artifacts and detects source drift/options errors.
- `/tmp/opencode/development-c-installed-audit-03/receipt.json` and
  `/tmp/opencode/development-c-capture-smoke-01/receipt.json`: final capture audit,
  real native Discover/Plan and ordinary private test/asic_test/timing tests.

Independent lifecycle review passes38 original checks plus24 migration controls:
[backend review](development_session_backend_review.md). Its source-closure finding
is corrected: ordinary authored test/timing sources and the four required acceptance
harness files are included; retained snapshots/tools/builds remain excluded.
The example's12 direct/lifecycle tests cover catalog parity, genuine FIFO and PT.8
execution, cancellation, source drift, config rollback/recovery, edit preservation,
active-lock refusal and ordinary private Dune tests. See the example handoff and
`reviewdocs/tests/development-session-final-c.md` for exact invocation records.

Initial tests found and corrected a config symlink incompatible with FS2 nofollow
admission, the FIFO `text/x-vcd` MIME omission, a clipped-default cycle-label error,
and incomplete authored-source copying. Original failed attempts remain intact.
The PT.8 cancellation path now leaves terminal cancelled/incomplete ownership to
FS2 instead of emitting provider terminal events that its validator rejects.

Coordinator checked final stable status: both source-drift lists empty, no missing
source, fixed paths and pinned apps match the audited capture. Broad Workbench
`@all @runtest` passes with switch5.2.0+ox, explicit `-j2` and shared build lock.
All work stays within the shared job budget. No EDA, root-provider/config change,
Git publication, user-pair restart or historical evidence rewriting occurred.
User visual acceptance remains the next manual step.
