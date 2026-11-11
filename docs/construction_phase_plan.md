# Hardcaml Workbench — Demo construction plan

New-session context: [cross-repository recovery checkpoint](session_checkpoint.md).
It summarizes the ASIC PT.0–PT.8 track, acceptance and preservation rules
without replacing this queue or the ASIC queue. Refactor continuation plans are
grouped under [migration guides](migration_guides/README.md).

## WB-049 common project configuration — 2026-11-11

Delivered `.workbench/` lookup for generic, ASIC, simulation and preparation
configuration, legacy compatibility, explicit conflict diagnostics and dry-run/
no-clobber copy migration. New initialization uses the common directory. Example
main/development launchers and FIFO setup support both locations and recovery.
[Migration policy, commands and verification](migration_guides/project-configuration.md).
Focused loader/backend/setup and script tests pass; no live configurations were
migrated and no real EDA was run. PT.3 consumer acceptance remains separate.

## Real fresh-prefix pyramid tests — 2026-11-11

Owner activated this bounded coverage item from the broader deferred test backlog.
[Runner/selection guide](real_prefix_pyramid.md) records eight explicit real endpoint
aliases and one serial pyramid. Default runtest/local/all excludes every real action;
only controlled harness tests are registered there. Persistent private evidence and
independent source state preserve the owner's main session.

- [x] Implement fresh independent rungs, exact-prefix/result checks and cleanup.
- [x] Register per-endpoint aliases and an explicit serial full-pyramid action.
- [x] Verify controls/default exclusion and actual real Elaboration/Synthesis.
- [ ] Execute the remaining physical endpoint rungs when explicitly selected.
- [ ] Execute the complete pyramid for a scheduled large-change qualification.

28 controls plus15 self-tests pass. Independent review substantiates the final real
Synthesis PASS. Floorplan through Signoff/full-pyramid execution is not claimed.

## Interactive endpoint rejection recovery — 2026-11-10

Owner's placement request in the synthesis-only accepted session exposed late
admission and a secondary observation error. [Fix and adoption handoff](developer_workflow_endpoint_rejection.md)
records early capability admission, definitive pre-execution rejection recovery,
retained checklist context and readable diagnostics. Independent backend/terminal
tests and actual retained-journal rendering pass. The live session remains on its
old captured apps until explicit stopped-daemon adoption; no physical run was made.

## Tool-test refactor continuation — 2026-11-10

**Owner priority update:** further general test refactoring and expanded flow
coverage are deferred to the [backlog](backlog/tool-test-flow-coverage.md).
Prioritize PT.0–PT.8 completion and its required acceptance; the unchecked follow-ups
below are deferred, not the active next implementation slice.

Owner authorized implementation with up to three implementation agents, a shared
20-job ceiling and disposable scripted Git fixtures permitted; owner-checkout Git
publication/authorship mutations remain prohibited.

- [x] Make nested RPC build budgets explicit and verify actual child argv.
- [x] Extract shared PTY/screen support with compatibility exports and helper tests.
- [x] Register an opt-in controlled native smoke with explicit sandbox dependencies.
- [x] Independently review and verify local groups under inspected execution budgets.
- [ ] Continue shared HTTP/process support and app-wide driver migrations.
- [ ] Reconcile external integration with the refactored example's current interfaces.

[Verification and execution limits](test_refactor_verification.md): backend/setup
passed separately at `-j1`; contracts/presentation/API passed at `-j2`; ten shared
support tests and seven native smoke assertions passed. The smoke stays terminal-
owned. `test/integration/` migration and combined local-aggregate execution remain
pending. No sibling changes or real EDA execution in this slice.

## Test organization alongside example-verification refactor — 2026-11-10

Owner requests clearer subsystem, shared-support and application-integration test
ownership, independently of the example's ongoing verification refactor.
[Bounded first restructuring plan](test_organization_plan.md) adds a test inventory,
root `test/` index and named selectors over current registrations, preserving all
fixture/evidence bytes and existing subsystem tests.

- [x] Document actual ownership/registration and example-sensitive boundaries.
- [x] Add explicit local suite selectors with fixture projects still data-only.
- [x] Verify selected Workbench-only suites and document remaining migration gaps.

No example changes, hardware verification or EDA; the developer synthesis acceptance
remains paused. Nested job-budget/Git-fixture constraints are documented rather
than hidden by an outer Dune limit.

Delivered first slice: [test ownership guide](testing.md), [root index](../test/README.md)
and [verification receipt](test_suite_selection_verification.md). Six named selectors
reuse current registrations; contracts/presentation forced reruns pass. Existing
fixture projects remain data-only and default runtest registration is unchanged.
Backend/API/local and setup execution are not claimed; nested-budget/Git-fixture
hardening, shared-support extraction and app-integration script migration remain
separate follow-ups. No example or hardware/EDA execution occurred.

## Completed ordinary developer workflow acceptance — 2026-11-10

**Refactored-example closeout:** [accepted capture, receipts and limits](developer_workflow_refactored_closeout.md).
Fresh simulation/readiness, real TUI synthesis and collection, report/check inspection
and same-store restart pass with independent evidence/resource review. Original
failed harness receipts remain failed; read-only continuations provide the remaining
inspection/restart evidence without rerunning producers. No P&R or Protemu work.

Owner authorized section-1 closeout: production client startup, FIFO pass/failure
investigation, PT.8 comparison, fresh synthesis, report/check inspection and
same-session restart/reopen. [Bounded acceptance and execution allocation](developer_workflow_acceptance_plan.md)
requires durable automated TUI tests with separately identified supporting RPCs,
one actual synthesis under the supported six-worker ceiling and no P&R.

- [x] Production startup/FIFO/PT.8 workflows and exact evidence associations.
- [x] Fresh synthesis through the TUI and actual report/check inspection.
- [x] Same-store restart/reopen, independent evidence/resource review and closeout.

Use only test-owned private state; existing live owner sessions/evidence remain
unchanged. Passing metadata/preparation is not synthesis completion.

The [phase-1 handoff](developer_workflow_acceptance_handoff.md) is historical.
Its lost pre-crash temporary store was replaced with new ownership-v1 captures,
explicit capability support and a kernel-enforced six-total-task synthesis envelope.
The [closeout](developer_workflow_refactored_closeout.md) is current authority for
executed acceptance. No acceptance jobs remain running.

## Development synthesis Git-context correction — 2026-11-05

Owner's synthesis attempt completed elaboration but failed collateral revision
admission. The development launcher's global source Git selectors contaminated
`git -C` support-tools/PDK probes. Corrected source-scoped real-Git dispatch keeps
revision checks strict and source context local. Independent installed preparation
and public metadata preflight pass on the retained user's bundle, with a genuine
wrong-revision negative still rejecting. No synthesis or physical flow was run.
The active user capture/history remains unchanged; adoption uses an explicit
stopped-daemon same-store refresh. [Recovery and evidence](development_git_context_recovery.md).

## Unified development session and waveform time navigation — 2026-11-05

Owner requests a coherent everyday example session, not another PT.8-only demo.
[Bounded implementation plan](development_session_plan.md) defines exclusive slices,
combined FIFO/PT.8 catalog, stable editable source/state and explicit refresh, and
bounded event-aware waveform Default/Fit over exact retained physical time.

- [x] Stable source-complete setup with pinned app/provider/library environment.
- [x] Combined real FIFO and PT.8 Testing suites, assertions/results/VCD handoffs.
- [x] Useful time-aware default, full-trace Fit, truthful compressed graph cells.
- [x] Real same-session UI/restart/refresh acceptance and independent review.

Existing root configuration/live pairs/evidence remain unchanged. No new EDA.

Delivered: [stable development launch/workflow guide](development_session.md).
Fixed editable project `.dev/workbench-development/project`, generation
`26f0d5e474bc4d45b5fc5859325c162d`, with captured matching apps and explicit refresh.
Native same-session FIFO normal/mismatch and PT.8 execution, useful waveform
Default/Fit and exact cursor, Workloads comparison, normal ASIC preparation and
history/restart/refresh gates pass. Independent waveform86 controls, lifecycle38
plus migration24 checks and final installed-capture audit pass after documented
corrections. Ordinary private test/asic_test/timing targets and coordinator
Workbench `@all @runtest` pass. Stable user daemon remains for manual launch;
earlier sessions/captures/evidence are preserved.

## PT.8 fresh simulation → Waveforms recovery — 2026-11-05

Owner found result-reference JSON opened as a waveform, with no VCD in the
attempt. [Bounded plan](pt8_waveform_recovery_plan.md) is delivered: explicit
six-interface-signal capture/publication, exact case/attempt VCD handoff, truthful
no-VCD availability and preserved JSON Workloads inspection. Mixed known/X/Z
windows retain known graphs and mark unknown lanes without inventing values.
Independent review corrected producer admission/publication and restored artifact/
palette membership gaps. Final real Flops/Exact direct cases and production
Testing→fresh Exact→quick/dedicated Waveforms pass in `session-waveforms-final-01`;
same-execution raw signal samples, original counters and standard public Plan pass.
See [final evidence](pt8_waveform_final_acceptance.md) and
[updated launch guide](pt8_workloads.md). Existing sessions/results remain unchanged;
no EDA or user-pair restart occurred. User visual acceptance remains manual.

## Standard Plan / private-session recovery — 2026-11-05

