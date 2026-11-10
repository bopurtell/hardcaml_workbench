# Workbench documentation

Workbench is a project control and inspection application: operate independent
Hardcaml projects, observe execution, and inspect identified hardware evidence.
Project/provider commands remain useful without the application.

## Start here

| Document | What it answers |
| --- | --- |
| [Session checkpoint](session_checkpoint.md) | New-session pickup: ASIC PT.0–PT.8, delivered Workbench integration, paused synthesis acceptance and current test-refactor boundaries |
| [Migration/refactor guides](migration_guides/README.md) | Actionable continuation plans, including the next Workbench test-organization steps |
| [Feature list](feature_list.md) | What users want to do, what exists, and what comes first |
| [Feature ticket catalog](features/README.md) |65 categorized WB tickets: one file each, priority, size/points, dependencies and decisions |
| [Intake crosswalk](features/intake.md) / [dependency map](features/dependencies.md) |Where every submitted request went and what each prerequisite must supply |
| [Feature sets](feature_sets.md) | FS0 initial demos and later themed groups of work |
| [Demo construction plan](construction_phase_plan.md) | What to implement next and how to demonstrate it |
| [Decision log](decisions.md) | Accepted D1/D2/D3 FS0 defaults and later command/snapshot policy |
| [FS0 acceptance](fs0_acceptance.md) | Actual HTTP/PTY fixtures, real 673/685 synthesis and live cached UI reopening |
| [Installed checks](fs0_install_checks.md) | Passed native installed workflow, external fixture and legacy captures |
| [FS3 adoption](fs3_adoption.md) | Existing-project initializer, portable workspace templates and persistent presentation preferences |
| [User-composable workspace plan](workspace_configuration_plan.md) | Agent-sized implementation and verification for shared stock/user window and workspace definitions |
| [Compose windows and workspaces](workspace_configuration.md) | Export stock examples, author keyed tile layouts, initialize/apply configuration and recover built-ins |
| [Post-merge composition audit](workspace_post_merge_audit.md) | Reconciliation of hierarchy, Testing/Timing/Overview and reconnect features with the shared specification |
| [Restore default layout](default_layout_restore.md) |One-step recovery: show defaults, hide extras, restore sizes, clear zoom and select Fit while preserving evidence/pins |
| [Layout focus-order plan](layout_focus_order_plan.md) | Implemented layout-defined Tab/Shift-Tab traversal, agent work packages and validation results |
| [Provider integration](fs0_provider_integration.md) | Implemented public API, configuration, cache and supervision limits |
| [Testing Workbench](testing.md) | Tool-test ownership, inline/subsystem/app integration layout, named suite selectors and current execution constraints |
| [Stable development session](development_session.md) | One editable example/project and retained session with FIFO + PT.8 suites, normal ASIC preparation and time-aware waveforms |
| [PT.8 Workloads](pt8_workloads.md) | Isolated session launch, verified retained results/A-B comparison and fresh example workload through Testing |
| [Terminal host](fs0_terminal.md) / [Execution module](fs0_execution_module.md) | Current UI controls and daemon-routed generic execution boundary |
| [Architecture](hardcaml_workbench_architecture.md) | Runtime, ownership, data and integration boundaries |
| [Rendering](rendering.md) | Presentation, input, layout and headless interaction requirements |
| [Appearance handoffs](design/README.md) | Imported older design doc, newer gallery and implementation qualifications |
| [Appearance presets](appearance_presets.md) | Try the implemented A–E skins and independent presentation controls |
| [Frontend composition](frontend_composition.md) | Where workspace layouts live; bounded fuzzy palette, per-tile chrome, status colors, preset migration and actual PTY evidence |
| [Frontend refinement](frontend_refinement.md) | Current panel/palette styling, compact six-domain Overview, run-selector sizing and dedicated Timing investigation workspace |
| [Overview sidebar and schemes](overview_sidebar.md) | Latest dense Overview composition, color-scheme controls, planned-run semantics and native verification |
| [Real ASIC example demo](real_asic_example_demo.md) | Current black-theme/status polish, split checklist/planned-run sidebar and exact commands for genuine retained ASIC evidence |
| [Synthetic Testing and dual demo](synthetic_testing.md) | Three default workspaces, seeded FS2 cases/results/artifacts, roomier Session layouts and synthetic/actual-example launch pairs |
| [Launch and stage consistency](launch_stage_consistency.md) | Exact plan-to-launch lifecycle, real structured stage observations and read-only refresh of existing runs |
| [Checklist preparation and launch](checklist_launch_workflow.md) | Restored real j/k/r preparation, on-demand capability discovery, visible Launch availability and exact input capture |
| [Synthetic flow demo](synthetic_flow.md) | Launch populated Overview/Timing workspaces and operate a simulated flow through the real daemon, without EDA |
| [Synthesis inspection](synthesis_inspection.md) | FS1/F06 cell table, filter/sort, row detail and evidence controls |
| [Hierarchy tile](hierarchy_tile.md) / [implementation plan](hierarchy_tile_plan.md) | WB-007 controls, shared evidence, independent browsing, agent work packages and acceptance |
| [Timing checklist and Overview](timing_checklist_overview.md) / [implementation plan](timing_checklist_overview_plan.md) | WB-069: independent STA status/duration, corner metrics, exact-source drilldown and failed-signoff evidence |
| [Executable Timing stage](executable_timing_stage.md) / [plan](executable_timing_stage_plan.md) | Real Routing → Timing → Signoff checkpoints, `r` preparation, historical compatibility and refreshed example deployment |
| [Timing workspace diagnosis and loading](timing_workspace_loading.md) | Real a023 empty-path fix, saved catalog removal, cache investigation and background warm-up rationale |
| [Timing usability and preloading](timing_workspace_usability.md) / [plan](timing_usability_preload_plan.md) | Three-decimal/compact presentation, built-in navigation, reordered tabs and default background index loading with explicit-only mode |
| [Identifier compression](identifier_compression.md) / [completion plan](timing_triage_identifier_completion_plan.md) | WB-073 global/workspace/tile controls, collision-safe identities, persistence and WB-009/WB-069 owner closure |
| [Overview title/detail regression](overview_compression_regression_plan.md) | Saved header recovery, stage-aware Placement/Routing detail, Overview Timing precision and actual-state verification |
| [FS1 acceptance](fs1_acceptance.md) | Aggregate timing/resources/checks, declared-clock context, finalization import, real physical/acceptance/cancellation evidence and remaining scope |
| [Finalization and artifacts](fs1_lifecycle_and_artifacts.md) | Workbench-owned collect/accept, live phases, cancel/reconnect, bounded report paging and explicit external text export |
| [FS1 investigation](fs1_investigation.md) | Completed adopted-evidence scope: paths, measured clocks, physical/routing tables, binary handoff, verified provider generation and activation |
| [FS2 simulation](fs2_acceptance.md) | Structured suites/cases/seeds, live failures, reruns, history and trace controls with real Cyclesim/native HTTP/PTY evidence |
| [Testing catalog and real FIFO](testing_workspace.md) / [cluster plan](testing_cluster_plan.md) |Current cooperative Testing panes, explicit catalog/subset launch, genuine FIFO pass/failure/traces and final native evidence |
| [FS2 provider contract](fs2_simulation_contract.md) / [implementation plan](fs2_implementation_plan.md) | Versioned configuration/events/RPC, bounds and feature-set ownership |
| [Formatting](formatting_guide.md) | Source conventions |
| [Backlog](backlog/README.md) | Deferred work and reactivation triggers |
| [Archive](archive/README.md) | Superseded plans and historical acceptance evidence |

