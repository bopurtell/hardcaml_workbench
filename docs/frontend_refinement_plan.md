# Frontend refinement: panel chrome, Overview and Timing workspace

Activated 2026-10-16 from the owner's review of the composition delivery. This is
the shared implementation plan for this request, not a reopening of FS2.

## Accepted scope

- Styled rounded palette frame matching the Instrument skin, colored prompt/caret
  and selected item, separate fuzzy-match emphasis, and a blank separator before
  the footer. Preserve captured execution, forms, modal input and Esc restoration.
- Reusable panels with title in the top border; short Session/Run selector tiles
  retain borders. Reduce vertical padding while keeping a little horizontal space.
  Navigation consumes one row plus a normal gutter, not four empty rows.
- Width-aware run labels: show full useful labels/IDs whenever they fit, abbreviate
  only for actual available cell width. Keep exact IDs in all commands and details.
- Run-selector capacity shows actual total/visible capacity; increasing row count
  must request enough layout height when possible, not only increase an invisible cap.
- Horizontal stage progression strip; wrap/fallback for narrow viewports, preserve
  keyboard stage selection, detail and explicit plan/launch semantics.
- Compact Overview summaries for synthesis, timing, placement and routing, plus
  checks and finalization/signoff when space permits. Reuse shared typed domain
  data; compact presentation is a mode, not a new backend provider. Keep unknown,
  unrequested, stale, completed and accepted facts distinct.
- Evolve the existing Timing preset into an investigation workspace with path list,
  selected path detail and provenance/context panes. Explicit typed investigation
  selection is local to the workspace/client and fenced by run/stage/digest; pane
  scrolling/focus remain independent. No hidden global selected path across clients.
- Inspect timing paths should open/focus this workspace. Preserve the captured run
  without changing unrelated shared run selection. Existing FS1 non-timing explorers
  remain available. Inspection actions remain read-only; browsing does not run EDA.
- Keep the synthetic demo on the same OCaml definitions. Preserve existing saved
  extras, pins and contexts; expose explicit Apply/Reset rather than silent deletion.

## Working rules

Work in `/home/wayne/devel/jane/silver`. No git add/commit/push/merge or
authorship mutations. Keep user state/configurations and live sessions untouched.
Ches is read-only reference if needed. No real physical flow is needed; private
synthetic/Cyclesim fixtures provide acceptance. Use `/tmp/opencode` for test state.

Three agents maximum, each **2 jobs**, serial commands in distinct absolute build
dirs `/tmp/opencode/refinement-{panels,overview,timing}`. No coordinator build while
agents compile. Final verification serial at `-j 2`, within the owner's maximum20.

## Ownership and interfaces

### Agent A — panel/palette rendering and final render integration

Own `terminal/host_view.ml`, `terminal/palette_view.ml`, new `terminal/panel.ml{,i}`,
`terminal/tile_presentation.ml{,i}`, and `terminal/dune`. Implement styled reusable
frame/title geometry and palette first. Add new B/C modules to dune when available.
Do not edit `main.ml` or `workspace_host.ml` (C owns them); publish any policy/API
changes needed there. After B/C handoff, wire compact summaries, horizontal stages
and Timing panes into host rendering, preserving exact geometry for input handling.

Use a distinct vertical-padding decision: preserve the existing density axis and
explicit padding controls without wasting two rows in every short panel. Any new
policy fields need sparse defaults and matching source-preset mapping via C.

### Agent B — Overview composition and compact/horizontal components

Own `terminal/workspaces/common.ml`, `layout.ml`, `overview.ml`, `testing.ml`,
workspace tests, new `terminal/overview_summary.ml{,i}`, and utility helpers in
`overview_tiles.ml` as needed. C owns `workspaces/timing.ml`; coordinate common
helper changes without editing it. Own synthetic provider/demo scripts and their
acceptance adaptations when needed, plus a new refinement acceptance harness in
a subsequent phase. Do not edit A/C shared host/runtime files.

Publish typed semantic summary rows/panels and a horizontal checklist view model
which A can render with shared styles; no keyword-derived engineering verdicts.
Add optional client minimum-height inputs to layout computation for selector
capacity rather than a special second geometry calculation. Preserve extra/custom/
duplicate tiles and zoom/narrow fallback. Overview should fit the four primary
domains at 120x40 and add checks/finalization sensibly; use compact pairs/grid rows
if six full-width panels cannot fit. Pane content takes priority over hints/provenance.

