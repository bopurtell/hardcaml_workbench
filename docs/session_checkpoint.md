# Session recovery checkpoint — ASIC PT.0–PT.8 and Workbench

**PT.3 continuation:** Protemu PT.3a is now verified: public-API adoption, private
recorded ASIC dependency and explicit Flops/Exact `program` variants with deterministic
emission/resource proof. See [consumer evidence](../../hardcaml_protemu/docs/pt3a-adoption.md).
PT.3b vendor-functional loader/core/system regression is also verified; see
[functional evidence](../../hardcaml_protemu/docs/pt3b-verification.md). Next is PT.3c
physical and final-netlist acceptance. No physical EDA was run for PT.3a/b.

**PT.3c first physical attempt:** [actual-loader results and triage](../../hardcaml_protemu/docs/pt3c-physical-attempt.md).
The routed netlist passes independent functional replay, but physical acceptance
remains blocked by slow-corner setup (−4.0586 ns) and nine unresolved Magic markers.
The original failed run is preserved and all owned execution resources are stopped.

**Everyday launch update, 2026-11-11:** use the example's
[checkout-backed main launcher](../../hardcaml_asic_example/docs/workbench_main.md).
Its `daemon`/`client` commands open the actual repository and persistent local state,
without the acceptance session's synthesis-only envelope or `/tmp` dependency.
Root companion configuration is prepared/published with backups; actual startup
and discovery passed, with no physical flow launched. The earlier store04 commands
below open an independent copied acceptance project, not the owner's checkout.

**Latest update, 2026-11-10:** refactored-example developer workflow acceptance is
[complete in its bounded scope](developer_workflow_refactored_closeout.md): actual
TUI synthesis/collection, report/check inspection and same-store restart passed with
independent review. The paused acceptance and old temporary-store instructions below
are historical; the pre-crash `/tmp` evidence was lost and fresh store04 evidence
now owns closeout. No jobs remain running. PT.3 remains separate/pending, and broader
test expansion remains backlogged. Read the closeout before any resume/adoption.

**Snapshot: 2026-11-10. Read this first in a replacement session.** This is an
orientation/checkpoint, not a second active implementation queue. Revalidate current
source/status and ask which paused work to resume; do not automatically launch a
flow, rebuild the example or refresh a running owner's provider.

## 1. Authoritative context and read order

1. Workspace `/home/wayne/devel/jane/AGENTS.md`, then applicable repository
   instructions and `git status` before editing. The repos contain substantial
   staged/modified/untracked work and retained evidence. Preserve all of it.
2. [ASIC phase plan](../../hardcaml_asic/docs/phase_plan.md): **only active ASIC queue**.
3. [Workbench construction plan](construction_phase_plan.md): active Workbench queue.
4. [Test-refactor continuation](migration_guides/workbench-test-refactor.md): next
   Workbench-only restructuring, independent of the example's current refactor.
5. [Stable development session](development_session.md): operating model and paths.
6. [Paused developer acceptance handoff](developer_workflow_acceptance_handoff.md)
   and [resource handoff](developer_workflow_resource_handoff.md) if resuming real
   synthesis acceptance, not merely documentation/test organization.

Repositories in scope: `hardcaml_asic`, `hardcaml_workbench`, and, only when authorized
and coordinated, `hardcaml_asic_example`. **The example's verification suite is being
refactored independently.** Recent Workbench-only test organization did not inspect
or run it. Do not inspect/modify Protemu under these handoffs.

## 2. What the “nine-part suite” means

The owner is referring to the **PT.0–PT.8 feature track**: nine indexed entries,
not nine test suites and not the entire first-release deployment checklist.

| Entry | Capability | Recorded disposition |
| --- | --- | --- |
| PT.0 | Corrected SRAM feasibility/example evidence | Complete in revised example scope; original failures/qualifications preserved |
| PT.1 | Supported exact SRAM backend | Required scope complete; optional timed-model PT.1d deferred |
| PT.2 | Macro collateral and physical controls | Complete for stock256×16/R0 example fresh-full profile |
| PT.3 | Protemu adoption/system acceptance | **PT.3a/b verified; PT.3c routed functionality passes, physical acceptance blocked** |
| PT.4 | Resource declaration/preparation inspection | Complete in bounded library/example scope |
| PT.5 | Requested-versus-realized reconciliation/measurements | Complete in supported retained-evidence scope |
| PT.6 | Workbench Resources inspector | Complete in bounded inspector scope |
| PT.7 | Timing intent/endpoint declarations and traceable evidence | Bounded library/example scope complete; separate physical specimen qualification passed |
| PT.8 | Variants, verified workload/results and controlled comparisons | Bounded library/example scope complete; Protemu application/selection pending independently |

