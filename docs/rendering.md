# Silver — Rendering and Interaction

**2026-10-15 accepted direction:** named workspaces follow shared run contexts by
default, with independent-context and per-tile reference options (D1/F10). Palette
defaults (D2) are approved for FS0; immutable-snapshot detail (D3) remains later.
The new host now delivers a provisional shelf layout and palette, preserving the
legacy RTL/hierarchy inspectors. See [FS0 controls](fs0_terminal.md) and the delivery
plan for implemented behavior; the complete appearance/gallery design remains pending.

**Appearance sources:** the newer [candidate gallery handoff](design/tui_candidate_gallery_handoff.md)
supersedes the [older design handoff](design/tui_design_system_handoff.md). See
[F12](features/appearance.md) and [source interpretation](design/README.md). Preserve
five candidates and independent style axes; no final default is selected. FS0 needs
the host/component seams and legibility, not a completed aesthetic gallery.

The [architecture](hardcaml_workbench_architecture.md) owns semantic boundaries;
the [plan](construction_phase_plan.md) owns implementation order. This document
owns the intended Bonsai Term presentation. Normative requirements below remain
distinct from the implemented host and inspection behavior linked above.

## 1. Workspaces, windows and monitor use

A project session has windows containing named workspaces. A window is an attached
terminal/application surface; Overview, Timing and Resources are workspaces. They
can be switched on one surface or displayed across monitor surfaces. The terminal
emulator/OS handles placement; a monitor is not an application identity.

Start with a useful provisional ASIC layout preset, then let the user move/reorder, resize,
hide/restore and zoom tiles. Save requested layout separately from effective
clamped geometry so shrinking does not destroy the preferred wide layout.
Default workspaces follow Main, one shared run context. Show a concise linkage
label such as `Linked: Main` or `Independent`. A large Overview selector and compact
Timing/Resources selectors all control Main; each keeps its own layout, focus,
filter and scroll. Selected-run indication updates without forced scroll/focus jumps.
No selector owns the context. Make-independent starts from the currently viewed run;
link-to-context immediately adopts its selection. Per-tile pinning is separate.

Illustrative wide window, not a fixed cell budget:

```text
test-asic / Overview     Linked: Main     Selected run: C      Connected
┌ Runs ────────┐ ┌ Flow / operations · C ──────────────────────────────┐
│ C  running  ◀│ │ route: running · elapsed … · observed …             │
│ B  complete │ └────────────────────────────────────────────────────┘
│ A  failed   │ ┌ Timing · C ──────────┐ ┌ Checks / artifacts · C ─────┐
│             │ │ setup: pending      │ │ DRC: pending                │
│             │ │ hold: pending       │ │ report / layout links       │
└─────────────┘ └─────────────────────┘ └────────────────────────────┘
┌ Timing · B [PINNED REFERENCE] ───────┐ ┌ Output · C ─── FOLLOW ─────┐
│ setup/hold, corner, stage, source   │ │ …                           │
└────────────────────────────────────┘ └────────────────────────────┘
```

Clock, physical-design and simulation/test tiles can replace or extend this preset.
The example's run statuses and pending values are illustrative, not captured tool
evidence. Wider dimensions do not automatically summon unwanted tiles.

Workspace selectors, navigation, status/legend and project summaries should be
mountable utility tiles, not permanently reserved screen bands. Commands for
navigation/help remain usable when those tiles are hidden. The small renderer/input/
overlay/recovery host is infrastructure, not mandatory visible application chrome.
Workspace tabs, tile-local tabs and run selection keep distinct semantic actions.

## 2. Run selection and loading

- Follow-workspace-context is the default; tile titles identify their evidence scope.
- Selecting B changes following tiles across every linked workspace. Switching
  never starts a tool. Independent contexts and pinned references stay unchanged.
- Uncached content shows "Loading run B". Do not draw A's values below a B header.
- F11 L1 hits render matching typed summaries immediately; L2 loads and cold queries
  arrive asynchronously. Distinguish cached/unverified, source-unavailable and failed
  refresh states from validated current evidence. A layout repaint is not a fetch.
- Pinned-run tiles identify their reference and retain that binding; newer results
  for the pinned run may update them. Exact snapshot pins, when supported, are frozen.
- New background runs do not steal selection. An explicit launch-and-view action
  targets an explicit run context and affects all linked workspaces once identity
  is known. Capture/revalidation details remain in D2.
