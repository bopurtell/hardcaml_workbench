# Silver — Architecture

Updated 2026-10-16. This is the central product and system design document.

**Active review:** the [feature inventory](feature_list.md) records the October 15
scope, and the [demo plan](construction_phase_plan.md) supersedes P0–P7. Named
i3-style arrangements, a command palette and snapshot-aware references are now
explicit requirements. D1 and the bounded D2/D3 FS0 defaults are accepted in the
[decision log](decisions.md). Workspaces follow shared run contexts and can detach
for independent inspection; immutable snapshot support remains later scope.
Provider reviews below are historical; the adopted public named-flow and durable
observation boundary is implemented. Current FS1 evidence and the exact installed
inspection provider are recorded in [FS1 investigation](fs1_investigation.md), not
in the October 12 source review.
The [construction plan](construction_phase_plan.md) owns phase order and evidence;
[rendering](rendering.md) owns visual and interaction conventions;
[backlog](backlog/README.md) holds explicitly deferred work. Historical decisions
and acceptance records are in [archive](archive/README.md). Coding conventions
remain in [formatting_guide.md](formatting_guide.md).

## 1. Purpose and current status

Workbench is a configurable control and monitoring application for independent
Hardcaml projects. A dedicated monitor should answer what is running, what passed
or failed, what timing/physical evidence exists, and where to inspect its artifacts.
The user continues editing elsewhere and can still build, test and run the project
through its ordinary CLI. Workbench supervises and presents these operations.

Two project profiles are in scope: **ASIC** and **FPGA-only**. An ASIC project's
FPGA emulation targets remain part of that ASIC project. Profiles supply sensible
defaults; explicit capabilities determine which tools, operations and data exist.
Generic Dune projects remain usable without a profile or hardware-specific driver.

Settled direction:

- Bonsai Term first; Bonsai Web is deferred until graphical needs justify it.
- Backend feature modules and independently movable frontend tiles.
- Appearance is separate theme/component/layout policy (F12). Navigation/status
  chrome is generally mountable tiles; only thin input/render/recovery infrastructure
  is mandatory. No final visual candidate is selected.
- A project session has windows containing named workspaces (Overview, Timing,
  Resources). Workspaces normally follow one shared Main run context; they can
  detach into independent contexts. Tiles follow their workspace or pin a reference.
- ASIC flow routing and authoritative results belong project-side, normally via
  `hardcaml_asic`. Workbench is not a required dependency of that library or flow.
- Development uses a dedicated sibling **test-asic repository**, with pinned
  dependencies and reproducible evidence, not the removed scaf worktree.
- **PD means physical design.** Power-domain analysis is a separate possible feature.

Implemented today: installed native daemon/client, generic Dune operations,
supervision/cancellation/logs, manifest/driver discovery, RTL/artifact/provenance
handling and elaborated hierarchy inspection. These are the former 1A–1C milestones.
FS0 now adds typed workspace/ASIC endpoints, persisted run contexts/layouts, a
palette/tile host, generic test module boundary, installed-provider synthesis
integration, explicit-reference run registration and L1/L2 summaries. Actual HTTP,
PTY and two-profile real synthesis acceptance is in the [plan](construction_phase_plan.md).
FS1's functional adopted-evidence scope is complete: capability-checked physical
endpoints, collect/accept finalization lifecycle, bounded reports/artifacts, rich
timing paths, measured clocks, stage-attributed physical/routing inspection and
byte-exact external binary handoff. See [lifecycle](fs1_lifecycle_and_artifacts.md)
and [investigation](fs1_investigation.md) for evidence, limits and provider identity.
The owner also confirms Escape works after the local-redraw/tmux followup.
Local input and deferred/poll completion invalidate the view immediately; domain
refresh remains polled at 500 ms, with a 100 ms clock for time-dependent content.
This is mixed reactive local rendering and polled domain delivery.

