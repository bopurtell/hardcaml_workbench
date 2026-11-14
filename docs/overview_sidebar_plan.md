# Dense Overview sidebar, color schemes and planned-run display

Activated 2026-10-16 from the owner's latest visual review. Previous refinement
changes are already staged by the owner; leave the index untouched. This pass adds
unstaged edits only. No git add/commit/push/merge or other authorship operations.

## Accepted scope

- Pack panels more closely in a Lazygit-inspired arrangement. Reduce inter-tile
  gutters without overlapping border/content cells. Quiet one-row workspace tabs.
- Lowercase tile titles and remove decorative leading dots/diamonds. Use styled
  borders/selection to indicate focus instead of changing semantic text. Never
  lowercase run IDs, provider content or user-supplied labels as a side effect.
- Overview left column approximately one third of width: Session, Run selector,
  vertical Stage checklist stacked. Sidebar width and tile heights should be clear
  source configuration; retain live run-row capacity control. Checklist must have
  readable width and not dump all aggregate evidence ahead of stage entries.
- Overview right column: individual full-width synthesis, timing, placement,
  routing, checks and finalization summaries stacked top-to-bottom, then planned run.
  Prioritize the four primary domain panels when narrow/tiny space cannot show all.
  At 120x40 compact key facts should be visible, not consumed by repeated chrome.
- Timing's Paths-left/Detail-over-Provenance topology stays intact. Shared schemes,
  lowercase titles and tighter gutters apply there, but do not move its run selector
  into the Overview sidebar or replace its investigation layout.
- Independent live color schemes: dark near-black, neutral slate/graphite, a
  Ches Crimson-inspired option and retain the prior neon palette for comparison.
  Default to a subdued slate background. Scheme is independent of A-E skin,
  Vivid/Selective/Restrained intensity, icons and density. Switch via command palette
  without changing workspace layout, selection, pins, data or provider calls.
- A small project-scoped `planned-run` tile at the bottom of Overview's right stack
  displays actual current preview selection: flow/profile/endpoint, assignments,
  readiness/error and inspectable exact plan identity. It is a **plan**, not an
  already queued or allocated job. No fake run ID or implied resume. Enter may show
  complete metadata; launching stays an explicit existing command.
- Empty/pending/failed/stale preview states are explicit; retain prior preview only
  if clearly labeled. Do not show old successful preview as ready during a new plan.
  The tile reads shared daemon snapshot/client request facts, never launches work
  on render or follows an unrelated selected historical run.

## Working rules

Workspace: `/home/wayne/devel/jane/silver`. Preserve all staged changes
and live demo sessions/configuration. Read Ches at `/home/wayne/devel/ches/ui/theme.ml`
as reference only. No real ASIC flows or sibling-source changes are expected.
Tests use private state under `/tmp/opencode`.

At most three general agents, each <=2 build jobs, serial commands per agent and
separate build dirs `/tmp/opencode/sidebar-{theme,layout,preview}`. Coordinator
performs no competing builds; final checks run serially at `-j 2`.

## Ownership

### A — themes and final renderer integration

Own `terminal/appearance.ml`, theme helper if useful, `host_view.ml`, `panel.ml`,
`palette_view.ml`, `terminal/dune`. Add Scheme enum/field with backward-compatible
sexp default and actual semantic role palettes; inspect Ches Crimson, adapt with
attribution and readable contrast. Lowercase host-generated tile titles, remove
decoration marker from headers. Keep selected list markers and pinned badges.
Publish exact Scheme API to C for palette integration. Add C's new `planned_run`
module to dune when it appears, then wire its typed rows/model into host after
handoff. B owns library geometry; don't edit its files.

### B — dense Overview and reusable geometry

Own `terminal/workspaces/common.ml`, `layout.ml`, `overview.ml`, workspace tests,
`overview_tiles.ml` and `overview_summary.ml` if needed for compact prioritization.
Do not edit timing.ml except trivial signature adaptation coordinated with C (no
topology change). Add a clear ratio/weight layout primitive or explicit configurable
sidebar proportion; avoid relying on `Narrow` minimum width to approximate one-third.
Packing should be shared/configurable; keep safe zero/one-cell gutters and all tile
rectangles in bounds. Use source constants for sidebar/selector/checklist heights,
with runtime selector min-height overrides still respected and bounded.

