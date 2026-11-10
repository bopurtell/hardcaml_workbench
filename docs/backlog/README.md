# Backlog

## Feature ticket catalog

The owner's current feature intake is organized into [individual WB tickets](../features/README.md),
with an [intake crosswalk](../features/intake.md) and [dependency map](../features/dependencies.md).
Use those tickets for estimates, scope and open decisions. This page retains
unactivated longer-term ideas and links from earlier delivery records; it does not
create a competing queue. Existing FS2-F IDs map to tickets in
[the compatibility crosswalk](fs2_followups.md#canonical-ticket-crosswalk--2026-10-17).

This directory holds discussed work deliberately deferred beyond the active
[plan](../construction_phase_plan.md). It is not an automatic next-phase queue.
Reactivate an item by moving its concrete requirements into the architecture/plan.
Create a dedicated note here when an item warrants more detail, instead of adding
another top-level planning document. These entries are planning status, not code.

The [feature inventory](../feature_list.md) now records the owner's broader product
requests, including project setup, Ches integration and automation. A focused spec
preserves desired behavior without making every feature a first-demo requirement.
Shared run contexts and workspace terminology are accepted in D1. D2/D3's FS0
defaults are also accepted; richer command grammar/shared preferences and exact
immutable snapshots remain deferred in the [decision log](../decisions.md).
The agreed [FS2 simulation/test milestone](../fs2_acceptance.md) is delivered,
accepted and closed. [Named FS2 followups](fs2_followups.md) preserve FIFO adoption,
trace streaming, responsiveness/reconnect/log retention and additional simulation
capabilities with explicit activation and acceptance criteria. Embedded waveform
exploration remains deferred separately. FS1's adopted-evidence functionality is complete.

## Tool-test flow coverage and runner consolidation

[Deferred coverage/refactor backlog](tool-test-flow-coverage.md) preserves the
remaining segmented and complete-flow coverage matrix, shared-support extraction,
integration registration and bounded top-level runner. Deferred by owner on
2026-11-10 to prioritize the main PT.0–PT.8 feature track and required acceptance.
The delivered refactor remains in place; this is not an automatic next work item.

## Inspector usability polish

The owner confirmed that Escape now responds well after the local redraw fix and
tmux guidance. Keep that manual acceptance separate from the automated latency
matrix and from final aesthetic approval; see the
[measured followup](../fs1_investigation.md#escape-responsiveness-in-tmux--2026-10-16-followup).

The following are presentation followups, not FS1 feature blockers:

Canonical planning: [WB-054 contextual controls](../features/presentation/WB-054-contextual-controls.md)
and [WB-055 lightweight peeks](../features/presentation/WB-055-source-path-peeks.md).
Timing's concise summary/detail/provenance composition has already been delivered;
the earlier raw-JSON prominence note below is historical, not an untouched feature.

- Show workspace → explorer → detail breadcrumbs and the active input mode.
- Provide contextual Escape/help hints and an explicit **Close inspector** palette
  command. That command is proposed, not currently implemented.
- Put concise semantic path/measurement information ahead of raw JSON, full IDs
  and absolute paths while retaining complete inspectable provenance.

Broader lifecycle race/cancellation permutations and larger-design performance
measurements are coverage/scaling followups in the construction plan. Reactivate
these bounded tasks when working on usability/adoption or when a concrete regression
is observed; they do not reopen the completed FS1 or FS2 milestones.

## Deferred extensions

### Preparation history and external emission adoption

Deferred from [WB-004](../features/project/WB-004-build-bundle-status.md) by owner
direction on 2026-10-25; not a prerequisite for its initial EDA-less preparation UI.

- Retain exact build/emission attempt receipts, scope, outcome and published bundle
  identity across daemon restart, distinguishing interrupted or unknown work.
- Discover/adopt preparation launched outside Workbench from authoritative producer
  receipts, without inferring success from directory existence or replaying work.
- Preserve associations to historical hardening runs only when exact producer/bundle
  evidence establishes them; retained bundles and completed producer attempts are
  distinct facts.
- Coordinate bounded retention and unavailable log/artifact states with
  [WB-041 durable logs](../features/infrastructure/WB-041-durable-logs.md) and
  [WB-042 resource budgets](../features/infrastructure/WB-042-resource-budgets.md).

Related but separate: [WB-037 archived replay](../features/verification/WB-037-archived-replay.md)
re-executes retained historical inputs; [WB-062 submission recovery](../features/verification/WB-062-submission-recovery.md)
is simulation-specific; [WB-065 lifecycle coverage](../features/infrastructure/WB-065-asic-lifecycle-coverage.md)
tests ASIC execution races. None currently owns general preparation receipt adoption.
Reactivate when restart/external-producer history is needed, with explicit producer
receipt/discovery and retention contracts. This entry is not included in WB-004's
initial estimate.

### Other deferred extensions

| Deferred item | Preserved intent | Reactivation trigger |
| --- | --- | --- |
| Resource-mapping/preparation composition (WB-004 follow-up) | Join bundle preparation with provider-owned resource preparation while retaining distinct operation identities, outcomes and exact bundle associations | Resource-mapping integration is ready for a combined workflow; closed WB-004 is not blocked |
| Dedicated comparator tile | Explicit A/B selection, contextual deltas, corner/stage/unit/constraint alignment | Pinned reference tiles prove insufficient for a real comparison task |
| Bonsai Web and embedded graphical views | Browser tiles, layout/spatial heatmaps and graphical timing-path cross-probing beyond the delivered terminal explorer | A concrete visual inspection need that terminal/external viewers cannot serve |
| Live FPGA integration | Vivado and project-side Hardcaml Xilinx/report providers, synthesis/implementation | Owner begins a real FPGA-only workflow; fixtures already protect shared boundaries |
| Persistent vendor/Tcl sessions | Tool process framing, serialization and lifecycle | Batch project operations prove inadequate |
| Hardware programming/ILA | Device operations and captures using the same jobs/artifacts | Actual board/emulation debug requirement |
| Waveform and signal-graph exploration | Simulation traces, circuit graphs, cross-probing | Real inspection workflow; not needed for flow monitoring |
| Power-domain analysis | Intent, crossings, isolation/retention and supplied verification | Design introduces relevant domains; distinct from physical-design PD |
| Rich power analysis | Activity/model/corner-qualified reports and comparison | Provider supplies meaningful evidence; an unimplemented tile must say unsupported |
| Multi-project sessions/workspaces | Multiple independent roots in one application context | One-project/multiple-window organization no longer suffices |
| Distributed workers / workstation-native attachment validation | Separate execution dispatch or a local client through an SSH forward | Actual deployment need; server-side terminals remain the first target |
| Dynamic plugins and arbitrary theme extensions | Independently loaded extensions and user-authored theme infrastructure beyond F12 | Static typed features and the reviewed appearance axes no longer cover concrete use |

Provider-owned canonical results, registered Workbench evidence, named saved
arrangements, linked/independent contexts, pins and F11's bounded L1/L2 summaries
are delivered. FS1 adds separate bounded rich-inspection indexes and on-demand
detail. Preset-preserving templates and selected presentation persistence are now
delivered. [Window attachment](../features/workspaces/WB-047-window-attachment.md)
and [interactive/freeform layout](../features/workspaces/WB-046-interactive-layout-editing.md)
remain FS3/host followups. Predictive prefetch and more elaborate indexing are
later optimizations justified by measured workloads.
F12's semantic tokens/composable chrome, initial A–E skins and independent
color/icon/density controls and native activity indicators are delivered. Remaining
[presentation tickets](../features/README.md#presentation-and-interaction) cover
richer gallery fixtures, reusable tabs, additional persistent overrides and further
owner review—not reimplementation of current global/header persistence.

Deferred-table items with canonical tickets: comparator WB-012, graphical physical
inspection WB-020, Vivado WB-011, waveforms WB-028 and power analysis WB-026. Broader
Bonsai Web surfaces, persistent Tcl sessions, board/ILA operations, power-domain
intent verification, multi-project sessions, distributed workers and dynamic plugins
remain unticketed deferred ideas here; they are not silently included in those
tickets' story points.