The richer contracts below remain requirements where not covered by these bounded
deliveries: broad store discovery, arbitrary layouts/templates, multi-window
adoption and fully subscription-driven domain publication remain later scope.
Embedded graphics and reliable source mapping remain later F06 work; exact external
handoff does not establish embedded or interactive GUI rendering. FS2 structured
simulation remains unstarted.

## 2. Runtime and dependency boundaries

```text
Project session: shared run contexts (Main → A, Investigation → B)
  Window 1                      Window 2
  Overview / Timing             Resources / Investigation
  [workspaces, tiles, focus]     [workspaces, tiles, focus]
                  │ typed application API
                  ▼
Workbench daemon
  session/context/catalog services + feature modules
  jobs / logs / artifacts / provenance / subscriptions
                  │ Workbench provider adapter
                  ▼
Opened project's commands and integration entry point
  Dune / tests / regressions / hardcaml_asic flow dispatcher
                  │ project-side tool/flow adapters
                  ▼
  simulators / LibreLane / OpenROAD / Magic / KLayout / later FPGA tools
```

The daemon runs beside the project/toolchain and owns supervised processes. Client
exit does not stop jobs. The initial deployment is server-side Bonsai Term over
SSH; each terminal application surface represents a logical window. Multiple
surfaces can attach to one daemon/project session. The terminal emulator/window manager
places those surfaces on monitors; Workbench need not manage OS monitors itself.

Clients render portable typed data and send commands. They do not start project
tools, parse raw reports, or turn remote paths into local file handles. Project
code is built in its own compiler/package environment through a separate driver,
not dynamically loaded into the daemon. Workbench's own build switch is not an
implicit fallback for a project's environment.

The existing application transport is versioned S-expressions over loopback HTTP,
Async/Cohttp, with bounded long-poll events and snapshot recovery. Keep instance
checks, cursor sequencing, stale-response rejection, request limits and submission
deduplication. Extend the protocol compatibly where possible; version incompatible
changes explicitly. Source definitions in `protocol/v1.ml` and
`project_integration/driver_protocol.ml` are the implemented wire contracts.

## 3. Feature modules, providers and tiles

Here **module** means a feature subsystem, not an OCaml language module.

| Concept | Owns |
| --- | --- |
| Feature module | Domain processing, semantic state, queries, typed commands and evidence |
| Workbench provider adapter | Translation between a project/backend's public contract and feature contracts |
| Project-side router/adapter | Toolchain/flow selection, tool-specific invocation, collection and interpretation |
| Tile | Rendering and local selection/filter/scroll; emits typed action intent |
| Window host | Attached surface, workspace switching, geometry and focus/input routing |
| Workspace | Named tile arrangement, local investigation state and a run-context binding |
| Run context | Shared selected-run identity/revision, independent of selector tile lifetime |
| Project session | Associated project/catalog, modules, windows and context registry |

The daemon owns the authoritative semantic registry of session/window/workspace/tile
instances and run-context bindings through `Workspace_service`; FS0 persists this
registry alongside the existing project/job/artifact service. Clients mirror it, send typed
intents and retain local presentation state: dimensions, active-workspace display,
focus, scroll, open overlays and effective clamped geometry. Persist requested
layouts/preferences through UI-configuration services without making live terminal
dimensions or one client's focus global. Build the registry once, not per appearance
candidate; the gallery may inject the same contracts with clearly mocked state.

A module can serve multiple tile types and clients. A composite tile can read
several module contracts. A WNS summary and a corner table share timing data;
they do not each launch extraction. No tile need be visible for work to continue.
Moving/hiding/closing a tile is distinct from cancelling or stopping its source.

Start with statically assembled typed subsystems using existing daemon services.
Neither a separate process per module nor dynamic plugin loading is required.
Provider data is structured domain data, not a list of already formatted tile rows.
Keep backend meaning independent of colors, geometry and frontend toolkit.