### Agent C — Timing investigation model/runtime and workspace preset

Own new `terminal/timing_workspace.ml{,i}`, `terminal/inspection_view.ml` as needed,
`terminal/workspaces/timing.ml`, `terminal/main.ml` and `terminal/workspace_host.ml`.
Implement actual list/detail/provenance composition state and runtime effects over
existing Asic inspection API/cache. Supply A with renderer helpers and integration
instructions; A owns final host rendering. Do not invent a new backend scheduler.

Ensure exact captured-run opening: if the normal Timing workspace already resolves
that run, use it; otherwise establish explicit independent/pinned investigation
binding without changing another workspace's shared run context. Label the choice
and preserve existing pins. Prefer a dedicated new independent Timing investigation
arrangement when reusing an existing one would overwrite user work. Stable preset
identity controls layout, not display name. Existing saved Timing layouts migrate
additively only on explicit inspect/apply. Full-screen non-timing inspection stays.

Requests and responses must be fenced by daemon/project, workspace selection epoch,
run/domain/stage and source digest/row identity. Selected path, corner/group/filter/
sort are shared only by cooperating panes in this client workspace. No shared
global scroll. Keep palette forms, FS2 actions, paste and Ctrl-C intact.

## Acceptance

- Styled palette bounds/background, rounded borders, colored prompt/caret, selected
  and matched emphasis, footer gap, similar-command navigation and Esc restore.
- Session/run-selector frames at default short sizes; border titles reclaim rows;
  density and explicit overrides work; navigation has no surplus vertical allocation.
- Long distinguishable run names use available width, selected entries stay visible,
  capacity changes alter actual panel height when space allows; no semantic mutations.
- Horizontal checklist all six stages on wide terminals, narrow wrapping and exact
  stage detail/plan action without inferred completion or unwanted producer calls.
- Overview exposes synth/timing/placement/routing at120x40 with compact valid facts;
  additional checks/finalization, pin/follow identity and unsupported evidence honest.
- Actual timing workspace list/filter/sort/corner/group/select/detail/provenance,
  palette overlay, run changes, delayed responses and independent workspace selection.
- Geometry/unit tests, full format/lint/build/tests at2, private native HTTP/PTY for
  synthetic flow, FS2 regressions and interrupt restoration. Capture80x24/120x40/large.

## Status

**Implemented and verified.** Final full format/lint/tests/build passed serially
at `-j 2` in normal `_build`. Final native refinement passed57 checks plus12 checks
with only two registered runs; composition44, FS2 45, synthetic launch/cancel and
five-mode interrupt regression all passed. See the
[current controls/source map/evidence](frontend_refinement.md).

Agent handoffs below are chronological. Their in-flight host assertions and earlier
captures are superseded by final post-polish verification. The selected-path pane
now starts actual provider detail on line5; raw provenance is separately scrollable.
User live state/configuration and Git index/history were left unchanged. Owner
visual review remains separate from automated acceptance.

### Agent A — first-pass panel API / integration handoff

- `Panel.geometry` owns frame feasibility, inner size and **independent** horizontal/
  vertical padding. `Panel.render` consumes exactly that geometry and an already
  visibility-filtered `View.t` title. Instrument uses rounded Unicode; structured
  skins use square Unicode; ASCII/None use ASCII. Frames need only 4×3 cells, not
  the former >8-row threshold. Palette chrome explicitly yields at <6 rows.
- `Host_view.panel_geometry` and existing `body_geometry` are the shared hooks.
  The latter retains its five-tuple API (inner width/height, horizontal inset,
  actual body width/height), now reclaiming the heading row when framed. Paging
  must continue to consume this hook rather than subtracting guessed chrome.
- Existing sparse `Tile_presentation.padding` now controls **horizontal** inset;
  vertical inset is independently zero in `panel_geometry`. This keeps density
  and explicit padding controls effective without costing two blank rows. **C:
  no new policy record field or source-preset mapping is needed.** `Panel.geometry`
  exposes a distinct vertical argument for any future deliberate vertical inset.
- Border titles honor header/title visibility and independent badge visibility;
  unframed/tiny panels retain the inline heading/badge. No binding is changed.
- Run selector labels use actual body cell width, preserving full IDs when they
  fit and using cell-aware middle shortening only under pressure. Status has an
  aligned bounded column. Heading reports visible/filtered-total and requested
  cap. `P.Layout.compute ~min_height_for_index` is wired for selector capacity;
  B should retain that optional API and single-source layout fallback.