Owner reported blank endpoint input and failed staging in the provided PT.8
session. Corrected catalog-derived initial endpoint selection, retained failure
diagnostics and exact quoted-assignment roundtrips. The example recovery setup
now supplies independent source inputs and matching provider build environment.
Actual production-client Plan/Preparation staging and enabled Launch-and-view
controls pass against `session-standard-recovery-02`, without physical submission.
Both profiles × seven endpoints plan successfully; private source build/emission
and a fresh Exact workload pass. Original user session remains unchanged.
See [review and recovery commands](standard_plan_recovery.md) and
[independent endpoint review](pt8_endpoint_independent_review.md).

## Active PT.8 workload inspection and execution — 2026-11-05

User authorized the Workbench integration of the accepted PT.8 library/example
workflow. [Bounded plan](pt8_workloads_plan.md) owns shared APIs, exclusive slices,
isolated provider/session setup and acceptance. Existing configured sessions and
live daemons remain unchanged.

- [x] Public workload reader bridge and bounded async result/comparison cache.
- [x] Workloads workspace: explicit result imports, A/B captures, axis and reasons.
- [x] Example FS2 positive workload catalog, fresh execution and exact result handoff.
- [x] Independent review, real retained/fresh HTTP/PTY acceptance and launch guide.

No new synthesis/P&R/STA or Protemu scope. Provider-owned verification/deltas and
existing FS2 supervision are reused; root configuration adoption is separate.

Delivered 2026-11-05: [launch/acceptance guide](pt8_workloads.md). Corrected private
session `session-final-review-01` runs immutable provider generation
`ee3af8de9f83418b9afed9c67e473e3c`. Actual retained comparison and production-form
fresh Exact launch, digest-pinned artifact handoff and fresh-versus-retained
comparison pass; all seven workload metrics have zero deltas. Independent frontend
review78 controls and backend correction61 observations pass after six findings
were corrected. Full terminal and coordinator `@all @runtest` pass. Source/model/
trace audit and root-provider/config preservation are recorded in the guide.
Existing live sessions remain untouched; user visual acceptance is pending.

## Active PT.6 resource inspector — 2026-10-28

Owner authorized presentation of ASIC-owned requested/selected/realized resources,
physical measurements and sampled timing/electrical links. The
[integration plan](resource_inspector_plan.md) freezes provider/backend/UI ownership,
exact evidence targets, bounded queries and native retained-SRAM acceptance.

- [x] Public provider inspection bridge and typed Workbench source/cache ingestion.
- [x] Resource table, drilldown, source navigation and bounded comparison/controls.
- [x] Native synthetic and actual retained-example acceptance, independent review.
- [x] Broader checks, matching binaries and explicit provider/restart handoff.

Delivered 2026-10-28: final native bridge533, synthetic HTTP/PTY70, retained SRAM
HTTP/PTY52, unified-flow99 and saved-layout17 assertions passed, along with both
full suites. Independent peer recheck passed66 assertions after corrections.
Importing coarse historical evidence does not create a new physical run. Owner
explicitly approved changing only the example's configured provider executable to
final PT.6 generation `97b85a9e25e24615b758b97b21ca9697`; generation pointers and
old evidence remain untouched. Matching default app pair is built; live restart is
manual. See [controls/restart](resource_inspector.md) and
[acceptance](resource_inspector_acceptance.md) for scope and limitations.

## Active unified fresh-prefix workflow — 2026-10-27

Owner authorized Elaboration as the first peer workflow step before every fresh
physical prefix. [Implementation contract](unified_fresh_prefix_plan.md) defines
ownership, exact-bundle handoff, durable linkage, cancellation and acceptance.
This supersedes the earlier standalone-only preparation/fresh-launch separation.

- [x] Daemon-owned Elaboration → exact emitted bundle → physical-prefix chain.
- [x] All fresh launch routes and run-linked checklist/status presentation.
- [x] Failure/cancellation/replay/restart and native frontend acceptance.
- [x] Independent review, broader checks and matching app binary build.