- Queued submission before provider allocation has its own label, not a fake run ID.
- Missing saved runs remain unavailable. Do not silently choose another run.
- Unlink/relink invalidates obsolete requests just like changing selected runs.
- Generic tests may be project-scoped with no ASIC run. Label that scope instead
  of displaying the current ASIC run as if it produced those test results.

Expected work may show pending/running animation. Distinguish not requested,
unsupported, no result, failure, cancellation, stale observation and unconstrained
analysis. An unsupported power-analysis tile must not spin indefinitely. Elapsed
time, observation age and measurement age are different fields. Do not fabricate
percentage or ETA from elapsed time or log volume.

## 3. Shared shell and styles

Use Ches as a reference for comfortable spacing, restrained accents, rounded or
thin borders, title/footer labels and clear selection. Reuse design principles,
not editor-specific primary-document assumptions or a dependency on its UI code.

Centralize semantic theme roles: background, foreground, surface, muted, border,
focus, selection, running, success, warning, failure, emphasized metric and active/
inactive tab. One provisional functional-demo skin is enough for FS0, not a final
default. Labels/markers retain meaning without color or special fonts.
Stderr is a stream identity, not evidence of failure; avoid a wall of red logs.

Separate workspace composition, geometry, component skin, color intensity
(`vivid/selective/restrained`), icon mode (`none/ascii/unicode/nerd_font`), density
(`compact/comfortable`) and utility-tile placement. Appearance presets suggest
combinations, not workspace identities. Keep A Instrument, B Structured, C Minimal,
D Studio and E Structured Studio (B+D) for visual comparison; allow D-like tabs in
every candidate. Changing skin/color/icons/density preserves context, pins, tile
identity and interaction state; applying a different suggested geometry is explicit.

Most tiles have configurable headers with title, optional scope/status, tabs,
actions or metrics. Text-only, border-integrated and richer treatments share one
component contract. Headerless widgets remain possible; they still expose evidence
identity/freshness and focus through content/inspection. Avoid nested-box clutter.

Measure terminal display cells, accounting for wide and combining characters.
One geometry computation supplies shell/content rectangles, clipping, scrolling,
cursor and any hit testing. Respect nonzero origins. Tile adapters declare useful
minimum/preferred sizes; degradation reduces decoration before essential context.
At tiny sizes, preserve recoverable navigation/help rather than throw exceptions.

Test wide desktop and modest laptop/tmux cell grids. The target workstation has
four monitors but normally one Workbench surface; do not infer four windows or a
pixel budget from that. Initial narrow recovery can use scrolling/tabs/hiding
secondary details rather than sophisticated automatic responsive rearrangement.

Keep project/run identity and connection health easy to find, but move full IDs,
paths and environment details to inspection. A compact overview may remain visible
in the default preset; users are not forced into one global persistent dashboard.

Owner review (2026-10-15) confirmed that Overview contents render correctly; the
row/grid arrangement remains provisional. The subsequent F06 synthesis inspector
replaced raw producer JSON and long absolute paths in normal synthesis views with
concise labels and full evidence drilldown. This delivered information-density
cleanup is distinct from selecting a final skin or layout.

## 4. Focus and commands