Six summary tiles plus preview must fit as a single right stack at120x40, with
important metrics before redundant validated/status boilerplate; retain stale or
unavailable warnings and full typed provenance via detailed views. Preserve extras,
duplicates, pins and hidden state; no silent destructive reset. Add planned-run kind
to Overview membership. In a subsequent pass own private native acceptance scripts
and adapt earlier presentation expectations without removing behavioral coverage.

### C — planned-run semantics/runtime and palette scheme commands

Own new `terminal/planned_run.ml{,i}`, `workspace_host.ml`, `main.ml` and focused
tests in those files. Add project-scoped tile kind, optional metadata/detail mode,
read-only shared model from Asic.Snapshot.preview/operations plus exact local Plan
intent as needed. Tie readiness to requested selection and completed plan operation;
handle retries, failure, supersession, delayed polls, daemon/project replacement and
other-client preview changes. Retain generic launch exact-preview guards; no new
scheduler/provider or implicit producer calls.

Coordinate A's Scheme API: expose palette `Color scheme: ...` actions preserving
all other appearance fields; avoid touching A files. Appearance remains client-local
unless an existing implemented preference store applies; document actual lifetime.
Tell A exact planned-run renderer/model API and any added host data field. Keep
Timing workspace semantics and FS2 launch forms unchanged.

## Acceptance

- Actual Overview captures120x40/180x55: ~1/3 sidebar, vertical stages, right panels
  full main width in order, planned-run bottom. No horizontal stage strip or paired
  synth/timing panels in this preset; small sizes degrade honestly.
- Tight gutters and lowercase unadorned titles verified, distinct focus/pin identity,
  long run strings preserved to available width and row expansion still meaningful.
- Scheme changes show distinct background/border/accent roles in both Overview and
  Timing, contrast/state colors remain usable, no geometry/selection/provider change.
- Planned-run empty -> explicit r Plan pending -> ready correct flow/profile/endpoint
  -> inspect identity; failed/stale/new-plan states don't reuse ready old preview.
  Historical run selection does not retarget the plan; launch remains explicit and
  allocated identity separate. Test actual HTTP/PTY plus pure race/error tests.
- Previous Timing inspection, synthetic launch/cancel, FS2 and interrupt acceptance
  retained. Full format/lint/test/build serial at2. No modifying the Git index.

## Status

**Implemented and verified.** Normal-checkout full format/lint/tests/build passed
serially at `-j 2`. Final normal-binary actual HTTP/PTY sidebar/scheme/plan acceptance
passed106 checks at `/tmp/opencode/overview-sidebar-835bf5f34f02/`. Composition,
refinement, synthetic launch/cancel, FS2 and five interrupt cases also passed; see
[current controls, source settings and evidence](overview_sidebar.md).

Handoffs below are chronological. Their in-flight integration assertions and pending
native-test notes are superseded by the final results above. Existing staged work,
user configurations and live state were left unchanged; new edits are unstaged.

### B — geometry/content handoff (2026-10-16)

- Implemented `Common.Weighted_columns of (int * tree) list`: positive weights
  divide the whole available width, with proportional descendant minimum checks.
  Existing `Columns`, `Narrow` and all constructors retain their behavior.
- `Layout.compute ?gutter` defaults to `0`; explicit `1` restores blank-cell
  gutters. All frame rectangles remain disjoint (adjacent bounds use `<=`).
  Extras/duplicate kinds retain occurrence/index association and fallback; layout
  never writes requested geometry, binding, hidden state or zoom state.
- Overview source constants: sidebar/main weights `1:2`; session/selector minimum
  heights `7/7`, checklist `10`, each right panel `5`. Navigation is one row.
  Right stack is synthesis, timing, placement, routing, checks, finalization,
  **planned-run**. Checklist sets `horizontal_stages=false`, `compact_summary=true`.
  At 120x40 (38 host content rows), seven right frames have 3+ content rows each.
- **A integration required:** call `Overview_summary.rows ~compact:true` for
  compact-summary policy (default `false` retains prior row ordering). Compact
  output puts a typed fact first with stale/refresh warning on the fact, explicit
  stage status second, then remaining facts; full provenance survives inspection.
  Remove the old positional `i <> 1` freshness filter in `compact_rows`: index 1
  is now the stage status, and stale warnings on metrics must remain visible.
  For checklist utility rows use `Overview_tiles.checklist_rows ~compact:true
  ~stages ~aggregate:facts ()` only for compact Overview, not detail mode. This
  shows stage rows first and retains aggregate facts in first-row inspection
  details; default false preserves the former aggregate-plus-stages ordering.