- `Palette_view.query` accepts optional `prompt_attrs`, `caret_attrs`, `caret`;
  `result_row` accepts `marker_attrs`. Fuzzy spans use the typed `Matched` theme
  role, independent of selection/prompt roles. Footer has one reserved blank row.
  Overlay source rendering is unchanged; forms retain a tail-anchored multiline
  prompt and visible caret.
- `overview_summary` and `timing_workspace` now exist and have been added to
  `terminal/dune`. B/C renderer integration remains the next pass; their semantic
  APIs can use `utility_attrs` / `evidence_attrs` and actual body geometry.
- First-pass verification passed serially at `-j 2` in
  `/tmp/opencode/refinement-panels`: `@terminal/runtest`, `terminal/main.exe`,
  `@terminal/fmt`, and `@terminal/lint`. New tests cover short rounded/ASCII frames,
  zero/tiny finite geometry, independent padding, width-aware Unicode labels,
  aligned selector status, and distinct ANSI prompt/selection/fuzzy attributes.
  Existing palette scrolling, captured forms, hidden-header pins and source overlay
  tests also pass. The checklist hint test now explicitly enables hints, because
  B's compact preset intentionally defaults them off.

### Agent B integration API (implementation in progress)

- A: add `overview_summary` to `terminal/dune`. `Overview_summary.rows
  ?stage_id ~kind ~run ~summary ~stages ()` returns `Overview_tiles.row list`;
  render with the existing role styling. Exact stage ID defaults to kind; aggregate
  terminal facts are labelled aggregate, never attributed to that stage. Run/digest/
  producer/source provenance is retained in row details. Keep detailed synthesis
  rendering for explicit Cells/Details/Metrics/Evidence modes.
- A/C: map new sparse `Common.presentation.compact_summary : bool option` and
  `horizontal_stages : bool option` to presentation policy/source presets. Both
  default to None and have sexp defaults. Only Overview declares them true.
- A: `Overview_tiles.Stage_strip.model ~appearance ~width ~run ~selected_id stages`
  supplies wrapped `lines : item list list`, `selected : item option`, and
  `selected_line : row`; each item retains exact `stage : Asic.Stage.t` and semantic
  `row`. `Stage_strip.render ~appearance ~attrs ~width ~height model` is an optional
  renderer. Selected detail is reserved a separate line even when strip rows clip.
  Keep existing keyboard/actions keyed by exact stage.id, never display name.
- A: `Layout.compute ?min_height_for_index definition ~width ~height ~kinds`
  accepts `(int -> int option)` over the *visible ordered kinds list*. Supply actual
  selector required outer height from your panel geometry and runtime row cap.
  The override applies to duplicate/custom extras and fallback grid too; insufficient
  total space returns Compact. Zoom still bypasses layout. No parallel geometry pass.
- Overview now declares ten existing-provider tiles: tabs, session, selector, stage
  strip, synthesis/timing, placement/routing, checks/finalization. Tabs are one row
  plus the ordinary slicing gutter. At120x38 content area the six summary panels
  fit in three two-column rows. At80x22 the existing focused Compact fallback applies.

### Agent B completed handoff

- Implemented the APIs above. A has added `overview_summary` to dune; library build
  passes. Compact panels and stage strip suppress redundant run-reference/hint rows;
  exact provenance remains inspectable. Navigation explicitly requests no frame/padding.
  Finalization prioritizes reported acceptance and physical completion in short panels.
- `Stage_strip.model` uses terminal cell widths, preserves provider order and full
  labels/records/actions, wraps rather than abbreviating identities, and reserves the
  selected-stage line. Inspection uses `selected.row.details` / `selected_line.details`.
- `Layout.compute` applies runtime minima before both primary-tree and fallback-grid
  placement, including duplicate extras. `Narrow` retains its narrow allocation even
  in an otherwise all-fixed-height upper band. No saved geometry or membership changes.
- Verification in `/tmp/opencode/refinement-overview`, serial `-j 2`: eight workspace
  tests pass; ten Overview summary/utility tests pass; owned OCaml files formatted.
  Coverage includes actual Panel geometry/render bounds at80x24/120x40/240x80,
  all six evidence panels at120x40, arbitrary sparse/duplicate/extra memberships,
  selector runtime minimum-height growth, long stage labels and verbatim action IDs,
  zero/missing/nonfinite/unavailable metrics, freshness and foreign-run fencing.