**Current FS1 explorers:** Inspect timing/clocks/physical/routing opens a
full-window, client-local explorer attached to the initiating tile. The workspace
continues to exist underneath; Enter opens row detail, Esc returns to the table,
and another Esc closes the explorer. Selecting the already-active workspace does
not clear its tile's inspector. Space c c still opens the global palette.
Breadcrumbs, mode-specific help, an explicit Close inspector command and concise
detail/provenance hierarchy are [usability followups](backlog/README.md#inspector-usability-polish),
not current features. The owner confirmed the Escape-responsiveness fix; that
confirmation does not imply final aesthetic approval.

The window host routes input to the focused tile and visibly marks focus. A modal
picker/help surface captures input before tiles and global actions. Text entry
must not accidentally trigger build/cancel shortcuts. Keep focus/selection stable
when jobs, logs or results arrive. Select list items by identity, not row index.

Ctrl-C is the global client-exit escape route and precedes all modal/paste capture.
Local navigation and deferred completion now explicitly invalidate the view;
Escape does not wait for the 100 ms display clock. Domain refresh is still polled.
Terminal-multiplexer Escape waits remain separate; the
[measured tmux followup](fs1_investigation.md#escape-responsiveness-in-tmux--2026-10-16-followup)
documents the owner's 500 ms setting and explicit opt-in tuning.
Raw terminal mode disables keyboard-generated OS signals, so checking it only in
a fallback keymap is insufficient. Filters and unfinished paste capture remain
visibly marked even with ordinary chrome hidden; abort restores terminal settings
without cancelling daemon-owned work. PTY interrupt regression covers each mode.

Define command identity, availability/reason, bindings and description once; derive
dispatch, help and hints from that definition. Exact keys are settled during M2;
`Space c c` is the intended palette binding.
Provide discoverable run selection, tile movement/resize, focus navigation,
inspection, context unlink/relink, back/close, help and client exit. Moving a following
tile into another workspace adopts its context; pinned tiles keep their reference.
Moving an entire workspace between windows preserves its context binding.

Reuse/extract the inspected Ches float placement and lifecycle where compatible:
it currently supports one transient float, with release and return-focus behavior.
The palette's modal capture must not become an implicit rule for every future peek.
Gallery help/source-peek examples can be clearly mocked until the adapter exists;
stacked floats and tiled↔floating transitions are not first-demo requirements.
Browser Ctrl+K in the export is illustrative, not a replacement for `Space c c`.

Logs have bounded scrollback and explicit follow state. Scrolling away pauses
follow; a visible command resumes it. Artifact readers page large content and show
retrieval limits. Closing/hiding readers does not stop their generating job.

## 5. Explain and inspect evidence

Timing summaries show setup/hold independently with units, corner/mode, stage,
clock/constraint context and source report. A failed goal links to details and a
short explanation. Checks identify their scope and evidence separately from flow
completion. GDS existence is an artifact fact, not signoff.

Clock and physical-design views explain available observations without inventing
coverage. An overview joining modules displays only compatible run contexts.
For a pinned timing reference, keep differences in corner/stage/constraints
visible. A dedicated comparator is [deferred](backlog/README.md).

Start artifact inspection with text/reports and external viewer actions. The UI
identifies the viewer host and reports unavailable display/transfer capability.
An SSH terminal cannot imply that a daemon-side GUI appears on the user's monitor.
Embedded graphical views are a later scope decision.

## 6. Headless-first implementation

Expose testable Bonsai components with explicit state, dimensions, time and
transport effects. Publish async state changes reactively; use clocks for actual
elapsed/freshness displays rather than periodically rereading all mutable state.
Batch large streams while keeping interactions responsive.

Tests send events through the production frontend, not just its reducers:

1. Select B while A queries are pending; complete A later and verify B stays correct.
2. Pin timing A, select B, and verify only ordinary tiles change.
3. Launch once, hide/move its tile, then reconnect without another submission.
4. Use differently sized selectors in two Main-linked workspaces; selection updates
   both, while focus/filter/scroll stay local. Hide one selector and use the other.
5. Detach Timing at B, select A in Main, then relink Timing and observe A. Reject late
   replies across detach/relink. Repeat across two windows when supported.
6. Resize, restore layout/context linkage, scroll/pause/resume logs and exercise
   modal input capture. Restoring Main must not create one context per workspace.
7. Launch a generic test once, inspect its logs/status in a simulation tile, cancel
   the intended attempt and verify workspace switches never relabel its provenance.
8. Hide/move navigation/status tiles and recover via commands. Switch appearance
   without provider fetches, context/pin changes or lost selection; distinguish
   focused tile, selected row and active tab without relying solely on color.

Use injected responses and controlled clocks; assert actions/state separately from
a few component/frame expectations. PTY checks cover terminal plumbing. Human
review is for style/readability/comfort, not a prerequisite for every interaction.

## 7. Existing baselines

The pre-redesign capture script and fixtures remain useful historical evidence:

```sh
./scripts/capture-terminal-baseline.sh --check
```

Files remain under `test/baselines/terminal/`; the [archived capture notes](archive/2026-10-12/terminal_baseline_captures.md)
describe them. They include synthetic scenarios and do not establish live ASIC
integration. Replace affected expectations deliberately as the new renderer ships,
without promoting unrelated behavior or treating old fixed layouts as requirements.

## 8. Comparative gallery track (FS5)

The [F12](features/appearance.md) gallery uses labeled synthetic Overview and Timing
fixtures across A–E, independent color/icon/density controls, optional chrome tiles
and shared header/tab/table/tree/inspector components. Source panes are placeholders
until real source-navigation/editor integration exists. Gallery fixtures do not
prove timing extraction, per-case test reporting or source mapping.

Implement on current OCaml/Bonsai Term primitives, not an embedded HTML renderer.
Capture terminal frames at wide/narrow cell dimensions and review real variants
before choosing defaults. Its V1 tasks live in the main construction plan as an
independent track, not an extra gate on FS0 functional demos.