- **C integration:** `planned-run` is already in Overview membership and the
  layout, using compact summary chrome. No host/runtime fields were changed by B.
- Tests: workspace suite passes with serial `opam exec --switch=5.2.0+ox -- dune
  runtest --build-dir /tmp/opencode/sidebar-layout -j 2 terminal/workspaces`.
  Includes ratio, ordered right stack, zero/one gutters, real selector growth,
  bounded excessive min-height fallback, shuffled duplicate/custom membership,
  sparse membership and tiny viewport bounds. Added compact stale metric + failed
  stage semantics and checklist inspection preservation tests.
- Subsequent verification: `opam exec --switch=5.2.0+ox -- dune runtest --force
  --build-dir /tmp/opencode/sidebar-layout -j 2 terminal/workspaces terminal`
  passes after shared host expectation updates arrived. Both adapted Python
  acceptance scripts pass `py_compile` with cache redirected under the private
  layout build directory. `git diff --check` passes. Edited OCaml files formatted
  with `opam exec --switch=5.2.0+ox -- ocamlformat -i <owned files>`.
- First full terminal test run built successfully but exposed old host assertions
  in `host_view.ml` tests named `Overview renders four primary domains ...`,
  `host horizontal stages ...`, `actual preset host resolves quiet chrome ...`,
  and `checklist follows exact run ...`; A owns adapting these after renderer
  integration. B adapted only the two strict blank-gutter assertions in
  `timing_workspace.ml` to `>=`; no Timing topology edits.
- Native acceptance phase: `test-frontend-refinement.py` now measures actual frame
  rectangles at120x40/180x55, one-third sidebar, ordered seven-panel main stack,
  zero gutters/no overlaps, lowercase titles, vertical six-stage checklist;
  checks full long run identities in zoom and actual selector viewport growth.
  Existing Timing detail/sort/filter/independent context/pin and no-producer
  coverage remains. `test-frontend-composition.py` counts selector rows within
  its actual frame rather than obsolete global first-12-row band. Native execution
  awaits A's compact content integration; no passing native result claimed yet.

### C integration API (available now)

- New `terminal/planned_run.ml{,i}` must be added to A's terminal dune library.
  Host state now has `planned_run : Planned_run.t`, project/daemon scoped, independent
  of registry selection. No `host_data` changes needed.
- Renderer: `Planned_run.model host.planned_run`, then `Planned_run.rows model
  ~detail:local.utility_detail`. Rows are `{ role; text }`, roles `Fact | Muted |
  Warning | Error | Success`; model status is `Empty | Pending | Failed | Stale |
  Ready`. Map roles to A's semantic attrs. Use tile kind/title `planned-run`, project
  binding, no resolved historical run/producer or fake queued identity. Summary has
  status and actual selection/assignments; detail adds exact identity, operation key,
  requested intent and full JSON. Enter/Esc use existing local utility detail;
  j/k/arrows/brackets scroll bounded rows. Rendering must sanitize provider text.
- Checklist preview hints should use `Planned_run.launchable host.planned_run preview`
  as well as selection match, to avoid calling retained previews ready after a new Plan.
- Scheme API detected: `Appearance.Scheme.{all,key,label,equal}`, field `scheme`.
  C palette commands are `Color scheme: Carbon/Slate/Crimson/Neon`, preserving all
  other fields. Appearance remains client-local until restart.

### C runtime/model handoff

- `asic_request` captures each local Plan before preference I/O yields, records the
  request's generation-scoped receipt independently of snapshot ordering, and requires
  an observation at/after its receipt floor. Failed HTTP receipts remain failed rather
  than making an earlier successful preview launchable. Retry generations cannot accept
  older receipts. Request serials discard delayed snapshots, and daemon/project scope
  plus physical client identity invalidates replaced/reconnected transport responses.
- Readiness requires exact typed selection plus the exact completed `plan:` operation
  key from existing `Plain_rpc.keys` (same typed sexp/SHA256 behavior as backend), no
  JSON scraping. Any active shared plan blocks ready. Once a local plan is confirmed
  ready, release its intent fence so later other-client previews can become current.
  Completed-but-superseded local intent is stale; unknown/expired operations are stale.
- Existing palette Launch and Launch-and-view now also require `Planned_run.launchable`
  at command construction and execution, retaining the existing exact preview equality,
  allocation-target/context and launch-and-view guards. No new scheduler or Run path.