F12 separates theme tokens, components and layouts in the frontend. Headers/tabs/
palette actions consume explicit typed state and F03 command IDs. Provider data
supplies measurement context, severity/verdict and availability where meaningful;
colors/icons are frontend mappings, not provider acceptance policy. Workspace
composition, requested geometry and appearance preset are distinct configuration.
Changing skin/density/icons/color preserves IDs, contexts and F11 cached summaries.

### Feature contract

Each feature declares identity/version, supported capabilities and unavailable
reasons; project/target/build/run scope; snapshots and bounded revisioned updates;
queries and commands; operation acknowledgements; and evidence references.
Evidence includes producing tool/stage, measurement context/units, source report,
constraints, source/build/environment identity and observation/measurement times
as applicable. A tile supports specific typed contracts, not arbitrary payloads.

Pure rendering and subscription must not implicitly execute work. Expensive
analysis is an explicit operation with status, cancellation and result identity.
Multiple consumers share published data; module dependencies refer to existing
facts rather than reparsing another feature's report independently.

### Asynchronous queries and rendering

Feature modules live daemon-side. Tiles use typed Workbench APIs; they never invoke
`hardcaml-asic-flow` directly. Subscriptions may cause bounded read-only provider
queries on cache misses, not synthesis/implementation or expensive new analysis.
Rendering itself reads frontend state and performs no provider I/O.

The daemon coalesces equivalent in-flight queries and shares cached results across
modules/tiles/windows. One report can feed several projections; independent reads
can run asynchronously with bounded provider concurrency. Observation/watch readers
fan out updates to many subscribers. Existing per-root execution queues must not
force safe read queries to wait until a physical job completes; respect provider
locking/consistency for any operation that changes evidence.

Switching a context updates labels/loading immediately. Cached summaries render
first; other results arrive independently without a global readiness barrier.
Scope/revision checks prevent obsolete replies from repainting the wrong run.
Unsubscribing releases query interest, not execution ownership. Keep pinned/shared
consumers alive and cancel only truly unneeded safe read work. Bound queues, pages,
cache entries and update batches so provider reads do not stall input processing.

This is asynchronous coordination in the existing native Async application, not a
process-per-tile design or an assumption that the provider is a persistent RPC
server. CLI reads, watch processes and any future public provider service are
adapter implementation choices. See [F02](features/modules_and_tiles.md) for tests.

## 4. ASIC provider routing and ownership

For projects adopting `hardcaml_asic`, use it as the **main ASIC-side flow router
and result authority**. The project's declaration/entry point supplies design,
target, environment and operation configuration. A Workbench adapter invokes
that public entry point or the configured installed `hardcaml-asic-flow` command
and translates its results into Workbench feature data.

`hardcaml_asic` can route to LibreLane and its tools without Workbench knowing
their orchestration rules. Magic/KLayout operations can supply execution, checks,
PD information and artifacts to several features. They are not necessarily separate
top-level Workbench providers. Tool-specific parsing and ASIC acceptance policy
belong with the ASIC flow; Workbench translates and displays their meaning.

Do not force every project operation through the ASIC router. Ordinary Dune builds,
unit tests and project-specific regressions may use direct project adapters. They
share Workbench's execution/log model and associate with builds/runs only where
that relationship is real. Other ASIC backends may implement the same Workbench
contracts later; `hardcaml_asic` is the preferred first implementation, not a
mandatory dependency for generic or FPGA use.

The dependency direction is:

```text
hardware project → hardcaml_asic public library/CLI
Workbench ASIC adapter → that project's configured public integration
hardcaml_asic → its tool/flow implementations
```

`hardcaml_asic` must remain usable without Workbench. New catalog/progress/report
APIs should be generally useful machine-readable flow APIs, not tile-specific APIs
requiring Workbench libraries. A versioned project driver can compose those APIs
with project tests and regression commands.

### Historical inspected foundation and missing integration — 2026-10-12