- Earlier broad `dune runtest terminal` reported three A-owned failures (host form
  query-tail, host density/padding, panel short-frame geometry); focused B tests pass.
  Runtime/source-policy mapping and final host render integration remain A/C work.
  Synthetic presentation-script adaptation and the new refinement acceptance harness
  remain the requested next phase, after runtime integration is ready.

### C handoff (in progress)

A: please add `timing_workspace` to terminal/dune. New tile kinds are
`timing-paths`, `timing-detail`, `timing-context`. Render each using
`Timing_workspace.pane tile.kind`, then `Workspace_host.timing host tile` (returns
None on mismatched binding), and `Timing_workspace.rows ~pane ~scroll:local.scroll
~width ~height view`. Do not invoke full-screen inspection overlay for these tiles;
their state is workspace-local (`host.timing`), not `local.inspection`. Empty/mismatched
state should say explicit Inspect required, never display another run's evidence.
Palette remains the normal final overlay. Runtime keyboard and opening are C-owned.

### Agent C — functional runtime handoff / verification

- Implemented `Timing_workspace.{pane,create,selection,input,rows}`. `pane` maps
  `timing-paths` → Paths, `timing-detail` → Detail, `timing-context` → Context.
  Selection is typed exact run/domain/stage/source-digest/row-ID. Shared query state
  includes filter, numeric/name sort, corner/group/producer, near threshold and stage.
  Host stores one `Timing_workspace.t` per stable workspace ID; pane scroll remains
  `Host.local host tile.id).scroll`, focus remains normal tile focus. Detail/context
  scrolling clamps at both ends. Path browsing retains the selected-detail request
  only while the selected row remains identical and never extracts on movement.
- `Host.timing host tile` is the renderer accessor. It rejects mismatched tile run
  bindings and stale context-ID/selection-revision epochs immediately, including an
  A→B→A context switch. `main.reconcile_synthesis` resets stale workspace intentions
  with a fresh generation and reads existing exact-run cache without extraction.
  Transport responses also retain existing daemon-instance/project/request fences;
  inspection tickets enforce generation/run/domain/stage/digest/row identity.
- `main.open_timing_workspace` handles `Browse_inspection (run,"timing",stage)`.
  Uses stable preset identity, requires matching context and *all* user pins, applies
  the preset additively on this explicit action, focuses Paths, and retains existing
  matching query/selection state. If context/pins differ it creates a uniquely named
  captured-run arrangement, makes its context independent, checks independence was
  actually accepted before selecting the run, then applies Timing. Main and existing
  pins remain intact. Hidden Paths are preserved by choosing a fresh arrangement.
  Already-loaded exact-stage rows are used without another Inspect request.
- Controls: Tab/Shift-Tab pane focus; j/k/arrows path selection or focused-pane scroll;
  n/N paging; `/` literal filter, Enter/Esc finish filter, Ctrl-U clear; `s` sort;
  c/g/p corner/group/producer cycles including ALL; `v` near; `t` explicit stage
  index inspection; `r` explicit refresh; Enter explicit selected detail. Space
  prefix/palette remains usable above the workspace. The existing literal filter
  paste gate now routes to workspace state, retaining Ctrl-C-first handling.
- Generic FS1 clocks/physical/routing full-screen explorers and artifact overlays
  remain tile-local and take precedence while open, including from a Timing pane.
  A: keep existing local inspection/artifact overlay rendering; the dedicated model
  itself never occupies `local.inspection`.
- B policy handoff integrated via `Host.composition_policy`, `Host.compact_summary`
  and `Host.horizontal_stages`: sparse neutral Common fields default false. A can
  call those directly without adding chrome fields to Tile_presentation. Existing
  runtime selector movement already uses A's `body_geometry` and actual row cap;
  please notify C if a new selector body row reserves capacity differently.
- Verification: executable build passed at `-j 2` in
  `/tmp/opencode/refinement-timing`; 34 focused inline tests passed (Timing_workspace,
  Workspace_host, Inspection_view), including actual path selection/detail identity,
  independent workspace contexts, preserved mismatched pins, immediate run/epoch
  invalidation, stale detail responses, pane-local scrolling and literal Timing paste.
  Full `dune runtest ... terminal` initially passed, but the later integration run
  failed A-owned `host_view.ml` checklist assertion near line2312 expecting
  `r prepare NEW run` and `placement: running`. No A-owned file was modified by C.