- Main handles Enter/Esc local detail and scrolls j/k/arrows/brackets using A's actual
  wrapped rows and tile body dimensions. Detail labels retained/unconfirmed preview
  explicitly. Stage `r` still dispatches only advertised typed `Plan`; browsing,
  appearance commands and rendering have no producer effects.
- Focused tests in `planned_run.ml` cover old-ready → pending → transport failure,
  retry/new-ready, same-selection replan, delayed snapshots/receipts, supersession,
  other-client pending/current-ready and scope replacement. `workspace_host.ml` tests
  scheme commands preserve every other appearance field/registry/plan state, Enter
  only activates inspection, and historical run selection does not retarget the plan.
- Verification uses switch `5.2.0+ox`, serial `-j 2`, build directory
  `/tmp/opencode/sidebar-preview`. Executable build passed before subsequent concurrent
  A/B edits. Final focused rerun status will be appended below; no Git/index mutations
  or live-state writes performed by C.
- Final C verification **PASS**: exact-switch `ocamlformat --check` on all four
  owned OCaml files; `dune build --build-dir /tmp/opencode/sidebar-preview -j 2
  terminal/main.exe @terminal/lint`; focused inline runner `inline-test-runner
  terminal_presentation -only-test terminal/planned_run.ml -only-test
  terminal/workspace_host.ml -show-counts`: **31 tests, 2 test modules**. Earlier
  broad `dune runtest ... terminal` encountered B's in-progress layout assertions
  and A's transient test compilation edits; those files remain their owners' work.
  Coordinator should perform the final full-suite/PTY acceptance after integration.

### C final correctness review

- Closed an issuance-vs-observation race: a Get issued before a same-selection Plan
  receipt could return the prior completed operation afterward. Every local Plan now
  requires a snapshot request issued **after** its receipt (existing Get polling; no
  new scheduler). That fresh poll confirms success; later ordinary reads keep ready.
- Plan intent is captured synchronously when the UI accepts the command, before the
  deferred effect runs. A superseded effect does not dispatch its old Plan. Dispatcher
  target rejection marks only its matching intent failed/unconfirmed, and stale Plan
  transport errors do not overwrite a newer intent's notice. `current_ticket` is the
  pure API for matching an outstanding local command; completed intents retire it.
- Launch rechecks readiness plus complete preview equality inside its deferred thunk,
  immediately before allocation-target capture and the existing Run request. Project
  changes clear the old model/snapshot during selection reconciliation, not only on
  the next ASIC request. Reconnect generations and physical-client guards remain.
- Missing preview with retained plan operations is stale rather than empty. Remote
  failures with no preview explicitly say selection/order are unpublished. Raw plan
  JSON, identity, selection case, assignment order/duplicates are preserved verbatim;
  only display text is sanitized (including the Launch palette label).
- Extended focused tests cover the pre-receipt same-selection poll race, normal reads
  after ready, operation expiry, missing preview, superseded dispatch/receipt, same-owner
  reconnect round trips, raw/control-containing identity and metadata, exact JSON
  equality, pending-detail Escape without cancellation, shared host plan state and
  scheme preservation while pending.
- Final review verification **PASS**: switch `5.2.0+ox` format check for C's four
  OCaml files; serial `dune build --build-dir /tmp/opencode/sidebar-preview -j 2
  terminal/main.exe @terminal/lint terminal/.terminal_presentation.inline-tests/inline-test-runner.exe`;
  focused inline runner: **34 tests, 2 test modules**. A/B native/full acceptance is
  separate. No index mutations, provider execution or live-state writes by C.
- Protocol limits: Snapshot has no server observation revision or per-attempt Plan
  generation/desired selection; remote same-selection retries cannot be individually
  attributed, and remote pending/failed selection cannot be reconstructed from its
  hashed operation key. Display uses last observed shared facts and labels unknowns.
  A local lost/rejected receipt remains failed/unconfirmed until explicit Plan retry,
  even if the daemon later completed it; an expired completed operation makes a retained
  preview stale until replanned. This is conservative launch blocking, not a retry loop.

### Agent A — live Scheme API (published)