The next three subsections preserve the October 12 review and proposed contract,
not a current upstream work queue. The adopted public observation/read/report
integration is delivered; see [FS0 integration](fs0_provider_integration.md),
[FS1 lifecycle](fs1_lifecycle_and_artifacts.md) and the current
[inspection contract/provider generation](fs1_investigation.md#source-and-provider-boundary).
Old Python source paths and missing-interface claims below describe that review's
baseline, not the installed implementation used for current acceptance.

Inspection on 2026-10-12 found the installed dispatcher and collector in
`hardcaml_asic/flow/hardcaml_asic_flow/`, with `run.json`, `results.json`, distinct
run IDs and archives. `phase4.run` writes an initial record before preflight;
`cli.execute_sequence` emits its aggregate JSON at the end. That is useful stored
evidence, not proof of a complete live event/substep or early run-announcement API.

Before integration, define provider contracts for run discovery, early allocation,
observation/update revisions, reports/artifact lookup, stage operations and
cancellation. Add missing ASIC semantics in `hardcaml_asic` and consume them through
the Workbench adapter. Do not scrape human summaries or guess identity from the
newest directory. This document does not claim those additions have been made.

For future FPGA work, Vivado is an expected tool provider; project-side
`hardcaml_xilinx`/report libraries may supply structured data. FPGA workflows still
have Dune/tests/simulation/artifact providers, not only Vivado. Live FPGA integration
is deferred; shared contracts are exercised with fixtures first.

### Historical provider integration review — 2026-10-12

Source review at ASIC commit `f6e8fd7` (clean checkout) confirms three existing
layers: OCaml project/build/bundle generation in `lib/`, the installed Python
dispatcher in `flow/hardcaml_asic_flow/`, and the external LibreLane/tool processes.
Keep those layers; this integration does not require rewriting the runner in OCaml.
Structured provider events can be decoded into typed OCaml values by Workbench.

The main missing layer is a durable **run observation interface** over the
existing runner and result collector, not another scheduler or a UI-aware router.
ASIC-side records know nothing about workspace, window, tile or selection IDs.
They expose facts that any number of independent observers can consume.

There are two levels of steps to expose: outer operations such as preflight,
implementation, postcheck and collection, and the actual implementation steps
inside LibreLane. Instrumenting only `execute_sequence` leaves placement/routing/
Magic/KLayout activity hidden inside one long operation. The provider describes
step hierarchy, stable occurrence/attempt identities, requested extent and actual
skip/gating decisions; Workbench can group those for display without inventing a
fixed seven-step execution model.

The local LibreLane distribution reports version `3.1.0.dev3`, matching the flow
pin. Its sequential flow calls `step.start` directly, and `Step.start` is marked
final; merely overriding `Flow.start_step` is not a proven interception strategy.
It writes per-step input/output state and metrics, but directly rather than by
atomic replacement. These are promising observation sources, not a validated
callback API. This source copy is under a Python 3.12 venv while the bundle requests
3.11; inspecting it does not validate the intended execution/container environment.

Prototype and choose a version-pinned integration seam inside `hardcaml_asic`:
supported lifecycle hooks if available, otherwise validated structured-state
observation with explicit limits, or a narrowly scoped upstream instrumentation
change. Avoid copying the flow engine's sequencing or guessing failures/skips from
missing directories. Test the actual container/native path to which support applies.

### Historical durable observation and result-snapshot proposal — 2026-10-12

The proposed public boundary supplies:

| Capability | Consumer-visible information |
| --- | --- |
| Describe | Contract versions, operations, observation/result capabilities and limitations |
| List / inspect runs | Explicit configured store, run/build identity, requested scope, status, timestamps and revisions |
| Inspect step plan/state | Parent/child steps, stable occurrence and attempt IDs, status/reason and known times |
| Observe updates | Early allocation, step state changes, result availability and execution/operation outcomes with a replay cursor |
| Read results / artifacts | Bounded snapshots and evidence references with producing step, source context and version |

These are conceptual operations, not committed CLI spellings. Preserve the current
one-final-JSON stdout contract of existing commands; an explicit observation mode,
separate journal or read/watch operation can expose updates without breaking it.
The early allocation record carries request correlation for the launching client;
the same run is discoverable when launched outside Workbench.

Prefer durable recorded updates with a current-state projection over an ephemeral
stdout-only stream. Define one authoritative write path, ordering/revisions,
single-writer or lock policy across standalone postcheck/collect operations,
snapshot-to-cursor consistency and recovery from a truncated update. Polling and
streaming are delivery choices over that same record. Readers must tolerate
duplicates and reconnect; absent observers must not block flow execution. An
observation failure must be explicit, never a fabricated successful stage.

Publish result data completely before advertising its reference. A result snapshot
is evidence at a step, not necessarily a restartable physical checkpoint. Retain
earlier snapshots when later steps fail or produce newer measurements. Separate
step completion from result publication so collection failures remain visible.

LibreLane state metrics are cumulative. An output state after step N may contain
timing measured at step N-2. Track the actual producer/measurement context and
distinguish inherited from newly generated values; numeric equality alone cannot
decide whether a metric was remeasured. Never relabel carried-forward values as
fresh post-route timing merely because they appear in a routing output state.

Keep legacy `run.json` status semantics intact during migration: currently a run
can be marked completed when physical execution finishes, before `execute` performs
postchecks/reporting. An observation summary separately exposes implementation
status, requested-operation status and check/goal outcomes. It does not reinterpret
the old field as "all requested work and signoff succeeded."

Finalization/archive support must preserve the step/result history advertised to
clients. Existing archives deliberately omit most intermediate state and require
completed runs. Extend preservation with explicit policy for observation snapshots
and diagnostic evidence from failed runs; do not silently relax the existing
completed-run archive or acceptance contract. Legacy records remain readable with
step history explicitly unavailable rather than reconstructed as fiction.

The historical provider handoff and its relation to ASIC's then-existing P6 work
are in the [archived plan](archive/construction_phase_plan_2026_10_12.md#asic-provider-handoff-within-workbench-p1).
Use the active demo plan for current adoption work; this handoff is not a fresh
upstream implementation queue.

## 5. Builds, runs, operations and jobs

| Identity | Meaning and owner |
| --- | --- |
| Project | Independent source repository and its configuration |
| Build | Immutable elaborated/emitted input bundle, when the backend has one |
| Run | Provider-owned execution attempt against inputs, with its result history |
| Operation attempt | A requested action or supported stage against an explicit scope |
| Job | Workbench's supervision record for submitted work, with logs/status |

One build can have multiple runs. One run may be associated with multiple jobs
for collection, postchecks or supported continuation. A generic build/test job
need not have an ASIC run. Do not invent a build/run reference when unavailable.
Use provider IDs scoped by project/provider; existing `Build_ref`/`Run_ref` values
carry provider identities rather than replacing them with Workbench job IDs.

Re-executing implementation normally creates a new run. Collecting or inspecting
an existing run does not. Continuing selected stages is supported only if the
provider defines it: it validates compatible inputs/prerequisites and records the
new operation attempt. A retry must not erase previous failures/check attempts.
The UI cannot manufacture arbitrary resume semantics from a list of stage names.

### Launch and observation

Submission creates a queued job immediately. The provider announces a run as soon
as it allocates one, including request correlation, requested extent and original
build identity. Until then, show an explicitly pending submission, not a fabricated
provider run ID. Failures before allocation remain visible as failed submissions.
Runs launched through the CLI become discoverable through the same catalog.

After allocation, the new run appears in run selectors. A plain launch does not
implicitly steal selection. An explicit launch-and-view action targets a run
context: selection changes affect all workspaces linked to that context, not just
the initiating window. Independent contexts and pinned tiles remain unchanged.
D2's bounded FS0 capture/revalidation defaults are accepted in the
[decision log](decisions.md#d2--command-and-context-semantics).
Background arrivals do not steal selection. A report tile shows
pending only when its measurement is expected for that requested operation; if
power analysis was not requested or supported, show that instead of a spinner.

Separate process liveness, log activity, known stage/substep progress, tool exit,
timing goals and verification. A finished process or GDS artifact does not imply
signoff. Loss of observation is not completion. Never invent a percent or ETA.

## 6. Project sessions, workspaces and run contexts

```text
Project session: test-asic; shared project/run catalog: A, B, C, ...
  Main context → C
    Overview workspace: large selector | flow C | resources C | logs C
    Timing workspace: compact selector | timing C | timing A [pinned]
    Resources workspace: compact selector | resource breakdown C
  Independent context → B
    Investigation workspace: selector | timing B | physical design B

Window 1 and Window 2 can display these workspaces on separate monitors;
one window can also switch between named workspaces.
```

A project session initially associates with one project root. A window is an
attached terminal/application surface. A workspace is a named switchable tile
arrangement, not a physical monitor. Authoritative results remain provider-owned;
closing a workspace/window never deletes results or stops execution.

Run contexts are Workbench session state. Each owns stable identity, selected run
(possibly none) and selection revision. Default workspaces bind to Main. Separate
project sessions do not accidentally share Main merely because their labels match.

Any number of run-selector tiles control the same context through their workspace
bindings. Overview's selector has no special authority. Selectors share the selected
run, but keep independent geometry, focus, filters, browsing cursor and scroll.
Changing selection updates all linked workspaces without forcing another selector's
navigation position to jump. Hiding the large selector does not disable the others.

**Make independent** creates a context initialized to the current selected run and
rebinds that workspace only. **Link to context** adopts the target context's current
selection. Start with Main/independent; advanced named groups can follow. A context
cannot be discarded while another workspace still references it.

**Tile binding** answers which evidence a data tile displays:

- **Follow workspace context** (default): use its bound context's selected run.
- **Pin run**: display a named other run; newer evidence can still update it.
- **Pin result snapshot**: exact immutable observation where the provider supports
  it; initial scope/retention remains open in D3.

Dedicated comparison/deltas are later work. Cross-run stage/corner/unit/constraint
differences remain visible. Run pinning is accepted and does not imply frozen data.

Serialize context selection transitions through authoritative session state and
increment selection revisions. Bind responses to context/revision plus run/query/
result identity; unlink/relink also invalidates obsolete requests. Uncached tiles
show loading for the new run, never A's number under B's label. Pinned references
remain unchanged; composite views join compatible identities explicitly. Providers
need not finish loading simultaneously. Selecting evidence never starts analysis.

Window/workspace/tile identities are stable. Moving within a workspace changes
geometry only; moving a following tile between workspaces adopts the destination
context, while a pinned tile retains its reference. Moving a whole workspace across
windows retains its context binding. Closing/hiding are distinct host actions,
neither a provider lifecycle command. See [F10](features/run_contexts.md).

## 7. Storage and fast switching

The [F11 cache specification](features/run_summary_cache.md) makes fast switching
an FS0 requirement. Use L1 decoded domain summaries in daemon memory and L2
persistent normalized summaries in a separate Workbench store; canonical provider
records remain the source of truth, not an expendable third cache tier. Cache typed
facts rather than tile-rendered text or geometry. Implemented files live in the
daemon's configured Workbench state directory, outside canonical provider results:
`asic-<identity-digest>.sexp` for the registry and
`asic-<identity-digest>-summary-v1-<report-digest-hash>.summary.sexp` for summaries.
The filename's v1 is distinct from the summary blob schema (writes v4, reads v1–v4).
L1 holds 32 summaries; L2 indexes up to 128 runs, each summary at most 256 KiB
(32 MiB indexed payload). The namespace includes project root, environment and
complete ASIC configuration. [F11](features/run_summary_cache.md) also records the
separate bounded inspection cache used by FS1.

On context switch, use L1 when available, asynchronously load L2 on a memory miss,
and only materialize provider results on a cold/invalid entry. Share equivalent
requests across modules/windows. A current-observation index maps run/query to
versioned observations; late fetches must not regress it. Completed runs can still
receive newer results. Adapter/schema changes invalidate incompatible derived data.

Keep small active/pinned/recent summaries hot within byte/entry budgets; a last-3–5
run working set is a workload example, not an unlimited retention guarantee. Large
path tables, waveforms and raw artifacts remain separately paginated/provider-backed.
L2 hits appear as cached/unverified; ordinary switching does not validate provider
edits. Explicit Refresh is required for current validation; the adopted summary
contract has no cheap provider revision query.
Source disappearance or refresh failure remains visible. Corrupt/incompatible cache
entries rebuild safely; cache writes publish complete entries atomically.

Acceptance includes unchanged resident A→B→A switching without new report queries,
and L2 reopening without re-materializing unchanged large reports after restart.
Account separately for lightweight freshness checks/live observation and measure
latency/working sets before promising a fixed timing budget.

Split storage by ownership:

| Store | Owner and purpose |
| --- | --- |
| Input bundles, runs, raw reports, check attempts and archives | Project/ASIC provider; durable source of evidence, useful from CLI |
| Run catalog/index and normalized summaries | Workbench; derived, rebuildable acceleration over provider records |
| Window/workspace layouts, context registry/linkage, selections and pinned references | Workbench UI configuration; durable preferences, not flow evidence |
| Job/process supervision | Workbench daemon; live process handles are not restart-persistent |

Persist context identities and linkage, not just a selected run copied into each
workspace. Restore Main-linked workspaces to one shared context. Layout templates
create distinct view instances with intended linking defaults; session restoration
can retain concrete references. Persistence is separate from selection linkage.

Avoid copying every large physical output into another Workbench store. Register
provider-backed artifacts through daemon-mediated lookup; materialize bounded
content/cache entries when useful. Keep the existing private imported-RTL path
for its current use case. Retention/deletion of canonical flow evidence belongs
to the provider/project; cache eviction must not delete it.

Cache summaries by project/provider, run, source record revision or digest and
adapter/schema version. Completed implementation records can still acquire a new
postcheck or collection revision: "completed" does not mean every derived record
is permanently immutable. Refresh/invalidate explicitly. Paginate large catalogs,
logs and detailed reports; keep common summaries warm so run switching does not
require reparsing large tool reports or launching tools.

Missing, moved or unreadable canonical data remains explicit. A persisted run
selection cannot silently switch to a different run. Cached evidence can be shown
as cached/unverified with its recorded source identity; it must not look freshly
confirmed. Rebuild the index and reopen a named result after daemon restart
without executing the flow. Current cache formats/budgets are implemented in the
Workbench store; they do not create a second authoritative result model or settle
the later immutable-snapshot/archival retention policy.

## 8. Feature map

These are feature boundaries, not a requirement to implement every possible view.

| Module | Shared responsibility | ASIC detail | FPGA detail |
| --- | --- | --- | --- |
| Context | Source, target/configuration, environment, hierarchy | PDK, technology, harness | Device/board |
| Execution | Operations, stages, elapsed time, logs and cancellation | Physical flow/tool progress | Vendor implementation jobs |
| Simulation/tests | Generic test attempts, optional cases/seeds, outcomes and failure evidence | Cyclesim/RTL/gate-level/regression adapters | Simulation/emulation suites |
| Artifacts | Roles, provenance, retrieval and viewer actions | GDS, LEF/DEF, extracted data | Bitstreams/checkpoints |
| Timing | Setup/hold, WNS/TNS, paths, constraints, units, corner/mode | Physical multi-corner STA | Vendor timing |
| Clocks | Declared/generated clocks, relationships and coverage | CTS skew/insertion latency | PLL/MMCM/device networks |
| Checks | Independent verdicts and report evidence | DRC/LVS/antenna/precheck | Implementation/methodology checks |
| Resources | Contextual measurements | Cell/macro area, utilization | LUT/FF/BRAM/DSP |
| Physical design | ASIC-specific implementation context | Floorplan, power grid, placement, CTS, routing/congestion | Later device view can share contracts without pretending to be ASIC PD |

WNS is part of timing, not necessarily a separate backend module. Clock facts are
owned by clocks; timing references them rather than maintaining conflicting clock
definitions. A clock inventory does not prove CDC verification. Report tools and
providers retain acceptance policy; Workbench should explain and link evidence,
not invent universal thresholds or a signoff verdict.

The [simulation/test module](features/simulation_and_tests.md) begins with existing
supervised Dune test operations, not an embedded simulator. Project-owned test
adapters can add structured cases and trace artifacts. Generic test attempts are
project-scoped unless real build/run provenance exists; selected ASIC run context
must never fabricate that association. Waveform exploration remains a later feature.

## 9. Inspection, rendering and verification

First deliver bounded text/report viewers and explicit external artifact viewer
actions. A viewer adapter resolves artifact IDs, tool arguments and files. Specify
whether it runs on the daemon host or client machine: a remote daemon has no
implicit desktop display, and remote files may need transfer. Embedded graphical
Magic/KLayout canvases are deferred.

Use Ches as a design reference for independent feature/view lifetime, shared shell,
capability-based input routing and requested/effective geometry. It is not a runtime
dependency. Workbench has no mandatory editor-like primary document tile. See
[rendering](rendering.md) for presentation, selection and focus behavior.

The [imported gallery handoff](design/tui_candidate_gallery_handoff.md) guides visual
experiments, with [interpretation notes](design/README.md) correcting assumptions
about existing implementation. Reuse/adapt Ches's inspected single-transient-float
placement/capture/release seams before introducing overlays; no full stacked float
manager or editor embedding is established by those APIs. Domain-free shared UI
packaging is a possible extraction outcome, not an FS0 prerequisite.

FS0 needs replaceable tokens/headers, optional utility chrome, consistent geometry
and safe input. FS5 compares A–E on identical mock Overview/Timing fixtures in actual
terminal cells. Browser screenshots are visual references, not terminal or real-flow
acceptance. Keep backend extraction independent of the appearance review schedule.

Develop against the sibling test-asic project with pinned `hardcaml_asic`, tools,
PDK and constraints. Keep real archived reports plus deterministic/synthetic replay
fixtures; identify which is which. The existing counter fixture remains for fast
Dune/RTL/hierarchy checks. Real-tool acceptance cannot be replaced by canned data.

Test providers and reducers headlessly, then use Bonsai Term's actual input path
with injected transport, controlled time and dimensions. Prove run selection,
stale-response rejection, linked selectors, independent contexts, pinned views and commands
without manual clicking. Pure reducer tests alone do not prove UI wiring. Use a
few component/frame expectations and installed/PTY checks; human review focuses
on appearance and comfort. Bound event/log volume and update incrementally so
long regressions do not freeze interaction.

## 10. Migration and release boundary

Keep the working daemon, supervision, integration and protocol reducers. Extract
feature and workspace boundaries incrementally. Current roles are `protocol/`,
`project_integration/`, `adapters/`, `backend/`, `daemon/`, `native_http/`,
`terminal/` and the deferred `web/`; new source boundaries follow demonstrated
contracts rather than a speculative directory/framework rewrite.

The first release operates the test ASIC through project commands and the ASIC
provider: build/test/regression, live physical-flow observation, selectable durable
runs, timing/check/artifact inspection, bounded clock/PD views and monitor windows
with linked or independent contexts and movable tiles. Demonstrate a pinned reference tile, reopening
results after restart and continued execution after client detach. Exercise FPGA
profile composition with fixtures; a live Vivado implementation is deferred.

Development commands are in the repository [README](../README.md). Phase completion
and new evidence belong in the [plan](construction_phase_plan.md), not a growing
second development diary. Deferred features go to [backlog](backlog/README.md).