- Remaining handoff: A must render the three kinds through `Host.timing` and
  `Timing_workspace.rows` at actual body geometry (module already registered).
  Final native/PTY acceptance and complete suite belong to coordinator integration.
- Final C rerun: executable build and all 34 focused tests passed after artifact/
  generic-explorer precedence fixes. Explicit Enter also consumes an already-cached
  exact-row detail without another extraction. Existing zoom on a Timing pane is
  respected (that pane receives focus); unrelated zoom remains preserved in its old
  arrangement while Inspect establishes a dedicated investigation.

### C resumed review (active)

- A/B: dedicated Paths now uses two compact header rows (count/stage/cache/error,
  then query/axes) and value/unit/status + exact reported startpoint→endpoint rows;
  no full-screen `INSPECT` heading. Runtime paging uses the same height minus two.
  `Timing_workspace.path_items` exposes typed `{ row; selected; label }` for optional
  exact-identity selection styling; `rows` API is unchanged. Context includes controls.
- A: compact synthesis renderer guard correctly respects explicit non-Summary modes;
  runtime Enter / metrics / Cells / Details dispatch already changes the same state.
- Inspect must focus **Paths**: a saved detail/context/unrelated zoom now gets a new
  independent investigation instead of reusing that arrangement. Existing zoom and
  hidden/custom tiles remain preserved. A saved Paths zoom can be reused safely.
- Strengthened epochs include workspace ID, context/binding revision and Timing pane
  bindings; every received transition invalidates old requests. Tickets now carry
  the workspace epoch too, preventing a moved tile response from landing in a different
  workspace with coincidentally equal generation/run/stage/row. Esc closes the local
  selected-detail reader without sending any producer cancellation.
- A integration follow-up: your typed `timing_body` uses a four-row header budget.
  C has aligned `Timing_workspace.rows` and keyboard page movement back to **four**
  rows (tiny panes retain one path), superseding the two-row note above. No host edit
  needed for that budget. Consider surfacing `view.pasting` / `view.filter_notice`
  alongside `view.editing` so rejected pasted control text is visible; source state
  already safely captures the payload. `path_items` remains available for typed
  selection styling / reported endpoint labels.
- Latest full terminal-suite attempt during A integration: four A-owned host_view
  assertions failed: Overview four-primary-domain visibility (~2108), quiet-chrome
  preset (~2511), checklist detail (~2996), warm synthesis run-switch compact frame
  (~3810). Executable still builds; focused C tests pass. C did not edit those tests
  or A's rendering to accommodate in-flight failures.
- C finalized rerun: all owned OCaml files formatted with switch `5.2.0+ox`;
  `terminal/main.exe` builds and all 34 focused inline tests pass at `-j 2`, serial
  `/tmp/opencode/refinement-timing`. Negative coverage now additionally exercises
  pin round-trip fencing, distinct-workspace tickets, closed-reader late receipts,
  same-digest replacement rows, stale index-refresh errors and 1000-down/one-up
  detail scrolling. Opening checks the freshly allocated context is absent from the
  pre-open registry and is neither Main nor shared before selecting the captured run;
  removed-workspace races stop rather than dereference a missing arrangement.

### C screenshot refinement — investigation-first Timing composition

- Timing's default tiles no longer include `stage-checklist`. Layout is one-row
  navigation, Session + wide selector top row, then Paths left and Detail/Context
  stacked right. At120×38 host content, primary panes resolve to Paths47cols and
  right72cols (weights2/3), Session30cols and selector89cols. Detail has weight3,
  Context2. Minimums fit120×40; normal narrow fallback remains. Existing saved
  checklist/custom/hidden/duplicate tiles remain extras via unchanged additive
  preset semantics; no stored arrangement or pin is deleted/rebound.
- Dedicated Detail no longer invokes generic `Inspection_view.build_detail_lines`.
  Its first four lines are width-bounded `Path: <name>`, `Slack: <value/unit> ·
  <reported status>`, `Corner: <corner> · Group: <group>`, and `Endpoints:
  <reported startpoint> → <reported endpoint>`. Long summary values get an ellipsis;
  all complete values remain in Context. Provider-returned text follows immediately
  (line5), or an explicit unrequested/pending/error/empty response message.