`Appearance.Scheme.t = Carbon | Slate | Crimson | Neon`, deriving `enumerate`,
`equal`, `sexp`; `Scheme.all`, `key : t -> string` (carbon/slate/crimson/neon),
`label : t -> string` (Carbon/Slate/Crimson/Neon), `of_key : string -> t option`.
`Appearance.t` gains `scheme : Scheme.t`, legacy sexp defaults to `Slate`, as does
`Appearance.default`. C: use `{ appearance with scheme }` for palette actions;
explicit full Appearance record literals in main/tests need `scheme = Slate` (or
the intended scheme). A will not edit main concurrently. Renderer work in progress.

A integration update: `planned_run` is now registered in terminal/dune and rendered
from `host.planned_run`, with sanitized/wrapped typed semantic rows and detail/scroll.
Checklist Launch hints now require `Planned_run.launchable`. Theme/title and new
scheme tests pass in terminal inline tests; current whole-terminal blocker is C's
`workspace_host.ml` test "overview utilities and explicit Testing creation" at
line2124: `missing_default_tiles` does not return planned-run yet (B's membership
edit pending). C/B please reconcile that test/membership in your owned files.

A consumed the emerging `Layout.Weighted_columns of (int * resolved) list` API in
host selector minimum-height traversal. Updating host-owned presentation assertions
for zero gutter/vertical defaults, retaining explicit horizontal-strip coverage.
Latest serial run during integration also reports C-owned tests in planned_run.ml
(line297) and timing_workspace.ml (line417), plus B's weighted partition test.
Please reconcile those owned tests; A will rerun once handoffs settle.

### Agent A — implementation/verification handoff

- Owned edits: `terminal/appearance.ml`, `host_view.ml`, `panel.ml`, `terminal/dune`.
  Palette view takes caller semantic attrs already, so its helpers need no edits.
- All paint now comes from `Host_view.Role.palette appearance`: Carbon near-black,
  Slate neutral graphite default, warm Ches-derived Crimson (reference attribution
  in source, brighter muted/error roles for evidence contrast), prior Neon comparison.
  Scheme-specific backgrounds, card/surface, selection, foreground, border, accents
  and semantic states apply across workspace, Timing, FS2 forms and palette. Status
  colors remain distinct even with Restrained intensity. Palette selected markers
  and matched spans retain their selected-row background.
- Host titles are lowercase without decorative prefixes or Instrument uppercasing.
  Exact binding run IDs, filter/user/evidence text, selected list markers and pins
  remain intact. Rounded-frame tests assert exact lowercase label and mixed-case ID.
- Tests added: stable Scheme key/sexp roundtrips and legacy default; all schemes and
  intensities have distinct semantic state attrs; scheme commands carry only local
  Set_appearance, preserve registry/locals/focus, geometry and rendered text. Existing
  host tests adapted to vertical checklist/zero-gutter/sidebar layout; reusable
  Stage_strip tests continue testing horizontal behavior in overview_tiles.
- `planned-run` render/dune integration complete (typed rows, sanitation, wrapping,
  detail, actual scroll geometry); no host data-field additions needed.
- Switch-exact format checks, executable build and `@lint` passed with
  `opam exec --switch=5.2.0+ox -- ...`, serial `-j 2` under
  `/tmp/opencode/sidebar-theme`. Latest `dune runtest ... terminal` passes all A/host,
  appearance/panel/planned-run/workspace tests; sole remaining failure is C-owned
  `timing_workspace.ml:417` old positive-gutter assertion (also inspect line420).
  It should accept adjacency under B's zero gutter while preserving topology.
  Earlier missing-membership/plan/weighted failures above are now resolved.
- Git index untouched; all A edits unstaged. B's final written handoff still pending;
  weighted traversal is already integrated without modifying layout-owned files.

### B — native acceptance completed (2026-10-16)

**PASS**: matching native daemon/client/preset exporter built in
`/tmp/opencode/sidebar-layout` using exact switch `5.2.0+ox`, serial `-j 2`.
New `scripts/test-overview-sidebar.py` runs actual private daemon HTTP + client PTY;
all screenshots are reconstructed actual ANSI cells, retained as `.svg`, `.txt`,
`.cells.json` and `.ansi`, alongside HTTP, keys, binary hashes and provider logs.

Final passing evidence:

| Harness | Result | Private evidence directory |
| --- | --- | --- |
| Overview sidebar / schemes / planned-run | 106 checks | `/tmp/opencode/overview-sidebar-fc8ea86f95ec` |
| Frontend composition | 45 checks | `/tmp/opencode/frontend-composition-b5bc7783c26e` |
| Frontend refinement | 96 checks | `/tmp/opencode/frontend-refinement-7dad2f910d25` |
| Refinement two-real-run capacity | 12 checks | `/tmp/opencode/frontend-refinement-7dad2f910d25-two-runs` |
| Synthetic smoke + HTTP + PTY + cancellation | passed; all five `*-verified.json` files | `/tmp/opencode/synthetic-flow-d0emyda4` |
| FS2 native HTTP + PTY | 45 checks | `/tmp/opencode/fs2-native-y2sbyizx` |
| Terminal interrupt | all five cases, no hangs, exit 0 | `/tmp/opencode/workbench-terminal-interrupt-wbg9s_ny` |

Sidebar captures: `sidebar-overview-120x40.svg`, `sidebar-overview-180x55.svg`,
`sidebar-overview-80x24.svg`; scheme comparisons are `sidebar-overview-{carbon,slate,
crimson,neon}.svg` and `sidebar-timing-{carbon,slate,crimson,neon}.svg`.
`scheme-samples.json` records distinct actual background/accent paint. Each scheme
also has an `[active]` palette capture; a bounded re-execution from a reopened
palette handles a captured target invalidated by asynchronous registry sync.

The new harness verifies one-third sidebar, vertical six stages, full-width seven
right panels in exact order, zero gaps/disjoint frames, lowercase undecorated
titles; four→five→six run-row capacity only expands the sidebar and leaves main
rectangles, semantic registry and providers unchanged. Scheme changes preserve
actual geometry/selections/pins/registry/provider calls in both workspaces, and
Neon survives Overview→Timing→Overview. It verifies empty plan→exact stage-r
Placement plan→ready; full exact identity/JSON and bounded detail scrolling;
historical run changes do not retarget the plan. A **private wrapper** delays and
fails a new CTS Plan: pending/failure never reuse previous success paint/readiness,
Launch is unavailable, retry becomes ready. Only explicit Launch invokes the one
`flow run`, allocates a distinct execution, then cancels that owned producer.

The real daemon clears `preview` as soon as a new Plan starts, so this native
failure fixture exercises old-ready→pending→failed with an absent old preview,
not a retained-preview `Stale` label. No backend state or fabricated snapshot is
injected. C's existing pure retained-preview/supersession/race tests remain intact
and pass in the terminal suite; the native harness also checks retained-detail
warnings if a backend does retain the prior preview.

Meaningful prior-harness adaptations: count selector rows within its actual frame;
verify full long opaque labels in zoom, filtered clipped rows by real row count;
restrict intensity underline oracle to `Appearance: Color` while scheme commands
remain separately tested; keep strict workspace cell restoration except the
legitimately dismissed global status notice row; a no-op same-size resize retains
the ANSI transcript; use 120x28 to exercise Timing Detail scroll now that zero
gutters expose more rows; replace obsolete `Selected:` strip text with exact
selected-stage markers and existing exact Stage ID/advertised-action/detail/launch
checks. Existing execution, cancellation, context, pin and race assertions remain.

Reproduction (all native harnesses ran serially; each shell timeout >=300s):

```sh
opam exec --switch=5.2.0+ox -- dune build --build-dir /tmp/opencode/sidebar-layout -j 2 daemon/main.exe terminal/main.exe terminal/workspaces/export_presets.exe @terminal/lint
opam exec --switch=5.2.0+ox -- dune runtest --force --build-dir /tmp/opencode/sidebar-layout -j 2 terminal/workspaces terminal
B=/tmp/opencode/sidebar-layout/default
python3 scripts/test-overview-sidebar.py --daemon "$B/daemon/main.exe" --client "$B/terminal/main.exe" --preset-export "$B/terminal/workspaces/export_presets.exe" --timeout 600
python3 scripts/test-frontend-composition.py --daemon "$B/daemon/main.exe" --client "$B/terminal/main.exe" --preset-export "$B/terminal/workspaces/export_presets.exe" --timeout 600
python3 scripts/test-frontend-refinement.py --daemon "$B/daemon/main.exe" --client "$B/terminal/main.exe" --preset-export "$B/terminal/workspaces/export_presets.exe" --timeout 600
python3 scripts/test-synthetic-flow.py --pty --daemon "$B/daemon/main.exe" --client "$B/terminal/main.exe" --preset-export "$B/terminal/workspaces/export_presets.exe" --timeout 600
python3 scripts/test-fs2-native.py --daemon "$B/daemon/main.exe" --client "$B/terminal/main.exe" --counter /tmp/opencode/refinement-overview/cyclesim/default/counter.exe
python3 scripts/test-terminal-interrupt.py --daemon "$B/daemon/main.exe" --client "$B/terminal/main.exe"
```