**Status vocabulary:** follow the [ASIC plan's status terminology](../../hardcaml_asic/docs/phase_plan.md#status-terminology).
Use **complete** for scope whose required implementation and acceptance gates passed;
use **implemented; acceptance pending** when required acceptance remains open.
Do not use “delivered” as a completion status. Scope limits do not make completed
work partial; PT.7/PT.8's separate open Protemu obligations must remain explicit.

No PT.9 has been adopted. Generic completion does not prove Protemu correctness,
timing adequacy or best configuration. Historical **ASIC P6** installation/source-
artifact identity/dependency/provisioning/independent-installation obligations remain
open at their recorded scope; see the link in the active ASIC plan. Don't confuse
ASIC P6 with PT.6 or Workbench feature-set numbers.

## 3. Completed user-facing integration after PT.8

The initial PT.8-only demos were consolidated into one stable development launcher:

```text
hardcaml_asic_example/scripts/workbench_dev.py
hardcaml_asic_example/.dev/workbench-development/
  project/          fixed editable source copy
  state/            durable daemon history/artifacts
  discovery/        daemon endpoint/ownership
  client-state/     persistent terminal preferences
  generations/      immutable app/provider/SDK/model/source captures
```

It exposes both `controlled-fifo` (directed/seeded, normal/mismatch checker) and
`pt8-memory-workloads` (flops256/exact256, fixed seed34097), normal ASIC source
Plan/Preparation, Workloads A/B comparison and exact case-bound VCD/result handoffs.
Refresh is explicit, stopped-daemon, preserves the same project/history/preferences
and refuses unknown edits. Root example sources are not automatically mirrored
into the editable private project. Do not assume this old layout/interface remains
unchanged after the independent example refactor.

Waveforms have useful clock-informed Default and whole-trace Fit while retaining
original tick cursor values. Compression is event-aware and marks dense transitions;
unknown lanes remain honest and local. **Owner deferred restoring connected Unicode
waveform strokes**; don't silently reopen that presentation task or blame Ghostty.

## 4. Terminology decisions to preserve

- **Stimulus**: raw operations/transactions/logical input data.
- **Workload contract**: stimulus plus execution assumptions/rules, completion,
  expected defined behavior and measurement rules/window.
- Reusable drivers, assertions/reference models/scoreboards and monitors implement
  the contract; no monolithic workload object or ownership of the whole environment
  is required. UVM sequences/items map to its traffic portion.
- Suite groups cases; case is runnable configuration/scenario; attempt is an actual
  execution. Current PT.8 cases each run one fixed multi-phase memory workload;
  arbitrary N-workload composition is not implemented.
- Tool tests and DUT verification are separate outcome axes. A faithfully displayed
  hardware failure can be a passing Workbench tool test.

Canonical explanation: [ASIC workload guide](../../hardcaml_asic/docs/guides/variant-comparison.md#terminology-stimulus-workload-test-and-suite),
[Workbench workload guide](pt8_workloads.md), [FS2 contract](fs2_simulation_contract.md).

## 5. Recent concrete defects and disposition

| Defect | Correction / remaining boundary |
| --- | --- |
| Config-only PT.8 private project could not stage standard ASIC source inputs | Source-complete private development project, explicit root/build paths and matching libraries |
| Blank endpoint prompt; remembered multiword assignments split | Catalog-derived initial choice and data-only quoted prompt roundtrip |
| JSON result reference opened as VCD; actual provider emitted no waveform | Independent real VCD publication and exact attempt/case selection, JSON Workloads route retained |
| Picosecond traces showed less than one clock period | Bounded event-aware physical-time Default/Fit, exact cursor preserved |
| Symlink config rejected by FS2 | Regular private configs with journal/rollback, no weakening of nofollow admission |
| Global GIT_DIR/WORK_TREE contaminated support-tools/PDK probes | Source-scoped real-Git dispatcher; actual collateral revision/status validation stays strict |

The Git-context fix passes independent installed preparation and public metadata
preflight, including genuine wrong-revision negatives. **That is not proof of a
completed synthesis flow.** Read [Git recovery](development_git_context_recovery.md)
and [independent review](development_git_context_independent_review.md) for exact
receipts. Original failed bundles/operations/captures were never relabelled.

## 6. Current pause: ordinary developer end-to-end acceptance

**Nothing from this session is running in the background.** The remaining work
was explicitly paused during the test-architecture discussion and example refactor.
Do not equate a pending/in-progress task card or a retained discovery PID with a
live test/EDA process. Recheck ownership/runtime if asked to resume.

Implemented phased harness: `scripts/test-developer-workflow.py`.

| Gate | Actual status |
| --- | --- |
| Real production startup and Testing forms, FIFO normal/mismatch reports/VCD | Passed |
| Both PT.8 cases, exact result handoff, seven zero A/B deltas and waveform checks | Passed |
| Simulation same-store restart/reopen/preferences/rerun | Passed |
| Source build/prewarm, Plan/staging and enabled synthesis launch control | Passed, readiness only |
| Fresh actual synthesis and its report/check inspection | **NOT RUN** in this acceptance |
| Post-synthesis same-store restart/reopen | Implemented route, **NOT RUN** |
| Complete acceptance independent review/closeout | Pending |

Exact pinned private test store: `/tmp/opencode/developer-workflow-store-01`.
Generation: `9d79963b4cd94c6190e9907a56683c9f`.
Final phase-1 receipt: `/tmp/opencode/developer-workflow-simulations-05/receipt.json`.
Native simulation receipt: `/tmp/opencode/developer-workflow-simulations-02/native-simulations/receipt.json`.
These are historical successful executions of those exact inputs, not a claim that
the refactored example or later Workbench source has already passed.
`/tmp/opencode` evidence may be absent after cleanup/reboot: recheck existence and
hashes before resuming. Missing receipts are not permission to overwrite/recreate
their old identities or assume a prerequisite passed on new inputs.

Actual TUI key actions are recorded separately from typed supporting RPCs and
direct provider/setup commands. A hand-sent RPC is not accepted as proof of a TUI
button/form. Existing raw keys/screens/HTTP/byte identities and failed receipts stay.

### Synthesis resumption constraints

- Do not run the positive synthesis phase merely because a command exists.
- It requires a passing pinned same-store prerequisite receipt, explicit allocation,
  runtime monitoring and coordinator activation. The historical immutable provider
  uses a six-worker bridge, not a supported two-worker knob. Docker quota alone is
  not a worker/thread guarantee. P&R is outside the authorization.
- Resource observer: `scripts/developer-workflow-resources.py`; negative-control
  script and metadata-only observations exist, but **no actual acceptance synthesis
  monitor attachment or native-worker ceiling proof has been completed**.
- Outstanding implementation/review concern in the resource handoff: acceptance
  must check BOTH monitor liveness and `stop-request.json` before/during execution;
  PID-only monitoring is insufficient. Revalidate this before activation.
- Recheck pinned script/source/app/provider hashes and owner generation. The harness
  contains exact captured-generation assumptions; changing them to new inputs is
  a new acceptance attempt, not permission to rewrite the old receipt.
- Current user example refactor can invalidate adapters, paths and case/parameter/
  artifact expectations. Resolve with its owner before real-example execution.

## 7. Parallel Workbench test-refactor checkpoint

**Latest owner priority:** remaining general test refactor and expanded segmented/
whole-flow coverage are [backlogged](backlog/tool-test-flow-coverage.md). Focus next
on the main PT.0–PT.8 completion work and required acceptance; do not automatically
resume test-infrastructure expansion from the historical pickup steps below.

**Continuation update, 2026-11-10:** explicit nested RPC budgets, shared PTY/screen
support and opt-in sandboxed native smoke are delivered. See
[current verification](test_refactor_verification.md). Backend/setup passed
separately at `-j1`, contracts/presentation/API at `-j2`, ten support tests and
seven native assertions passed. Disposable Git fixtures are now explicitly
permitted by the owner. `test/support/` exists; `test/integration/` migration is
still pending. The original first-slice snapshot below is historical. Its blanket
backend/API execution prohibition is superseded for the verified configurations;
combined aggregate parallelism remains unverified.

First bounded slice is complete: [root index](../test/README.md),
[ownership guide](testing.md), [inventory](testing_inventory.md) and
[selector verification](test_suite_selection_verification.md).

Six root suite aliases exist over current owned tests. Contracts and presentation
were forcibly rerun and passed. Backend/API/local were not executed in that slice
because of disposable Git fixture authoring and nested `-j20` paths; setup was also
not executed. Root fixture projects remain data-only; default runtest registration
is unchanged. Most inline tests still live beside their owners, and many native
scripts remain opt-in outside Dune.

**Next proposed restructuring:** bound nested test execution/fixture setup,
extract shared test-only support, register a Workbench-owned native smoke, then
move app-wide drivers in small batches. `test/support/` and `test/integration/`
are proposed destinations, not completed migrations. Follow the
[migration guide](migration_guides/workbench-test-refactor.md), not a mechanical
move of every test or automatic N×M expansion. Example-sensitive adaptation comes
after its verification refactor is understood.

## 8. Preservation, execution and next-session decision

- No Git add/commit/amend/push/config changes or cleanup of staged/untracked work.
  Another actor may stage/modify files; inspect and preserve, never assume ownership.
- Existing provider selections/configs/live owner daemon are not changed or restarted
  automatically. Read actual manifests when authorized; old generation names in
  documentation are checkpoints, not current-pointer truth.
- Global maximum20 concurrent jobs including other sessions and nested workers.
  Current safe Workbench-only commands use explicit `-j2` or lower, switch5.2.0+ox,
  `_build_pt8_workbench` and `/tmp/opencode/workbench-pt8-build.lock`.
  ASIC/example shared locks remain `/tmp/opencode/asic-pt7-build.lock` and
  `/tmp/opencode/example-pt7-build.lock` if that work is separately authorized.
- No EDA activation from documentation or test-organization tasks. Do not execute
  backend/API aggregates under the current policy until nested/Git-fixture issues
  are addressed. No Protemu work is implied.

**Ask which workstream to resume:** Workbench-only test restructuring (can proceed
independently), paused actual-synthesis acceptance (needs coordination/admission),
or later PT.3 consumer adoption. Do not silently expand one into another.