- Context contains run/domain/stage, cache/truncation facts, digest/execution/SHA256/
  diagnostics first; then complete row ID/name/producer/category/status/value/unit/
  corner/group, **full raw source JSON/path**, and **every reported field**. No
  provenance is discarded. Rendering stays pure and pane scroll/state fences are
  unchanged. Generic non-Timing full-screen explorers are unchanged.
- **A handoff:** replace the old metadata reconstruction in `timing_semantic_prefix`
  with `Timing_workspace.semantic_prefix ~pane ~width view`, returning typed
  `(line_role * string) list` (`Selected`, `Metric`, `Metadata`, `Pending`, `Failure`).
  Detail prefix has exactly four one-line summary rows when selected. Context prefix
  is its complete unwrapped provenance; apply normal wrapping. Derive first selected
  line styling from this prefix, not the old wrapped `Row: id · name` height, or long
  names can accidentally style actual provider text. Provider payload after Detail's
  prefix stays neutral. Public `rows` / `input` / selection APIs remain unchanged.
- Added focused height10 acceptance with >2KiB source JSON and 3KiB raw field:
  actual provider text must appear on line5, while full Context preserves source,
  payload, full name, digest, execution SHA and diagnostics. Added actual120×38
  layout geometry test (no default checklist, wide selector, correct stack/ratios).
- Build and all36 focused Timing/Inspection/Host state tests pass (`5.2.0+ox`, serial
  `-j 2`, `/tmp/opencode/refinement-timing`). Full terminal suite has one expected
  A-owned stale assertion at `host_view.ml:2386` demanding old `Row: 29` in Detail;
  it now belongs to Context. Host prefix assertions also need the API handoff above.

### Agent A — final integration in progress

- Wired `Host.compact_summary`, `Host.horizontal_stages`, B's semantic summary/
  strip APIs, and `Timing_workspace.pane` / `Host.timing` into host rendering.
  Timing Paths renders typed selection/status/value columns with the same four-row
  paging budget as C; Detail/Context consume C's exact body-width rows and scroll.
- C coordination: first integration build is blocked at `workspace_host.ml:214`
  (`view` inferred as `Inspection_view.ticket` but `Inspection_view.t` required).
  A has not edited C's files; please resolve that annotation in the current review.
- Selector runtime requests now use the existing resolved layout tree's minimum
  sizes and remaining height budget, so a huge requested cap does not force an
  otherwise-fitting Overview into focused fallback. Actual rows still consume
  `body_geometry`; there is no parallel cell-placement calculation.

### Agent A — final renderer integration complete

- `Host_view.compact_summary_enabled` / `compact_rows` now use
  `Host.compact_summary` and `Overview_summary.rows`. Overview displays all four
  primary domains at120×40, plus checks/finalization. Explicit Cells/Metrics/Details/
  Evidence and terminal detail still use the original readers. Freshness controls
  operate on typed compact rows; aggregate facts remain labelled aggregate.
- Horizontal stages use `Host.horizontal_stages` and `Stage_strip.model/render`.
  The selected line reserves room for reported status and the actual stage ID,
  rather than repeating a name/ID and clipping status on narrow panes. Wrapping
  preserves provider order and actions. Explicit hints remain effective, including
  matching-plan Launch / Launch and view prompts; default Overview suppresses them.
- Timing rendering uses `Timing_workspace.pane`, `Host.timing` and
  `Timing_workspace.rows` with exact `body_geometry`. Shared rounded frames carry
  distinct Paths / Selected path / Provenance titles. Paths has typed selection,
  value and reported-status emphasis, reported startpoint/endpoint labels, axes,
  counts, cached/truncated status, paste/filter notices and a visible input caret.
  The four-row paging budget is aligned with C's current runtime, including tiny
  fallback. No mismatched run/epoch model renders through this accessor.
- `Host_view.timing_semantic_prefix` styles typed Detail/Context field labels,
  values, status and cache metadata, checking each span row against C's wrapped
  output before using it. Free-form report text remains neutral. C retains scroll/
  wrapping authority; tests compare text at three geometries and top/middle/end
  offsets, plus exact typed-prefix compatibility with C's current controls rows.
- Border title budgeting now prioritizes independently visible pin identity even
  with a visible title at32 columns. Selector titles report actual visible/filtered
  counts and requested cap, labels use available cell width, and layout requests
  are limited to the existing tree's remaining height (million-row cap regression).
- C's earlier type-inference blocker is resolved upstream; A did not modify
  `main.ml`, `workspace_host.ml`, `inspection_view.ml`, Timing model or workspace
  definitions. Old renderer assertions now assert compact counts/evidence and
  explicit selected-stage identity while retaining run-switch/pin/registry checks.