FS2's fixture has an internal 300s wall-clock alarm; other harnesses used 600s
where supported, with 700s shell bounds. No real EDA was run. All state/provider
injection stayed in private test directories; no index operations were performed.

Final A API reconciliation: `Overview_tiles.summary_rows ?freshness` and
`Overview_summary.rows ?freshness` now accept A's bool argument, default `true`.
False suppresses validated-only chrome, **never** stale/unavailable warnings.
Added tests for both semantics. Exact-switch formatting, matching executable
build, terminal lint and forced workspace/terminal inline suites all pass.

### A final integration — B API request

B: please add `?freshness:bool` (default true) to `Overview_summary.rows` and mli.
False should omit only the standalone freshness row; keep compact stale/failed
qualifiers on metrics and full provenance in details (honesty, even with chrome off).
A is integrating `~compact:true ~freshness:(H.policy host tile).freshness` and
removing positional row1 filtering. This avoids dropping stage status after your
compact reordering. Please publish when ready; A edits host_view only.
Also please add the same default-true `?freshness:bool` parameter to
`Overview_tiles.summary_rows`, omitting only its standalone Freshness row while
retaining fact qualifiers/provenance. A can then remove the checklist's positional
freshness logic too. Keep `checklist_rows` compact metadata attachment as written.

### A final compact integration — complete

- Read B's geometry/content handoff and integrated its helper APIs in owned
  `terminal/host_view.ml` only. `Overview_summary.rows ~compact:true` now prioritizes
  typed metric/fact in body row1 and stage observation in row2, including four-row
  framed panels. No positional freshness filtering remains in compact summaries
  or checklist facts: both use B's explicit `~freshness` parameter. B's implemented
  semantics retain non-validated warnings even with freshness chrome off; ordinary
  validated freshness can be hidden. No arbitrary fact/stage rows are dropped.
- Overview's normal vertical checklist uses `Overview_tiles.checklist_rows
  ~compact:true`, showing the six stage observations without aggregate clutter.
  Enter detail retains full selected-stage and aggregate provenance/interaction.
- Shallow planned-run summary has one cell-clipped state line, endpoint line, then
  flow/profile and assignments; explanatory text cannot wrap ahead of the endpoint.
  Enter uses C's complete typed metadata with safe display-cell wrapping; its actual
  wrapped rows remain the scroll bound source. Exact identity/JSON stay inspectable.
  Full host title labels and follow/project badges are lowercase; semantic `PIN`
  and exact mixed-case run identities remain intact.
- Regression coverage: two-row compact metric+stage with freshness on/off, stale
  qualifier retention, six-stage-only normal checklist/full Enter provenance;
  planned-run readiness+endpoint at frame heights4/5, exact detail identity/JSON,
  100-wide-Unicode flow name and long assignments without image overflow.
- **PASS**, serial exact-switch commands in `/tmp/opencode/sidebar-theme`, `-j 2`:
  `ocamlformat --check terminal/host_view.ml terminal/appearance.ml terminal/panel.ml`;
  `dune runtest --build-dir /tmp/opencode/sidebar-theme -j 2 terminal` (full shared
  terminal/workspaces suite); `dune build --build-dir /tmp/opencode/sidebar-theme
  -j 2 terminal/main.exe @lint`; `git diff --check`. No remaining test/build/lint
  integration blockers. Native HTTP/PTY acceptance belongs to B and is separate.
- Controls: `Space c c` → `Color scheme: Carbon/Slate/Crimson/Neon`; A–E preset,
  Vivid/Selective/Restrained, icons and density remain independent Appearance actions.
  `Toggle focused tile freshness` controls routine freshness chrome. `Run selector:
  More visible rows (+1)` / `Fewer visible rows (-1)` retain bounded layout resizing.
  Tab/Shift-Tab focuses tiles; planned-run Enter/Esc enters/leaves full metadata and
  j/k/arrows/brackets scroll. Stage `r` prepares a new advertised Plan; Launch remains
  an explicit existing palette action. Appearance is client-local until restart.
- Global scheme roles apply equally to Overview, Timing and FS2/palette forms;
  Timing investigation topology is unchanged. Index remains untouched.