No new ASIC physical-stage enum or implicit checkpoint-resume behavior is required.
Delivered 2026-10-27: 223 native scripted assertions, forced full build/tests/lint,
and independent adversarial review pass. Source-build/emit runs for each fresh
submission; replay retains the same workflow. Exact stage receipt ownership,
same-client retry recovery and capability-probe cancellation defects were corrected.
The standalone preview-ownership guarantee is preserved. After a real no-EDA
compatibility check, the owner explicitly approved updating the example's configured
physical provider to PT.5 generation `dd1ec9002cdc40f2936488cedd9eb0fe`; old generation
pointers/results were preserved. Matching default app binaries are built; restart
and real physical execution remain manual. See [controls and closeout](unified_fresh_prefix_plan.md#delivery-and-user-verification)
and [acceptance](unified_fresh_prefix_acceptance.md).

## Active Overview compression/title regression

Owner supplied live Overview state where Placement/Routing lose titles and show
generic finalization text after compression toggling. The
[regression plan](overview_compression_regression_plan.md) owns private reproduction,
render/policy correction and targeted state recovery. Preserve the user's layout
and all unrelated presentation choices; serialize verification at one job.

- [x] Diagnose and fix Placement/Routing title/body behavior.
- [x] Verify compression/persistence isolation and refresh retained client.

Saved header-off settings explain the absent titles; reproduction did not show
compression changing them. Enter/detail mode exposed a separate fallback bug that
discarded stage observations without finalization. Typed domain detail is restored,
Overview Timing now honors decimal precision, and boundary-safe decimal truncation
is regression-tested. Actual-state native replay and full single-job build/lint/tests
passed. See the plan for two targeted header toggles and client-only restart.

## Active WB-009 / WB-073 completion

Owner verified and closed **WB-069**, then authorized the remaining timing-report
triage and identifier-compression work. The
[completion plan](timing_triage_identifier_completion_plan.md) owns exact-evidence
boundaries, three-scope compression, collision handling and agent assignments.

- [x] WB-069 explicitly closed/verified by owner.
- [x] Resolve original WB-009 report from retained evidence or identify missing input.
- [x] Complete WB-073 scope/persistence and collision-safe Testing/identity rendering.
- [x] Serial one-job integration checks, deployment and status/evidence reconciliation.

WB-009 was traced read-only and the owner confirmed **Resolved by recent fixes**;
it is now closed/verified. Original exact run identity remains unasserted. WB-073
is now delivered awaiting owner acceptance: three scopes, schema-6 persistence,
collision-safe Testing/Session/Runs/Waveforms identities and native verification.
Full build/lint/tests passed at one job; retained binaries are refreshed.
See [compression controls and evidence](identifier_compression.md).

## Active Timing usability and preloading — 2026-10-23

Owner authorized the [Timing usability/preload plan](timing_usability_preload_plan.md):
configurable three-decimal display and compression, semantic colors, wider paths,
built-in Timing inspection, Overview/Testing/Waveforms/Timing order and bounded
background index preparation with explicit-only mode.

- [x] Presentation traits, colors and layout.
- [x] Built-in navigation/order and optional separate investigation lifecycle.
- [x] Source-fenced background index loading and explicit-only preference.
- [x] Integrated real-run verification, saved-state adjustments and deployment.

Delivered with serial single-job final verification after server-crash recovery.
Full build/lint/tests and changed-file formatting passed. Actual a023 hidden warm-up
loaded its 1,021 index rows with one provider read and zero detail reads, without
changing Overview focus or pins; switching required no further index read. Saved
built-ins now order Overview/Testing/Waveforms/Timing, with extras preserved, and
retained daemon/client/exporter binaries are refreshed. See
[controls and acceptance](timing_workspace_usability.md) for settings, receipts and
the pre-reboot VCD fixture limitation on full waveform acceptance.

## Active Timing workspace follow-up — 2026-10-23

Owner reports an unwanted simulation catalog in Timing and empty paths for the
latest `a023` Timing run. The [follow-up plan](timing_workspace_followup_plan.md)
owns membership/navigation diagnosis, retained real evidence and loading-policy
research. No physical rerun or new automatic preloading policy is implied.

- [x] Remove simulation catalog from Timing and verify saved-layout behavior.
- [x] Diagnose/fix actual-run empty paths and verify native inspection navigation.
- [x] Document current cache/loading behavior and recommend a warm-up policy.

Generic inspection incorrectly requested Signoff for the Timing-only a023 run.
Fixed exact target selection; private native UI displays its 1,020 paths plus input
reference. Hid only saved Timing catalog `tile-38`, preserving Testing and layout.
Full build/lint/tests and current/legacy native regressions passed. Retained client
is refreshed; only client restart is required. Background index warm-up remains a
proposal, not implemented behavior. See [findings and policy](timing_workspace_loading.md).

## Active executable Timing stage — 2026-10-21

Owner authorized extending WB-069 into a true provider stage/checkpoint. The
[executable Timing plan](executable_timing_stage_plan.md) owns boundaries, legacy
compatibility, agent ownership and verification. This supersedes the earlier
non-runnable restriction for new capable providers, while retaining historical
supplementary observations.

- [x] Provider seven-stage planning, execution/checkpoints and six-stage compatibility.
- [x] Workbench discovery, execution/analysis ingestion and exact-source inspection.
- [x] Single actionable Timing checklist row and explicit prepare/launch acceptance.
- [x] Integrated verification and updated controls/evidence documentation.

Full Workbench build/lint/tests, provider continuation/finalization/legacy suites,
11-check executable HTTP/PTY acceptance and complete checklist launch regression
passed. Historical selections can prepare NEW Timing runs using the current catalog.
The real example provider/project bindings and retained Workbench binaries are
refreshed; live daemon/client restart remains manual. See
[controls, deployment and evidence](executable_timing_stage.md). No physical EDA
flow was run; global formatting retains unrelated baseline differences.

## Active WB-069 Timing checklist and Overview — 2026-10-21

Owner authorized implementation of the [Timing plan](timing_checklist_overview_plan.md).
Delivery uses a supplementary end-of-segment STA observation, preserving completed
timing evidence after later signoff failure without adding an execution endpoint.

- [x] Provider retained STA observation and exact-source inspection.
- [x] Workbench typed ingestion, compatibility, refresh and cache fencing.
- [x] Separate Timing checklist item and richer Overview Timing tile.
- [x] Exact-source navigation, read-only actions and compact-layout verification.
- [x] Integrated regression checks and recorded acceptance evidence.

Three implementation agents maximum; shared worker limit 20; no staging, commits or
pushes. The detailed plan owns file ownership, contract decisions and test matrix.
Implementation and automated acceptance are complete: full Workbench build/lint/tests,
20-check final WB-069 HTTP/PTY acceptance, 135-check sidebar and 30-check launch-stage
regressions passed. See [controls and evidence](timing_checklist_overview.md) for exact
receipts, existing formatting failures and terminal-only/no-historical-backfill limits.
Owner visual acceptance and refresh of previously installed providers remain separate.

## Active WB-007 hierarchy tile — 2026-10-21

Owner authorized implementation on `bpurtell/hier`. The
[hierarchy tile plan](hierarchy_tile_plan.md) owns agent work packages, execution
budgets, selection semantics and acceptance gates. Scope is the opt-in hierarchy
module/tile and existing-inspector integration; WB-008 execution is separate.
Implementation and automated verification are complete. Normal build, full tests,
lint and changed-file formatting passed; native HTTP/PTY receipts are retained at
`/tmp/opencode/hierarchy-tile-w1de3jp1/`. See
[controls and acceptance](hierarchy_tile.md) for coverage and the unrelated
repository-wide formatting failures. Owner visual acceptance remains separate.

## Planning intake — 2026-10-17

The [WB feature catalog](features/README.md) now organizes the owner's new requests
as individually estimated tickets. [Intake traceability](features/intake.md) covers
all 62 submitted entries (61 unique features), plus four retained followups. See
[dependency handoffs](features/dependencies.md) before selecting an implementation
slice. This documentation pass activates no feature, performs no runtime acceptance
and changes none of the delivered milestones below. In particular, the new Timing
report is [WB-009](features/evidence/WB-009-timing-coherency.md), not a diagnosed
failure of all previously accepted timing evidence.

When work is explicitly selected, reference its WB IDs here and record the actual
acceptance evidence. Ticket acceptance checkboxes are proposed gates, not claims
that implementation has started.

Updated 2026-10-16. **FS0 Demos A–C and FS1's adopted-evidence functional scope are
delivered with explicit limits.** This is
the active status/checklist, replacing the October 12 P0–P7 plan in the
[archive](archive/construction_phase_plan_2026_10_12.md). The
[feature inventory](feature_list.md) owns product scope; the
[decision log](decisions.md) owns accepted D1/D2/D3 defaults and later policy.
M0–M5 are implementation phases, distinct from feature sets and ASIC phases.

FS0 covers M0–M3's functional slices, not every normative feature requirement.
FS1/FS2 map to richer M4 evidence and simulation; FS3 maps to M5 adoption.
FS5/V1 is an independent appearance gallery, not a functional-demo gate.
FS1's synthesis and aggregate terminal/physical investigation slices and FS5's
first appearance slice are recorded below. FS1's adopted-evidence functional scope
is now delivered, including richer paths, measured clock evidence, stage-specific
physical/routing investigation and external binary handoff. Later F06 extensions
remain separately qualified in the investigation record.
FS2 structured project-scoped simulation is now delivered; see the M4 FS2 record
and [FS2 acceptance](fs2_acceptance.md), added 2026-10-16.

## Evidence and candidate baseline

Use these records together rather than interpreting an old audit as current status:

| Record | Scope / retained evidence |
| --- | --- |
| [Environment inventory](fs0_environment_inventory.md#ready-executable-pair) | Exact executable paths, SHA-256 inventory, capture receipts, tools and wire versions; historical audit, whose pending-wiring/test notes are superseded below |
| [Provider integration](fs0_provider_integration.md) | Implemented API/configuration, supervision, summary identities, budgets and freshness limits |
| [Execution module](fs0_execution_module.md) | Protocol projection and daemon routing over the existing generic supervisor |
| [Terminal host](fs0_terminal.md) | Controls, ownership, launch policy, renderer coverage and known UI limits |
| [Installed checks](fs0_install_checks.md) | Native installed workflow, external fixture, legacy capture checks: all passed |
| [Native acceptance](fs0_acceptance.md) | Actual HTTP/PTY fixtures, real serial synthesis, allocation/detach, warm/restart identity and live cached UI reopening |
| [FS1 physical/terminal acceptance](fs1_acceptance.md) | Physical completion, independently accepted/rejected operations, cache reopening and real cancellation |
| [FS1 lifecycle/artifacts](fs1_lifecycle_and_artifacts.md) | Workbench-owned collect/accept, postcheck cancellation, bounded report reads and external text handoff |
| [FS1 investigation](fs1_investigation.md) | Current adopted-evidence completion, exact upgraded provider, timing/clock/physical/routing exploration, binary handoff and Escape responsiveness |

Historical FS0 accepted candidate (not the upgraded FS1 inspection provider, and
not an assertion that today's sibling HEAD was linked):

```text
project  /home/wayne/devel/jane/hardcaml_asic_example/_build_namedflow_real/default/bin/project.exe
SHA-256  5e8bdaab7dc4a5f5dbda8dae22a3e9946c4db09bf16951381d125a418d3a49b1
provider /tmp/opencode/namedflow-real-20261015/provider/bin/hardcaml-asic-flow
SHA-256  2c6604d355b819ee5cec8f731b4ba810ea9415ebf56f24ebac798a8d346bcdd5
tools    /home/wayne/devel/jane/hardcaml_asic_example/_flow_tools
```

Provider package `0.1.0`, CLI contract **4**, `namedflow1=true`; observation reads
v2, allocation v1, reports/historical methodology v1. Source stamping is absent.
The inventory records captured source checksum
`a12a763f842f283ab31649e8ded40786b304277f8e572d0f68e500e1fdc1686d`
and receipts under `/tmp/opencode/namedflow-real-20261015/`; package version alone
does not identify the linked source. The normal `.dev/asic/current` installation
is distinct from this explicitly selected pair.

Primary Workbench acceptance roots:

- `/tmp/opencode/workbench-fs0-91em64rl/`: fixtures plus real balanced **673** /
  synth_delay **685**, both completed, acceptance **`not_evaluated`**; early
  allocation while launcher executing, submission-client detach, durable contexts,
  pins and L2 identity. `real/verified.json` and `outcome.json` retain results.
- `/tmp/opencode/workbench-fs0-unzwt0kn/`: actual 120×40 cached real UI reopening;
  **673 → 685**, pin back to **673**, then **pinned 673 beside following 685**;
  current-screen assertions, unchanged run registry and restart restoration.
- `/tmp/opencode/workbench-fs0-etbs6c68/`: strengthened fixture-only verification.
- `/tmp/opencode/workbench-fs0-6_1ymcsd/`: initial fixtures and preserved real
  preallocation timeout-CLI failure; successful rerun preserved its configured
  `results/` root. The authorized config correction sets stage timeout to `()`.

Exact run/report paths, plan identities and normalized report digests are in
[acceptance](fs0_acceptance.md#successful-real-rerun). Real report-call counts are
not instrumented; fixture warm/restart report calls remain **2 → 2**. Timing `[]`
means unsupported, and synthesis counts are checkpoint-boundary measurements,
not signoff acceptance or per-step attribution.

Final parent validation passed, serially: `dune build -j20 @fmt @lint`,
`dune runtest -j20`, `dune build -j20`, then current HTTP/PTY fixture acceptance
(`/tmp/opencode/workbench-fs0-botbl2jn`), installed native application checks and
legacy baseline checks. The installed PTY test now selects attempts by their exact
submitted IDs and checks full repaints, not incidental ANSI delta retransmission.
External counter fixture acceptance also passed. No additional real EDA was needed
after the recorded two-profile acceptance and real cached-screen verification.

### Takeover reconciliation — 2026-10-15

The checkout was clean at `560ad8f` when inspected; the handoff's uncommitted-work
description was historical. Read-only execution and adopted-provider reviews found
stale FS1/FS5 status statements in the documentation index/inventory, corrected to
match the delivered slices below. No provider adoption or new EDA was performed.

Fresh parent verification, serialized through `scripts/with-switch.sh`:

- `dune build -j20 terminal/main.exe daemon/main.exe` passed.
- `python3 -B scripts/test-terminal-interrupt.py` passed all five cases, with clean
  client exit, restored ISIG/ECHO/ICANON, and the private daemon surviving each client.
  Evidence: `/tmp/opencode/workbench-terminal-interrupt-tb4fj7ht/`.

The inspected regression creates its own metadata-only project, client directories,
state and daemon under a new evidence root; it submits no jobs and performs no Git
operations. This is actual frontend/HTTP behavior over a disposable fixture, not
real synthesis evidence or a full tmux/concurrent-client responsiveness acceptance.
Earlier full-suite and real-tool results above remain historical evidence.

During FS1 integration the owner advanced HEAD to `1a3df25` ("Staging for fs3
parallelization"). Integration preserved that current tree; no agent-created
commit, staging or other mutative Git operation was performed on a live checkout.

## M0 — Decisions, provider baseline and demo fixtures

Features: F01–F06, F09–F11. **Delivered baseline; remaining coverage is explicit.**

- [x] D1: shared Main contexts, independent/relink, multiple selectors and tile pins.
- [x] D2/D3 FS0 defaults approved by the owner's initial **Approve scope** answer:
  captured/revalidated targets, no missing-flow fallback, ordinary launch does not
  select, launch-and-view selects only matching captured revisions; follow/pin-run
  first, immutable snapshots deferred.
- [x] Record explicit candidate executables, hashes, tools and supported wire versions.
- [x] Verify discover/describe/plan/run/observe/report through fixtures and actual
  installed-provider HTTP synthesis. Use returned exact allocation/report references.
- [x] Retain two distinguishable fixture and real runs; backend fixtures cover
  preallocation failure, malformed output, timeout, cancellation, changed/missing
  evidence and cache races. Existing counter fixture remains available.
- [x] Bound the demo to synthesis; expose cell count/breakdown, provenance,
  completion, acceptance and freshness; mark unsupported timing honestly.
- [x] Specify cache keys, source/revision invalidation, missing-source and
  schema/corruption behavior. No cheap provider revision query is available.
- [x] Generic project-scoped Dune test path and deterministic supervisor fixtures;
  installed counter tests and actual HTTP generic test pass without ASIC tools.
- [ ] Complete a single end-to-end matrix for late-response, reconnect, failure and
  cancellation cases across interactive and concurrent clients. Existing focused
  tests cover subsets, not every permutation.

## M1 — Module/command contracts and headless ASIC path

Features: F01/F02/F03/F05/F06/F09/F11. **Demo A delivered.**

- [x] `protocol/execution.ml` projects exact project Build/Test attempts;
  `backend/execution_module.ml` delegates to `Service`. Daemon submit/cancel/log
  handlers route through it; no second scheduler, job store or inferred test cases.
- [x] Daemon-owned ASIC service: four bounded public queries, one launcher,
  coalesced cold reads, automatic reader after persisted allocation, cursor fences.
- [x] L1 decoded summaries (32), L2 indexed summaries (128), bounded payloads and
  explicit retention limits; tiles do not own provider processes or execute EDA on read.
- [x] Typed terminal command catalog, captured target/revalidation, availability,
  shared Build/Test/RTL/cancel actions, exact preview and launch idempotency keys.
- [x] Generic test attempts/status/log/cancel retain project scope, submission
  identity and the existing supervisor's process lifecycle.
- [x] ASIC discovery, description, explicit flow/profile/endpoint preview, exact
  identity-guarded synthesis launch and early allocation without fabricated IDs.
- [x] Durable observation/read-updates and exact report references; distinguish
  command state, execution completion and acceptance. Client detach preserves work.
- [x] Project synthesis resources into shared summaries with checkpoint origin.
- [x] Fixture-owned process cancellation/deadline/output bounds; generic supervisor
  retains descendant cancellation coverage.
- [x] Extend fixture cancellation to real owned backend/container and external-
  postcheck cancellation specimens in M4. ASIC cleanup signals only owned PIDs;
  stopping a reader is not producer termination. Broader boundary/race permutations
  remain M4 coverage followups.

**Demo A:** native HTTP client discovers/previews/runs both real synthesis profiles,
observes allocation before launcher completion, detaches, and retrieves exact reports.

## M2 — Tile host, named arrangements and palette

Features: F02–F06/F09–F12 (minimal F12 seams). **Demo B delivered.**

- [x] Separate transport ownership, pure host reducer/local state and typed rendering.
  Daemon/project/request-order and binding/selection guards reject stale responses.
- [x] One daemon-owned semantic registry: stable session/window/workspace/tile/context
  IDs, Overview/Timing linked to Main, independent/relink and exact per-tile pins.
- [x] Selectors share selected run, retaining local cursor/filter/scroll/focus.
  Moving following tiles adopts the destination context; pins remain exact.
- [x] Tile add/hide/restore/move/reorder/resize/zoom; shelf order/preferred sizes,
  compact focused-tile fallback, with no backend lifecycle side effects.
- [ ] Freeform x/y placement and richer geometry interaction. Stored geometry fields
  do not make the shelf renderer a free-positioned layout system.
- [x] Provisional semantic-role skin, configurable local headers/chrome, mountable
  navigation/status, commands/recovery without chrome, clipped narrow rendering.
- [x] Ches single-transient lifecycle reviewed; bounded palette capture/return focus
  and paste suppression implemented locally. No general float manager claimed.
- [x] `Space c c` palette with effective targets, typed actions and availability;
  remembered explicit launch inputs are persisted independently of inspected runs.
- [x] Run selector, execution/log/project-test/synthesis/evidence tiles and preserved
  legacy RTL/artifact/hierarchy inspector with return to host.
- [x] Reducer/renderer tests cover modal input, delayed-view guards, linkage/pins,
  switching, clipping and local state. Native PTY checks cover real host transport,
  installed discovery/hierarchy and resize down to 1×1.
- [x] Fixture warm A/B switching uses no new report calls; actual cached real UI
  shows 673→685 and pinned 673 beside following 685 with explicit scope/freshness.
- [ ] Expand actual frontend concurrent-client, pending-response, reconnect-during-
  allocation and interactive launch-and-view/cancellation coverage. HTTP Run and
  RPC-driven live selection do not prove every interactive launch path.
- [ ] Measure high-tile-count fan-out, responsiveness, latency and memory/disk use.
- [ ] Fully reactive publication/redraw and richer capability-aware endpoint forms.
  Domain refresh remains clock-driven; local input/deferred completion now invalidates
  the view immediately. Time-dependent displays retain a clock. Assignments are
  whitespace-separated.

**Demo B:** linked/independent workspaces, following/pinned synthesis comparison,
palette operations and project-scoped tests/logs are delivered. Synthetic renderer
fixtures (50/73) and actual real UI evidence (673/685) are separately labeled.

## M3 — Historical reopening and saved arrangements

Features: F04/F05/F10/F11. **Demo C delivered via autosaved session state.**

- [x] Persist bounded run registry/index and versioned normalized L2 summaries
  outside provider results; atomic publication, corrupt/incompatible handling.
- [x] Reopen explicit known provider references after restart without tool execution.
  Broad provider-store discovery is unavailable; no guessed newest directory.
- [x] L2 loads avoid public report materialization and show `Cached_unverified`.
  Fixture refresh/missing/corrupt/eviction tests exist; real warm/restart summaries
  preserve every field except freshness, including original observation time.
- [x] Autosave named workspaces, tile order/hidden/size/zoom/bindings, Main linkage,
  independent contexts and selected exact run references. Actual restart restores
  the full workspace snapshot, including the two-tile real demo.
- [x] Separate semantic registry from client focus/filter/scroll/dimensions; clamping
  stays local. Interactive launch inputs have a separate client preference store.
- [x] FS3 CLI template export/import/clone separates portable layouts from personal
  session state; generic/ASIC starters included. TUI template browsing remains later.
- [x] FS3 persists explicit client appearance, layout mode, chrome/header choices in
  a separate project/environment-scoped store; transient navigation stays local.
- [x] Later observations invalidate freshness; explicit Refresh materializes current
  public reports. Missing-source/refresh-failed data remains labeled.
- [ ] Benchmark cold/L1/L2 latency and sizes; expand full missing-reference and
  schema-change interactive restoration coverage. No speed target is asserted.
- [x] Preserve existing hierarchy current/historical evidence labeling in installed
  checks rather than relabeling old hierarchy as a newly selected run.

**Demo C:** daemon restart restores contexts/pins/arrangement and reopens exact
cached real summaries without EDA. Immutable snapshots/archival retention are
deferred by accepted D3 scope, not missing FS0 implementation.

## Remaining FS0 followups

Dashboard usability correction (2026-10-15): the saved acceptance state's empty
Overview was traced to its selector-movement test. Startup now distinguishes loading
from an empty saved arrangement. Fit-to-window is the default local layout mode;
the additive Overview preset supplies 13 views including honest unrequested/
unsupported stages. Requested shelf sizes remain selectable and persisted pins
unchanged. Actual PTY reproduction over a private state copy passed with real
cached 673/685 evidence, all five skins and no provider/result changes:
`scripts/test-fs0-dashboard.py`, `/tmp/opencode/workbench-fs0-dashboard-52akmtcc/`.
Terminal tests, format/lint, installed workflow and legacy baselines passed.

**Owner review, 2026-10-15:** the user reports the Overview works and content renders
correctly inside its tiles. The row/grid arrangement and visual styling are accepted
only as provisional demo presentation, not the intended final layout/aesthetic.
Raw JSON and absolute paths in producer/source provenance are too verbose for the
overview. Follow up with concise semantic labels and an inspectable full reference
(F06/rendering); this does not block the next domain slice. This feedback records
human functional acceptance of the viewed Overview, not broader flow/signoff coverage.

The unchecked M0–M3 items are bounded followups, not grounds to label delivered
demos “not started.” Final parent-wide checks passed. Prioritize missing interactive
race/reconnect/launch-and-view/cancellation coverage, then measured scaling and
adoption choices. FS3 supplies CLI templates and persisted local chrome; freeform
geometry and richer endpoint forms remain explicit gaps; domain refresh remains clock-driven,
with immediate local input/completion redraw after the Escape-latency followup.

## M4 — Rich evidence and live acceptance (FS1/FS2)

### Native project provider adapters — 2026-10-18

WB-066 delivered: separate public provider package with shared FS2v1 types and
validators, synchronous runner, native project-owned `test_provider.exe` wrappers
for real FIFO and counter examples. Standalone simulator/checker implementations
remain independent. Frozen encoding, native/Python equivalence, private HTTP and
restart, installer and full normal checks pass. The owner-approved real native
generation is installed with persistent backups; live daemon/state and physical
evidence are preserved. [Plan and exact evidence](native_provider_plan.md).

- [x] Owner manual workflow acceptance and WB-066 closeout, 2026-10-19. The owner
  reported the native-provider workflow works and requested completion marking.

### Testing adoption/investigation cluster — 2026-10-17

Activated WB-034, WB-032 and WB-063; [shared plan](testing_cluster_plan.md),
[current user guide and evidence](testing_workspace.md).

- [x] Genuine FIFO directed/seeded Cyclesim adapter with native VCD/reports,
  full-uint64 seed mapping, explicit checker-only mismatch and preserved ordinary
  CLI/Dune tests. Persistent installation/configuration in the actual example.
- [x] Explicit suite/case catalog, subset/filter/defaults, stale-discovery disabled
  reasons and exact captured suite/selection/digest command revalidation.
- [x] Cooperative Catalog/Attempts/Cases/Detail/Artifacts/Logs with client/workspace
  investigation, independent tile scroll, one request stream and lifecycle fences.
- [x] Typed cursor-follow and compact artifact navigation at normal/narrow sizes;
  generic tests/legacy simulation stay independent, old arrangement extras preserved.
- [x] Final normal format/lint/full tests/build at20; real FIFO native proof and
  synthetic/FS2/checklist/indicator/interrupt regressions pass with private state.
- [ ] Owner visual/workflow review of the new Testing composition. WB-063 remains
  partial for that explicit gate only; implementation and automated proof are complete.

Definitive real proof: `/tmp/opencode/fifo-testing-wx4xhzjp/` (21 cooperative
assertions plus6 actual geometry checks). Synthetic cooperative proof:
`/tmp/opencode/testing-workspace-w56bs6_c/verified.json` (15 checks). Broader receipts
are in the shared plan. No physical EDA, live investigation reset or Git authorship
operations occurred; the original FS2 milestone remains accepted and closed.

### Real checklist preparation/launch followup — 2026-10-17

[Workflow and evidence](checklist_launch_workflow.md),
[shared plan](checklist_launch_workflow_plan.md).

- [x] Normalize declared fresh-prefix endpoints and actual catalog default pair;
  unknown providers retain explicit Plan/Run without guessed stage actions.
- [x] Checklist j/k/r captures inputs and performs bounded capability discovery
  when needed, then normal Plan; profile/assignments and exact target are preserved.
- [x] Launch/Launch-and-view remain visible disabled with reasons until a current
  exact preview is ready. Failed/superseded preparation cannot launch an old plan.
- [x] Actual cold-daemon real Routing preparation and negative target/capability
  cases; synthetic-only full launch/allocation. Final normal acceptance61 assertions
  at `/tmp/opencode/checklist-workflow-7dbc9ab8d388/`; full checks passed at2.

Persistent binaries were refreshed without changing live user sessions. No real
EDA, canonical-result edits or Git staging/commits were performed. This resolves
the stage-action gap noted in the earlier consistency/adoption records below.

### Real launch/checklist consistency followup — 2026-10-17

Fixed after owner real synthesis launches exposed retained-plan and stage-contract
gaps. [Semantics, evidence and restart instructions](launch_stage_consistency.md),
[shared implementation plan](launch_stage_consistency_plan.md).

- [x] Separate preview readiness from exact durable launch reservation/allocation and
  producer lifecycle; no false “no job allocated” statement after submission.
- [x] Normalize supported public schema3 recipes and exact stage occurrences when
  the optional stage-plan extension is absent; preserve cursor/identity fences.
- [x] Verify both owner synthesis streams as synthesis completed/other five not
  requested, and retained signoff as six explicit completions; canonical files unchanged.
- [x] Full normal format/lint/tests/build at2; final native acceptance27 checks at
  `/tmp/opencode/launch-stage-consistency-a2201a488574/`, lifecycle/regression tests,
  and refreshed persistent demo copies with actual-project acceptance.
- [x] Subsequent checklist workflow resolves fresh actions from explicit project
  capability declarations, not stage status. No implicit resume/launch behavior.

No EDA rerun, provider installation or live user-session mutation was needed.
Earlier “not reported because stage_plan is absent” notes describe the previous
adapter; explicit structured occurrence normalization is now supported.

**FS1 adopted-evidence functional scope delivered: synthesis, aggregate and rich inspection.
FS2 substantial project-scoped simulation delivered.** Exact commands/results are
in [FS1 acceptance](fs1_acceptance.md) and [FS2 acceptance](fs2_acceptance.md).
Features: F06/F09 and execution/regression extensions.

- [x] F06 synthesis inspection over existing cache: count/name sorting, literal
  filtering, stable selected row, count/share detail and full evidence inspection.
  Concise summary labels replace raw producer JSON/absolute-path dumps.
- [x] Validate local state across sort/filter and run/digest changes, missing/zero/
  mismatched totals, overflow handling and independent pinned views. Actual 120×40
  PTY uses real cached 685/673 totals and checks a cell count changing 58→56.
- [x] Verify no provider work is caused by inspection: private-daemon syscall trace
  after cached load has no subprocess launches or provider-result access; original
  state/config/results unchanged. Evidence:
  `/tmp/opencode/workbench-synthesis-inspector-pmzn1twc/`.
  Format/lint, repository unit tests and full build passed serially at `-j20`.
  [Controls/test command](synthesis_inspection.md).
- [x] Hidden-filter recovery followup: persistent filter-input indicator, displayed
  query/match count and Ctrl-U clear, verified through actual PTY after polling.
  The reported apparent crash was not confirmed as process termination: live client/
  daemon remained running and hello responded. See synthesis inspection evidence.
- [x] Subsequent input-hang report reproduced a real Ctrl-C routing defect in raw
  mode. Interrupt now precedes filter/palette/paste capture. Actual PTY before/after
  matrix verifies all five cases exit and restore terminal settings while the daemon
  remains alive. `scripts/test-terminal-interrupt.py`; details in synthesis inspection.

- [x] Synthesis area and diagnostic counters with explicit units, availability and
  checkpoint references; choose the explicit synthesis boundary even after later
  physical failure. Old cache versions remain readable with semantic repair.
- [x] Explicit finalization import validates execution/results hashes, structural
  execution identity and selected checkpoints. Persist the exact operation for
  Refresh; ordinary viewing/restart uses the bounded shared cache.
- [x] Aggregate setup/hold, final physical area/utilization, reported DRC/LVS/antenna
  statuses and full source/context inspection. Preserve distinct execution,
  collection, timing-goal, postcheck and acceptance facts.
- [x] Verified historical declared-clock configuration, not measured CTS or coverage.
- [x] Actual native HTTP/PTY import of collection-only, accepted and rejected
  operations; independent tiles/pins, exact reference form, restart/L2, no warm
  provider reads, Unicode/paste entry and bottom/reverse-scroll recovery.
- [x] Retained setup/hold path tables with corner/group/producer/stage selection,
  literal filtering, numeric/name sorting, violated/near-limit filtering and
  source-fenced detail. Real acceptance independently checks all 1020 path spans.
- [x] Measured clock latency/network skew and setup/hold check skew, supplied
  source/generated headers and relationships, propagation/coverage excerpts and
  explicit conflicting-header diagnostics; absent relationships are not inferred.
- [x] Stage-specific die/core/cell/macro/placement metrics and global/detailed
  routing/congestion tables with original units, step/occurrence and carry-forward
  attribution. Native repeated/nonfinite metric diagnostics remain explicit.
- [x] Byte-preserving bounded binary transfer and configured terminal-host external
  opening. Actual exported GDS SHA-256 matches; installed KLayout loads it headlessly.
- [x] Project-declared simulation/regression cases, seeds and failure/trace artifacts;
  actual Cyclesim and native HTTP/PTY acceptance recorded below.
- [x] Bounded terminal-result report/artifact catalog and text paging, exact
  run/attempt/hash/offset/limit identity and explicit stale/expired-page recovery.
  Optional external text opening exports verified sanitized text to the terminal
  host before invoking a configured executable, never opening a daemon path locally.
- [ ] General source viewers, embedded graphical artifact rendering and provenance
  navigation beyond the selected adopted terminal result.
- [x] Real synthesis→floorplan→placement→CTS→routing→signoff completion; separate
  external precheck/gate-level acceptance pass. Earlier 600-second signoff timeout
  remains retained, with earlier synthesis evidence visible through Workbench.
- [x] Actual Workbench signoff launch/client detach/cancel of a confirmed active owned
  container. Launcher stop grace increased from 5 to 15 seconds so provider cleanup
  and terminal publication finish. No owned survivors or later-stage launch.
- [x] Finalization/acceptance producer lifecycle inside Workbench: explicit collateral,
  persistent exact-key reservation, early allocation, phase/status, client detach,
  owned cancellation, automatic validated result import and restart without replay.
- [ ] Cancellation coverage at every physical boundary and broader concurrent
  reconnect/publication race combinations.

**Parent verification:** format/lint, full build, full `runtest -j20` and installed
native lifecycle/RTL/hierarchy/resize checks passed serially. Latest retained real
UI tests: metrics `workbench-fs1-metrics-c00xpq9e`, accepted physical import
`workbench-fs1-terminal-results-5yvke5ek`, original synthesis inspector
`workbench-synthesis-inspector-xf0ihqfd`, interrupt matrix
`workbench-terminal-interrupt-rxwy7wd1` (all under `/tmp/opencode`). Real owned
cancellation passed at `workbench-fs1-cancellation-nyiu2n23`.

**Provider/flow evidence:** unchanged installed provider; only the example launcher
was rebuilt in `/tmp/opencode/fs1-timeout-project-SAuuX0/build` to expose its existing
stage-timeout flag. Successful physical evidence is
`/tmp/opencode/workbench-fs1-physical-w0rftdi0`; setup **11.67551954830797 ns**, hold
**0.12502899069955042 ns**, final area **18916.9 µm²**, utilization **0.0209625**.
Collection acceptance is `not_evaluated`; the separate explicit acceptance operation
at `/tmp/opencode/workbench-fs1-acceptance-5oa67d8u` reports **pass**, with TT precheck
and gate-level replay passing. This is not a universal signoff assertion. Exact
identities, failed attempts and remaining scope are in the linked acceptance record.

**Lifecycle/artifact followup delivered:** [controls and evidence](fs1_lifecycle_and_artifacts.md).
Actual palette→daemon→provider collection, acceptance (**pass**) and cancellation
during external postcheck passed in separate private evidence directories:
`/tmp/opencode/workbench-fs1-lifecycle-qkm54grn`, `...-2p10_520`, and `...-wtprmfgc`.
Each has one producer, unchanged canonical inputs, no owned survivors and restart
without replay. Artifact reads launch no provider work. External text handoff was
verified with a local observer executable, not a claim about a real GUI renderer.
Final format/lint, full build/runtest, installed workflow and five-mode interrupts
passed after integration. No provider upgrade or new physical implementation run
was needed for that lifecycle followup.

**Final FS1 investigation delivery (2026-10-16):** [scope, controls and evidence](fs1_investigation.md).
Provider-owned `inspect` schema 1 is installed privately at
`/tmp/opencode/workbench-fs1-inspection-provider/generations/59466eda06df463e8d921678830ff5c2`.
Its receipt identifies captured snapshot `0423a76848cdc41f79ec5fd67502445b08b783050d8eba9de83991e8550cda09`,
not an authoritative linked-source stamp. All four domains passed actual HTTP/PTY
and L2 restart acceptance at `/tmp/opencode/workbench-fs1-investigation-hd0uuqio`;
binary handoff preserves the exact GDS bytes, and actual headless KLayout loading
passed. Original provider results/config/state were unchanged. The owner's existing
example config was initially left pinned to its prior provider. A subsequent manual
demo reported `invalid command: inspect`; its provider setting was then updated to
the verified generation above. The active owner processes were not stopped. Restart
and explicit re-registration preserve the saved workspace and adopt the new config.

Final provider focused tests, Workbench format/lint/full build/full runtest,
installed native workflow, five-mode interrupts (`...-xth8tynj`) and original
synthesis inspector (`...-arle_91_`) passed. Inspection is read-only over the
previous physical run; no new physical/signoff execution was needed. Embedded
graphical editing, spatial heatmaps and unsupported source mapping remain F06
extensions, not inferred capabilities of these tables or the external handoff.

### FS2 substantial delivery — accepted and closed 2026-10-16

Shared [implementation plan](fs2_implementation_plan.md),
[provider/RPC contract](fs2_simulation_contract.md), and
[controls/acceptance](fs2_acceptance.md).

**Milestone closed: structured project-scoped simulation delivered and accepted.**
The owner reported the basic demo works and authorized closeout. This is scoped
manual launch/view acceptance, complementing the automated evidence below.

- [x] Versioned companion simulation configuration and explicit bounded discovery;
  suites/cases, canonical uint64 seeds and parameters remain project-owned.
- [x] Existing-supervisor discovery/run jobs, per-root admission, logs, deadlines,
  process-group cancellation, captured launch inputs and durable idempotency.
- [x] Validated live events and bounded normalized detail; process outcome remains
  separate from semantic cases. Malformed/truncated/duplicate streams are incomplete.
- [x] Terminal launch form, attempt/case investigation, wrapped failure detail,
  stream-labelled logs, independent tiles, cancellation and targeted reruns.
- [x] Current-project reruns preserve original inputs and immediate parent identity
  while creating a distinct job; original attempts remain retained within bounds.
- [x] Workbench-owned bounded history/artifacts reopen after restart without replay;
  unfinished history becomes interrupted, missing/corrupt evidence is explicit.
- [x] Attempt/case-owned raw artifact transfer and terminal-host export/viewer action;
  full SHA256 and page identity/size checks, actual Cyclesim VCD handoff.
- [x] Real PDK-free Cyclesim example, deterministic failure/race fixtures, actual native
  HTTP/PTY integration, full format/lint/runtest/build and existing interrupt matrix.
- [x] Record scoped owner acceptance and transfer additional adoption, performance
  and simulation capabilities to [named followups](backlog/fs2_followups.md).

Generated-RTL/gate-level adapters, archived replay, embedded waveforms and ASIC
acceptance contribution are separately activated followups, not open milestone
checkboxes. The owner retains Git integration; the
[post-integration verification handoff](fs2_acceptance.md#integration-handoff)
does not claim the main branch is already updated or tested.

Final combined checks passed serially through `scripts/with-switch.sh` with `-j 20`,
build dir `/tmp/opencode/fs2-build-backend`. Final reviewed HTTP/PTY evidence:
`/tmp/opencode/fs2-native-yx27d5_b/result.json`, **45 checks passed**. Real standalone
Cyclesim proof: `/tmp/opencode/fs2-provider-tzid09_h/` (12 case executions, 768 cycle
comparisons). Five-mode interrupt regression: `workbench-terminal-interrupt-ou1stfm9`.
No full ASIC flow, sibling source changes, staging, commits or pushes were needed.
Retention and slow-storage responsiveness limits are explicit in the acceptance record.

### Inspector input responsiveness

**Inspector Escape responsiveness:** the manual demo's delay was reproduced as
tmux's 500 ms Escape wait plus the former 100 ms input repaint dependency. The
client now invalidates its view immediately for local navigation and deferred
completion. Actual private-tmux 10 ms tests with real path detail measured
13–15 ms exits; private-tmux 500 ms still measured about 500 ms, distinguishing
the two causes. The owner server was not changed. Final latency regression
`/tmp/opencode/workbench-inspector-latency-pa1haj23` passed its 80 ms ceiling;
terminal tests/build, format/lint, installed lifecycle and Ctrl-C matrix passed.
See [evidence and commands](fs1_investigation.md#escape-responsiveness-in-tmux--2026-10-16-followup).

**Owner confirmation, 2026-10-16:** after the fix and setup guidance, the owner
reported Escape now works fine. This closes the manual latency report, without
claiming exhaustive terminal or provider coverage. FS1 has no remaining functional
blockers for the adopted evidence. Breadcrumbs, mode-specific help, an explicit
Close inspector command and more concise detail presentation are
[usability followups](backlog/README.md#inspector-usability-polish); broader lifecycle
race matrices and larger-design performance remain coverage work. FS2's independent
structured-simulation delivery and acceptance are recorded above.

### Earlier proposed execution followup — generic detail remains deferred

The initial takeover review proposed an identity-safe selected-attempt detail view. This
is a follow-on to F02/F09's existing execution UI within M4, not delivery of FS2
structured simulation or a new ASIC orchestration engine. **Generic selected-job
detail is not implemented yet.** FS2 now provides dedicated simulation attempt/case
detail and logs; it does not claim this broader generic-job followup is complete.

- [ ] Enter/Esc detail navigation over existing `Job.t` identity, kind, state, phase,
  created/started/finished timestamps and exact outcome, with explicit missing fields.
- [ ] Tile-local selection and scrolling retain exact job identity through updates;
  disappearance or daemon-instance replacement must not silently retarget details.
- [ ] Wire bounded stream-labelled logs through existing job log RPC, deduplicating
  interest across visible consumers and rejecting stale-instance responses.
- [ ] Exercise actual HTTP/PTY selection of an earlier attempt, independent tiles,
  live output and return navigation. Keep the five-mode interrupt regression intact.

Preserve the execution tile's existing RTL/driver-job inspection and hierarchy
entry points; do not replace its job list with the generic Build/Test-only
`Execution.attempts` projection. Project-test filtering remains project-scoped.
No historical argv, test cases, progress percentage or ASIC-run association should
be inferred from job kind, log text or current project configuration. Existing
generic supervisor and ASIC process-service boundaries remain separate.

**Original timing gate, now superseded for aggregate terminal evidence:** the
stage-summary adapter still emits `timing = []` because
CLI4 lacks normalized timing attribution/units. The retained accepted 673/685
checkpoint metrics contain synthesis/lint measurements, not setup/hold slack;
`synth_delay` is a profile name, not measured timing improvement. The adopted
provider's `execution/results/stage_report_service.ml` forwards unknown metric
keys with no unit and labels metrics as accumulated boundary snapshots. Its
separate coarse collector and newer source declarations do not establish timing
through the adopted named-flow report path. First require timing-bearing evidence
and a supported units/corner/measurement-origin contract before a timing slice.
The subsequent FS1 implementation uses the existing public finalization-results
contract for aggregate timing, rather than guessing units in stage metrics.
Synthesis area/check counters are now projected into the current summary.

## M5 — Multi-window polish and adoption (FS3)

### User-authored window/workspace composition — 2026-10-21

Post-merge follow-up: [composition audit](workspace_post_merge_audit.md) reconciles
the merged hierarchy/domain/navigation work with canonical stock and custom layouts.
Implementation and integrated acceptance are complete; the audit records exact
configuration, hierarchy, Testing, frontend-refinement and reconnect evidence.

[Implementation plan](workspace_configuration_plan.md). Owner-authorized scope uses
one shared specification for stock and user layouts, including responsive trees.

- [x] A1: portable bounded schema, keyed tile references and validation.
- [x] A2: atomic initialization/additive apply and persisted resolved definitions.
- [x] A3: canonical stock/example files and shared catalog/layout integration.
- [x] B1/B2: explicit CLI and terminal configuration entrypoints.
- [x] B3: integrated protocol/backend/native CLI and terminal verification.
- [x] C: [user workflow, compatibility/extension guidance and evidence](workspace_configuration.md).

Native receipts: `workspace-config-zbzojw2o`, `fs3-adoption-574hfszu`, and
`default-layout-restore-gekveke6` under `/tmp/opencode/` (each `result.json`).
Targeted tests, native builds and lint pass; full format check has pre-existing
untouched ASIC/waveform differences recorded in the guide.

At most three general implementation agents; builds run centrally with `-j20`.
No Git staging, commits or pushes are authorized.

### Explicit default-layout recovery — 2026-10-18

[Shared plan](default_layout_restore_plan.md), [controls/evidence](default_layout_restore.md).

- [x] One atomic captured-revision restore: show default occurrences, hide extras/
  duplicates, restore requested sizes, clear zoom; preserve identities/pins/context.
- [x] Named/current preset commands, stable-ID selection and custom/unknown disabled
  reasons; no display-name inference or implicit restoration.
- [x] Success-only Fit persistence with late-response/local-intent fences; existing
  additive Apply/Reset and appearance preferences retained.
- [x] Normal full checks at20; native58, FS3 adoption141, cooperative Testing15 and
  interrupt5/5 proofs passed. Owner's live layout was not mutated by these tests.

Final native receipt: `/tmp/opencode/default-layout-restore-t4rz4qvv/result.json`.

**First adoption slice delivered; full multi-monitor acceptance pending.**

**Post-merge integration completed 2026-10-17:**
[shared plan and evidence](fs3_integration_plan.md).

- [x] Real header-toggle/reset actions persist sparse intent; polling no longer
  reapplies stale saved preferences. Same-session reconnect preserves browsing and
  invalidates outstanding responses; replacement identities clear local state.
- [x] Templates retain optional preset identity and share current preset starters
  with the terminal definitions. Custom layouts honor generic Fit.
- [x] Explicit atomic/idempotent bootstrap handles import-before-TUI and concurrent
  startup, while legacy sparse saved arrangements are protected.
- [x] Initializer roots match the opener; explicit manifest-only reload succeeds
  without a fake discovery job. Installed initializer/client handoff verified.

- [ ] Two attached monitor surfaces, convergence/local navigation and cross-window
  workspace/tile movement acceptance.
- [x] Existing-project initializer with validated current-format manifest and atomic
  no-clobber publication; no build/VCS/provider execution.
- [x] Versioned portable generic/ASIC templates, atomic Main-linked instantiation,
  export/clone and CLI listing. New view identities exclude source pins/run state.
- [x] Persistent local appearance/layout/chrome/header choices, malformed-file recovery
  and project/environment/session identity checks.
- [x] Actual private-daemon HTTP template lifecycle and restart restoration, plus
  real PTY appearance change/restart acceptance (`scripts/test-fs3-adoption.py`).
- [ ] Explicit configuration-directory migration/precedence, upward discovery and
  new-project creation; TUI template discovery/selection comfort.
- [ ] High-volume log/event responsiveness and help/discoverability measurements.
- [ ] Reviewed appearance presets, SSH/tmux controls and glyph fallback validation.
- [ ] Final adopted-scope checks and deliberate provider-version adoption.

See [FS3 adoption](fs3_adoption.md) for commands, boundaries and verification.
Current normal build, full tests and repository-wide format/lint pass serially at
`-j 20`, within one shared aggregate pool of 20. FS3 native acceptance passes 140
checks at `/tmp/opencode/fs3-adoption-n5sxf42_/result.json`; installed handoff evidence
is `/tmp/opencode/fs3-installed-setup-evidence-20261017/`. Checklist 61, lifecycle 27,
FS2 native Cyclesim and all five interrupt regressions pass. Exact evidence is in
the integration plan. This does not claim full multi-monitor acceptance.

## V1 — Independent appearance gallery (FS5)

### Native activity and semantic icons — 2026-10-17

[Shared plan and evidence](terminal_indicators_plan.md),
[controls](appearance_presets.md#native-activity-and-semantic-icons--2026-10-17).

- [x] Actual installed Bonsai Term Dot/Line components, shared per client, with
  independent input/display invalidation and provider polling.
- [x] Typed lifecycle/request indicators in stages, runs, jobs, planned-run and
  structured simulation; compact pin/seed/artifact/log context glyphs.
- [x] Unicode/ASCII/Off modes, persisted choice, deterministic pure captures,
  one-cell glyph policy and unchanged dense geometry/unadorned titles.
- [x] Canonical simulation row metadata preserves full text and independent
  process/case outcomes; no report/log keyword inference.
- [x] Full normal checks at20; native indicator351, FS2 45, Overview130,
  checklist61 and interrupt5/5 acceptance. Real tools were not launched.

Native evidence: `/tmp/opencode/terminal-indicators-e67675e54fe0/result.json`.
Initial Off-mode redraw failure was fixed and covered by the final native run.

### Synthetic Testing and wider Session panels — 2026-10-17

[Shared plan](synthetic_testing_plan.md), [controls, evidence and both demo launch pairs](synthetic_testing.md).

- [x] Synthetic seeding creates Overview/Timing/Testing from stable exported presets;
  repeats/renames preserve one default per preset and existing custom state.
- [x] Self-contained copied FS2 provider/config; explicit seed submits retained
  pass/failure cases, parameters/seeds, live progress, logs, reports and synthetic
  trace bytes through normal supervision. No hardware/ASIC association is fabricated.
- [x] Idempotent submissions and additive old-demo upgrade with ownership checks;
  no test launches on ordinary viewing/navigation/client restart.
- [x] Timing Session and Testing sidebar are one-third width at normal viewports;
  Testing allocates more height to FS2, Timing investigation topology is retained.
- [x] Normal format/lint/full tests/build at2, actual synthetic HTTP/PTY and real
  ASIC example adoption; persistent real-demo binaries refreshed without EDA.

Final synthetic evidence: `/tmp/opencode/synthetic-flow-kkw_d303/`. Matching actual
example evidence: `.dev/workbench-real-demo/receipts/acceptance-f3248de97eac43cfb4cc65862aebb98e/`.
Both launch pairs are ready for scoped owner hand-validation; data provenance
remains distinct. Existing user sessions/state and Git index/history were preserved.

### Black/status polish and actual ASIC example adoption — 2026-10-16

Delivered from owner feedback. [Shared plan](real_example_polish_plan.md),
[launch commands and evidence](real_asic_example_demo.md).

- [x] Checklist/planned-run split remaining left-column space with equal weights;
  Session/Runs above and six full-width domain summaries at right.
- [x] Neutral field labels and value-only semantic colors, including selector
  lifecycle tokens; width-aware meaningful Session run prefixes and hash suffixes.
- [x] Black Carbon default/legacy fallback and bright white headers, with preserved
  status/metric/focus distinctions and all alternative schemes.
- [x] Persistent inspection-capable provider installed at2 jobs; actual example
  configuration repaired from expired temporary paths, prior provider/current preserved.
- [x] Read-only adoption of exact original named signoff/finalization references
  through normal APIs; actual native Overview/Timing/all-domain detail verified.
- [x] Persistent demo binary refresh with receipts/rollback tests; final copies
  match normal build. Full format/lint/tests/build passed serially at2.
- [ ] Provider optional live stage-action envelope remains absent. The subsequent
  consistency fix now reads checklist status from public structured occurrences;
  no new real stage actions or execution are claimed by adoption.

Final actual evidence: example `.dev/workbench-real-demo/receipts/acceptance-b72a4a8afe9441e698eda6a6da24e7a5/`,
673 cells, setup11.6755ns, hold0.125029ns, retained acceptancepass,1020 timing paths
plus one input-reference row.2235 canonical input/provider files unchanged; no EDA.
Separate synthetic UI/regression evidence includes polish196, refinement98/two-run12,
composition46, FS2 45 and five interrupt cases; exact roots and scope are in the guide.
No Git staging/commits/pushes. Existing sibling user edits and live sessions preserved.

### Dense Overview sidebar, color schemes and planned-run — 2026-10-16

Delivered from the owner's Lazygit-inspired packing/layout and theme request.
[Shared plan](overview_sidebar_plan.md), [controls/source settings/evidence](overview_sidebar.md).

- [x] Overview1:2 sidebar/main split with Session/Runs/vertical stages on the left;
  synthesis/timing/placement/routing/checks/finalization/planned-run stacked at right.
- [x] Zero blank-cell gutters with adjacent disjoint frames, lowercase unadorned
  titles, configurable source weights/minimum heights and bounded live selector growth.
- [x] Carbon/Slate/Crimson/Neon scheme axis with live palette commands, independent
  skin/intensity/icons/density; Slate default, Ches-inspired Crimson, typed state colors.
- [x] Project-scoped planned-run preview with pending/failed/stale/ready states,
  inspectable exact identity, receipt/poll/intent fences and guarded explicit launch.
- [x] Preserve Timing topology and shared module/query identity; no provider work
  caused by visual changes or plan inspection and no fake queued/allocated identity.
- [x] Full normal format/lint/tests/build at2; actual sidebar106, composition45,
  refinement96/two-run12, FS2 45, synthetic launch/cancel and five interrupt cases.
- [ ] Owner visual review of the four schemes and denser default arrangement.

Final normal-binary evidence: `/tmp/opencode/overview-sidebar-835bf5f34f02/`.
Regression roots: `frontend-composition-b5bc7783c26e`, `frontend-refinement-7dad2f910d25`
and its `-two-runs` companion, `synthetic-flow-d0emyda4`, `fs2-native-y2sbyizx`,
`workbench-terminal-interrupt-wbg9s_ny` (all under `/tmp/opencode`). Existing user
staged work/index and live session state were preserved; no staging/commits/physical
flows. Native pending/failure scenarios clear the old daemon preview; retained stale
preview and same-selection receipt races have separately identified pure coverage.

### Owner-review panel and investigation refinement — 2026-10-16

Delivered after manual feedback on the composition slice. [Shared implementation
plan](frontend_refinement_plan.md), [controls and evidence](frontend_refinement.md).

- [x] Shared styled panel/palette borders, title-in-border, colored query caret,
  distinct match/selection emphasis and footer separator; short panels retain frames.
- [x] One-row navigation, reduced vertical padding, width-aware long run identifiers,
  actual visible/total capacity and bounded responsive selector-height growth.
- [x] Horizontal Overview stages and compact synthesis/timing/placement/routing/
  checks/finalization panels over existing typed evidence, with detailed modes retained.
- [x] Timing Paths/Selected path/Provenance workspace; actual provider detail starts
  after four compact summary lines, full raw metadata remains separately inspectable.
- [x] Exact captured-run opening, safe existing-workspace reuse or independent
  arrangement, protected Main/pins, pane-local scrolling and stale epoch/digest fences.
- [x] Actual HTTP/PTY refinement57 + two-run12 + composition44 + FS2 45 checks,
  synthetic launch/cancel and five interrupt cases; full format/lint/tests/build at2.
- [ ] Owner visual review of the refined panel composition. Existing custom extras
  remain preserved; no automatic layout deletion or persisted presentation is claimed.

Final evidence under `/tmp/opencode`: `frontend-refinement-e41e2e8d24b9`, its
`-two-runs` companion, `frontend-composition-25481b162854`,
`synthetic-flow-y0hx51su`, `fs2-native-n3pc_ana`, and
`workbench-terminal-interrupt-49omjzgu`. Normal `_build` binaries were rebuilt.
No live demo-state changes, real EDA, Git staging or commits were performed.

### Frontend composition follow-on — 2026-10-16

Delivered from the owner's palette/layout/configurability request; this does not
reopen the accepted FS2 milestone. [Shared plan](frontend_composition_plan.md),
[source map, controls and acceptance](frontend_composition.md).

- [x] Bounded centered palette over the actual workspace/inspector, ranked fuzzy
  title/alias/ID matching, exact character emphasis and Tab/Shift-Tab navigation.
- [x] Quiet normal Follow/project chrome, visible pins by default even without a
  header, per-tile title/badge/run/freshness/hints/frame/padding/row controls and reset.
- [x] Typed freshness/outcome/check colors, preserving Validated versus Passed/Failed
  semantics and unmodified raw report/log evidence.
- [x] Central composable Overview/Timing/Testing OCaml definitions and stable preset
  identity; legacy loading, rename stability and explicit additive Apply/Reset.
- [x] Wide shallow upper-main run selector, stacked main panels, quiet navigation,
  retained duplicates/extras/pins and narrow/zoom fallbacks. Testing includes FS2.
- [x] Synthetic seeding consumes exported normal presets; provider stage labels are
  production-like while synthetic identity/provenance remains explicit.
- [x] Preserve Compact/Comfortable density as the base padding choice, with explicit
  presentation overrides taking priority and reset restoring inheritance.
- [x] Final full format/lint/runtest/build at `-j 2`; actual frontend HTTP/PTY
  **41 checks**, synthetic flow, FS2 Cyclesim and five-mode interrupt regression.
- [ ] Owner visual review of this new arrangement. Persisted client presentation,
  tile-local tab groups, arbitrary floating surfaces and a separately tiled global
  footer remain later extensions, not claims of this bounded slice.

Final evidence under `/tmp/opencode`: `frontend-composition-359220233ca9`,
`synthetic-flow-huttcbvv`, `fs2-native-me_1anb2`, and
`workbench-terminal-interrupt-v31tg44p`. The frontend evidence includes actual
80×24, 120×40 and 180×55 cell-grid captures. Normal `_build` binaries were rebuilt;
existing user daemon/demo state was not changed. No physical tools or mutative Git
operations were needed. Earlier transient compile/format findings and a timed-out
coordinator harness run are distinguished from final passing evidence in the guide.

**Synthetic flow/demo slice (2026-10-16):** delivered an isolated no-EDA provider
and setup/seed/client launcher, coherent reference/failed runs, rich FS1 inspection
datasets, optional typed stage observations and checklist planning through existing
Plan/Run operations. Three agents implemented backend, provider and terminal slices;
parent checks stayed serialized at `-j20`. Real HTTP and terminal/PTY acceptance
passed at `/tmp/opencode/synthetic-flow-8rmfu7xu/`. See the
[user guide and evidence](synthetic_flow.md) and [bounded implementation plan](synthetic_flow_plan.md).
This supports the appearance track and future FS2 fixture integration; it does not
implement another structured-suite contract or imply real-provider stage support.

**Aesthetics worktree slice (2026-10-16):** added pure utility-tile presentation
and nonuniform Overview geometry, a three-row workspace navigation tile, session
status and stage checklist, explicit Testing workspace creation, Shift-Tab reverse
focus, brighter Instrument defaults and comfortable padding. Opaque run IDs are
shortened in compact labels with full session inspection available. Stage entries
remain `not reported` until explicit stage observations reach the ASIC snapshot;
available aggregate outcomes/checks are displayed separately. See
[controls and limits](appearance_presets.md#aesthetics-worktree-first-pass-2026-10-16).

Verification: `@fmt`, `@lint`, full `dune runtest -j20` and default build passed;
terminal tests were repeated after navigation/inspection fixes. The raw Ctrl-C PTY
matrix passed all five modes at
`/tmp/opencode/workbench-terminal-interrupt-vqupx_j0/`. Production-renderer A–E
captures now include an aesthetic Overview fixture at 80×24 and 120×40 under
`/tmp/opencode/aesthetics-review/` (synthetic evidence). Owner visual review and
spinner/Nerd Font experiments remain open.

**First skin slice delivered; richer gallery/review pending.** See
[appearance presets](appearance_presets.md) for controls, captures and tests.
This is a reusable renderer over actual FS0 tiles, not a selected final aesthetic.

- [ ] Reuse installed rendering/Ches seams and the existing semantic registry.
- [x] Implement A–E thin skins using shared host rendering, semantic colors, optional
  frames/headers, focus treatments and small-tile fallback. Independent color,
  off/ASCII/Unicode and density controls are available in the actual palette.
- [x] Capture identical synthesis/timing-unavailable/pinned/palette fixtures at wide
  and modest cell grids. Test 90 combinations and actual PTY switching without
  registry changes or provider calls; installed workflows/legacy captures pass.
- [ ] Compare A Instrument, B Structured, C Minimal, D Studio and E Structured Studio
  over identical labeled synthetic Overview/Timing data.
- [ ] Independent color/icon/density axes, reusable tabs and configurable chrome.
  Color/density/basic icon axes are delivered; reusable tab groups and Nerd Font
  mode remain. Studio title badges do not pretend to be navigation tabs.
- [ ] Actual wide/narrow terminal captures, focus/input/glyph/geometry checks and
  owner review before selecting defaults. Mock peeks remain labeled mock.

## Phase summary

| Phase | Current status |
| --- | --- |
| M0 | Accepted FS0 defaults and candidate/fixture baseline delivered; broader matrix remains |
| M1 | Headless Demo A delivered; physical/container cancellation evidence extended in M4 |
| M2 | Tile-host Demo B delivered; bounded UI/coverage/performance gaps above |
| M3 | Autosaved-session/L2 Demo C delivered; FS3 adds CLI templates and appearance persistence |
| M4 | FS1 adopted-evidence investigation/operation scope delivered; substantial FS2 project-scoped simulation delivered with real Cyclesim/native HTTP/PTY evidence; later F06 extensions remain |
| M5 | Initializer, CLI templates and presentation persistence delivered; multi-monitor acceptance later |
| V1 | A–E skins/axes/captures delivered; rich gallery and default review pending |

Keep acceptance records authoritative for exact commands/results. New provider
capabilities or normative feature requirements alone do not check a delivery box.