- **PASS**, final source, serial2 jobs in `/tmp/opencode/refinement-panels`:
  `scripts/with-switch.sh dune build --build-dir /tmp/opencode/refinement-panels
  -j 2 @fmt @lint @runtest terminal/main.exe`. All A-owned OCaml files were formatted
  with the exact switch immediately before this command. Full repository tests
  include execution projection, daemon failure/cancellation/log/driver/provenance
  coverage and FS2 backend simulation. New host tests cover actual120×40 panels,
  one-row navigation + gutter, short frames/border titles, bounded selector growth,
  horizontal wrapping, Timing identity/scopes/styling/paste and actual palette
  footer separator/caret. No remaining renderer test failure is known.
- Native HTTP/PTY refinement acceptance and captures remain B/coordinator work;
  no physical flow or retained demo session was used by A.

### Agent B — native refinement acceptance complete

- Added `scripts/test-frontend-refinement.py`: existing-binary-only private native
  HTTP/PTY acceptance, exported OCaml presets, default300s wall-clock bound, owned
  process cleanup. Reuses the composition screen/ANSI/SVG oracle and lifecycle.
  A separate two-registered-run phase verifies actual `Runs 2/2 (cap4)` reporting;
  the main phase registers six runs and verifies true selector viewport growth.
- Native checks cover rounded palette border/title and colored prompt/caret, exact
  fuzzy spans and selection, blank footer gap, Tab/Shift-Tab and exact source-cell
  restoration; short framed Session/selector, one-row tabs + one gutter, full long
  distinguishable run IDs; all six horizontal stages, exact stage detail/action,
  exactly one explicit Plan and no producer on browsing; six compact evidence
  domains and honest not-evaluated acceptance despite completed physical work.
- Timing native acceptance verifies composed Paths/Selected path/Provenance panes,
  numeric ordering, actual j/k selection of a non-first row and exact digest-fenced
  provider detail, filter/sort/corner/group, Enter, independent detail scrolling and
  pane focus, palette restoration, run A→B invalidation, independent captured-run
  opening protecting Main and an existing pin. Clocks/routing overlays still work.
  Actual cell screenshots retained at80x24/120x40/180x55/240x80.
- Updated `test-frontend-composition.py` and `test-synthetic-flow.py` only for
  intentional presentation changes: Timing now has cooperating panes, compact
  Overview labels, reclaimed palette title row, actual selector title/counts,
  explicit hint enabling in the zoomed launch test, and fresh revision acquisition
  after explicit zoom mutations. Palette command helpers now explicitly choose
  the highest-ranked result after edits (selection identity is otherwise retained).
  Exact producer/plan counts, selected-run attribution, acceptance/color distinctions,
  launch semantics, cancellation and full synthetic provider checks remain intact.
  `test-fs2-native.py` required no changes.
- Matching binaries built serially at `-j2` in `/tmp/opencode/refinement-overview`;
  Cyclesim counter built separately/serially under its `cyclesim` sub-build directory.
  All acceptance runs were serial. Final passing evidence:
  - Refinement (49 explicit checks plus required capture predicates):
    `/tmp/opencode/frontend-refinement-fb0ee09a5c18/result.json`; two-run companion
    `/tmp/opencode/frontend-refinement-fb0ee09a5c18-two-runs/result.json`.
  - Full composition: `/tmp/opencode/frontend-composition-3cf67a72be58/result.json`.
  - Synthetic provider + native HTTP/PTY + exact-once launch/cancellation:
    `/tmp/opencode/synthetic-flow-m2k4l9tx/pty-verified.json`,
    `integration-verified.json`, `cancellation-verified.json`.
  - FS2 HTTP+PTY: `/tmp/opencode/fs2-native-yu6i5uq0/`.
  - Interrupts: `/tmp/opencode/workbench-terminal-interrupt-q1dp4u45/results.json`;
    all five cases pass, no hangs, exit0 and terminal flags restored.
- Binary hashes, key/HTTP/provider logs, `.txt`, `.ansi`, `.cells.json` and `.svg`
  screenshots are retained in the corresponding evidence directories. No remaining
  native acceptance blocker is known. No shared terminal source changed in this phase.

### Agent A — canonical Timing visual-prefix integration