The feature list is the concise product inventory; feature sets group delivery
themes (FS0 and adopted-evidence FS1 delivered; substantial FS2 accepted and closed;
FS5's first appearance slice delivered).
F01–F12 feature documents record architectural behavior and boundaries; the WB
catalog owns proposed feature scope, estimates and dependencies. The construction
plan alone owns activated implementation order and delivery checklist. Ticket
acceptance criteria describe a future completion gate, not an active implementation
checklist. Focused acceptance records linked there own exact runtime
evidence. A feature request or a provider capability is not proof
of an implemented Workbench feature.

## Current orientation — 2026-10-17

- **FS0 Demos A–C delivered with bounded limitations:** typed execution boundary,
  tile host/palette, project-scoped tests/logs, named workspaces, linked/independent
  contexts, run pins, public ASIC synthesis and autosaved-session/L2 reopening.
  Existing Dune, RTL/artifact/provenance and hierarchy workflows remain exercised.
- Real serial balanced/synth_delay synthesis completed with **673/685 cells**,
  acceptance **`not_evaluated`**, early allocation and client-detach survival.
  Actual cached UI reopening shows **673→685** and **pinned 673 beside following
  685**. [The plan](construction_phase_plan.md#evidence-and-candidate-baseline)
  consolidates evidence roots and exact candidate executable/hash provenance.
- **D1 accepted:** windows are attached surfaces; Overview/Timing/Resources are
  workspaces. Their selectors control a shared Main run context by default, with
  explicit independence/relink and per-tile references. See [F10](features/run_contexts.md).
- [F09 simulation/tests](features/simulation_and_tests.md) retain generic Dune tests
  and add structured FS2 suites/cases/seeds, live outcomes, targeted reruns, bounded
  history and exact trace export over the existing supervisor. Real Cyclesim and
  native HTTP/PTY acceptance passed. The owner accepted the basic demo and authorized
  milestone closure; [controls and evidence](fs2_acceptance.md),
  [followups](backlog/fs2_followups.md), and
  [integration handoff](fs2_acceptance.md#integration-handoff).
- **D2/D3 FS0 defaults accepted:** captured/revalidated targets, no missing-flow
  fallback, ordinary launch does not select, guarded launch-and-view, follow/pin-run
  first. Immutable snapshots/archival retention and richer command policy are later.
- Tiles render asynchronously delivered module state. The daemon shares/caches
  provider queries; rendering does not spawn one provider process per tile.
- [F11 run-summary caching](features/run_summary_cache.md) is delivered in L1/L2;
  canonical evidence remains provider-owned. Fixture warm/restart report calls stay
  2→2; real restart preserves exact evidence identity with `Cached_unverified`.
- [F12 appearance](features/appearance.md) keeps themes/components/layouts separate,
  utility chrome mountable and headers configurable. FS5/V1's first A–E skins and
  independent color/icon/density controls are delivered; richer gallery fixtures,
  reusable tabs and final aesthetic review remain pending. No embedded editor is selected.
- Limits: shelf layout rather than freeform geometry; domain refresh is polled and
  the endpoint/assignment form remains basic. Local input redraw is immediate.
  Embedded graphical editing and unsupported source mappings remain later work.
  Broader frontend race/reconnect/cancellation coverage and scaling measurements
  remain explicit followups.
- FS3's [first adoption slice](fs3_adoption.md) delivers existing-project initialization,
  CLI template export/import/clone and persistent client appearance/header choices.
- FS1 now includes [synthesis metrics and aggregate physical evidence](fs1_acceptance.md),
  signed timing, check verdicts, verified declared clocks and exact finalization
  import. Real six-stage execution, external acceptance and owned-container
  cancellation have separate retained evidence. The final [FS1 investigation](fs1_investigation.md)
  delivers path/corner/group navigation, measured clock evidence and stage-specific
  physical/routing/congestion tables. FS2 project-scoped structured simulation is
  now delivered independently of ASIC configuration.
- Workbench-owned finalization/acceptance and report/artifact text viewing are
  delivered, with real palette/transport detach, cancellation, idempotency and
  restart checks. External text opening uses a private terminal-host export,
  not the daemon's original path. Exact binary handoff is also delivered, with
  a real exported GDS loaded headlessly by KLayout; interactive GUI rendering and
  embedded editing are not claimed by that test.
- Parent format/lint, full runtest/build, installed workflow, actual metrics/physical
  HTTP/PTY/L2 checks, original synthesis inspection and the five-mode interrupt
  matrix passed. Evidence and limitations are recorded in the active plan.
- **Owner usability confirmation:** Escape now works well in the timing-inspection
  workflow. This closes the reported latency followup. Timing's concise summary/
  detail/provenance split is also delivered; clearer inspector breadcrumbs,
  contextual help and a Close inspector command remain
  [usability polish](backlog/README.md#inspector-usability-polish). FS2's independent
   delivery and acceptance are recorded separately above.

- FS3 post-merge integration and native icons/activity are delivered; see
  [FS3 integration](fs3_integration_plan.md) and
  [native indicator evidence](terminal_indicators_plan.md). Preset identity,
  atomic defaults and selected persistent presentation choices are foundations,
  not outstanding catalog tasks.
- [WB-009](features/evidence/WB-009-timing-coherency.md) is now owner-verified/closed:
  the actual a023 wrong-stage defect was fixed, and after read-only historical triage
  the owner confirmed recent fixes resolve the older report. Its original exact
  execution identity remains unasserted; no new physical flow was used for diagnosis.

Build, launch and check commands are in the repository [README](../README.md).