- Replaced host metadata reconstruction with
  `Timing_workspace.semantic_prefix ~pane ~width`. The small host adapter only
  performs the same final sanitation/wrapping as `Timing_workspace.rows`, carrying
  C's typed roles: Selected→Selection, Metric→Metric, Metadata→Muted,
  Pending→Warning, Failure→Failure. Removed all old wrapped `Row: id · name`
  selected-height calculations. Actual C scroll clamping/offsets remain authoritative.
- Detail's four canonical summary rows are styled; actual provider payload starts
  on line5 and stays neutral, including when scrolling directly into that payload.
  Context retains complete identity, source, reported fields and digest provenance.
  Existing shared border titles and zero vertical padding remain in effect.
- Updated host tests for Path/Slack in Detail and exact Row29 in Context, retaining
  row/digest selection assertions. Added actual120×40 layout assertions for Paths
  left and larger Detail over Context right, no default checklist, and shared framed
  zero-vertical-inset panes. Added long-name/2KiB-source/3KiB-field renderer coverage:
  raw provider text appears on line5, has exactly neutral ANSI attributes both at
  the top and after scrolling, and complete provenance remains in Context.
- **PASS** after exact-switch formatting of every A-owned OCaml file:
  `scripts/with-switch.sh dune build --build-dir /tmp/opencode/refinement-panels
  -j 2 terminal/main.exe @terminal/runtest @terminal/fmt @terminal/lint`.
  Serial2 jobs; no C/B implementation files were edited. The prior B native evidence
  predates this screenshot refinement; an updated screenshot/native rerun is the
   remaining visual acceptance follow-up, not a known compile/test failure.

### Agent B — post-polish native acceptance (final)

- Rebuilt matching daemon/client/preset-export binaries serially at `-j2` in
  `/tmp/opencode/refinement-overview` after C/A's canonical Timing prefix/layout
  refinement. Updated only harness presentation expectations in
  `scripts/test-frontend-refinement.py` and `scripts/test-synthetic-flow.py`;
  no shared terminal implementation changed in this follow-up.
- Refinement now checks actual framed pane cells: at120x40 the first four Detail
  rows are Path/Slack/Corner/Endpoints and the complete six-line exact provider
  detail starts on line5 and fits visibly. Fresh default layout is Paths-left,
  Detail-over-Context right, with no vertical checklist. A non-first selected row
  also exposes its own provider payload immediately on line5.
- Context native scrolling exposes the exact selected row ID, complete raw source
  JSON and all reported fields; the full exact source digest is checked independently.
  Provider Detail remains visible/unchanged during Context scrolling. A shorter
  120x32 viewport verifies genuine independent Detail scrolling now that the short
  provider payload fits completely at the polished normal sizes. Exact backend row/
  digest text comparisons, filter/sort/axes, palette restoration, Main/pin protection,
  captured-run independence and run-change invalidation assertions are preserved.
- All five final suites ran serially and passed; refinement's300s budget sufficed:
  - **57 refinement checks** plus capture predicates:
    `/tmp/opencode/frontend-refinement-e41e2e8d24b9/result.json`.
  - **12 two-run capacity/palette checks**:
    `/tmp/opencode/frontend-refinement-e41e2e8d24b9-two-runs/result.json`.
  - **44 full composition checks**:
    `/tmp/opencode/frontend-composition-25481b162854/result.json`.
  - Synthetic provider smoke + native HTTP/PTY, exact-once launch and cancellation:
    `/tmp/opencode/synthetic-flow-y0hx51su/` (`pty-verified.json`,
    `integration-verified.json`, `cancellation-verified.json`, `smoke-verified.json`).
  - **45 FS2 native HTTP/PTY checks**:
    `/tmp/opencode/fs2-native-n3pc_ana/result.json`.
  - **5/5 interrupt cases**, exit0/no hangs/terminal flags restored:
    `/tmp/opencode/workbench-terminal-interrupt-49omjzgu/results.json`.
- Polished native cell captures (`.svg`, `.txt`, `.cells.json`, `.ansi`) under the
  final refinement directory: `refinement-timing-120x40`,
  `refinement-timing-polished-180x55`, `timing-context-full-provenance`,
  `timing-selected-second-row`, and `timing-detail-pane-scrolled`. Other Overview/
  tiny/palette captures remain included. Binary hashes and HTTP/key/provider logs
  are retained with results. Earlier failed/intermediate evidence remains unchanged
  with its original status; prior49-check passes predate this visual refinement.
  No final native acceptance blocker remains.
