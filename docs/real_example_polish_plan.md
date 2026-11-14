# Sidebar/status polish and real ASIC example demo

Activated 2026-10-16 from the owner's review. Continue atop existing unstaged
sidebar/theme work; preserve all user edits and index/history. No staging,
commits, pushes, merges or resets.

## Requested outcome

- Split Overview's remaining left-column space between the vertical checklist and
  planned-run beneath it. Keep Session and Runs above; right column has six domain
  summary panels (synthesis/timing/placement/routing/checks/finalization).
- Neutral `Evidence:` label, semantic color only on `validated`/other value. Prefer
  typed label/value spans generally, not keyword matching arbitrary report strings.
- Run-selector lifecycle tokens completed/failed/running/pending/cancelled/etc. have
  semantic colors while run identity remains readable and exact for actions.
- Session Run uses available width, retaining a meaningful first label/word and
  final hash characters where needed. Full identity remains in inspection; Unicode
  clipping never splits scalars/cells. Avoid the fixed six/six generic truncation.
- Carbon/black becomes default, with black/near-black ground and bright neutral
  headers, while status/metric/selection colors and alternative schemes remain.
- Next demo can run against the actual `hardcaml_asic_example`, using real retained
  evidence where possible. Repair obsolete /tmp provider/result references with
  verified durable paths, not guessed latest runs or synthetic substitutions.

## Safety and resource rules

Main checkout `/home/wayne/devel/jane/silver`; siblings may receive small
necessary integration/config changes. Preserve live processes/state and canonical
results. Reference docs and Ches are read-only. Test evidence is private. Keep
reusable real-demo configuration/provider paths outside volatile `/tmp`.

At most three agents, each2 build jobs, serial commands per agent in separate build
dirs `/tmp/opencode/real-polish-{render,layout,example}`; coordinator no competing
build. Final checks serial at2. No physical implementation run unless retained
evidence cannot satisfy the demo. Inventory first; report exact producer contract
gaps. If a new bounded synthesis is actually necessary, coordinate it explicitly,
keep tool concurrency/CPU affinity within2, and do not launch a full30-minute flow
merely to exercise frontend changes.

## Ownership

### A — label/status/theme rendering

Own `terminal/host_view.ml`, `appearance.ml`, `overview_tiles.ml`, and optional new
pure label helpers; coordinate module additions through terminal/dune. Implement
typed label/value coloring, run-status spans and width-aware Session run labels.
Keep semantic status mapping field-specific; unfamiliar values neutral. Use black
Carbon default/legacy appearance fallback and bright neutral header text while
retaining focused-border/selection and colored statuses. Preserve other schemes
and all layout/selection behavior. Do not edit B layout or C example/config.

### B — sidebar split and native acceptance

Own `terminal/workspaces/overview.ml`, workspace tests and relevant private frontend
acceptance scripts. Split checklist/planned-run below Session/Runs, approximately
half each at normal dimensions, with named source minimum heights/weights. Right
has six full-width stacked summaries. Keep Timing topology unchanged. Preserve
extras, row-height controls, explicit Apply/Reset and small viewport fallback.
Add actual PTY assertions for geometry, token colors/labels, long Session IDs and
black headers after A publishes APIs; keep previous synthetic/Timing/FS2/interrupt
behavior covered. New `scripts/test-real-example-polish.py` or similarly clear name
may cover synthetic UI proof without pretending its data is actual ASIC evidence.

### C — real example readiness and reproducible launch

Inspect sibling `hardcaml_asic_example` and installed provider/source contracts.
Current config points at deleted `/tmp/opencode` FS1 provider/results. Inventory
durable `.dev/asic` installation and `_flow_results` exact observations, executions,
finalizations and hashes. Determine a compatible runnable pair and evidence.
Own small sibling configuration/provider installation fixes and a workbench
`scripts/real-asic-example-demo.py` launcher/registration helper if useful; do not
edit A/B sources. Initial pass must return discovery/inventory and feasible exact
adoption path before starting new EDA. Prefer retained evidence only.

Real demo must open the actual example root using normal public APIs, separate
daemon state/discovery/client preferences, and exact returned observation/finalization
references. No walking newest directories as truth, no manual invented Run_ref or
fabricated report metrics. Validate installed version/capabilities with bounded
commands. Read-only registration/inspection is not a new execution/acceptance.
Canonical evidence must remain unchanged; retain receipts/hashes. Use persistent
example-local or XDG state locations for demo artifacts intended to survive reboot.

## Acceptance

-120x40/large Overview: left Session/Runs/Checklist/Planned-run, checklist+plan split;
  right six domains, no overlapping rectangles, four/six-run row control preserved.
- Actual ANSI attrs show label `Evidence:` neutral and only status green/warning;
  selector status tokens have field-appropriate colors independent of ID/selection.
- Long human labels and opaque/hash IDs show informative head and suffix within
  actual Session width; exact identity remains inspectable and action-safe.
- Black default and bright headers seen in actual terminal, existing Crimson/Slate/
  Neon live switching intact. Timing keeps topology; no producer calls on styling.
- Real-example launch commands work with nonvolatile executable/config paths;
  adopted real evidence opens through daemon/client and scope/availability is honest.
  If an upstream capability is missing, clearly record its exact limit.
- Full format/lint/tests/build serial at2; actual frontend/synthetic/FS2/interrupt
  regressions as appropriate, plus bounded real-example HTTP/PTY adoption proof.

## Status

**Implemented and verified.** Final normal format/lint/tests/build passed serially
at2. Synthetic UI polish196, refinement98/two-run12, composition46, FS2 45 and five
interrupt cases passed. The actual example independently passed normal public
HTTP/PTY adoption of retained signoff evidence:673 cells, setup11.6755ns,
hold0.125029ns, acceptancepass,1020 timing paths plus one reference row, and rich
clock/physical/routing detail. All2235 inventoried canonical files stayed unchanged.

Persistent provider/config and refreshed Workbench binary copies are prepared;
no new EDA ran. See [current launch commands, controls and precise limits](real_asic_example_demo.md).
Chronological intermediate handoffs below are superseded by final evidence there.

### Agent A handoff — 2026-10-17

Implemented atop the existing unstaged work in `terminal/host_view.ml`,
`terminal/overview_tiles.ml`, and `terminal/appearance.ml`. No module/Dune addition.

- Utility rendering now consumes `Overview_tiles.row_spans ~appearance ~width ~indent
  row`: marker, neutral label/separator, and independently styled value. Both vertical
  rows and the optional horizontal stage strip use it. Evidence labels therefore stay
  neutral while validated/warning values retain semantic colors. Active markers and
  selected-label identity remain visible; report/log strings are not scanned or changed.
- `Host_view.run_status_role` recognizes execution lifecycle values only: completed is
  success; failed is failure; running/starting are running; pending/queued/cancelled/
  interrupted/skipped are warning. Unknown values (including verdict `pass`) are neutral.
  `Host_view.run_selector_view appearance ~width ~status_width ~cursor ~active run status`
  renders typed identity and status independently, retaining `>`/`*` and selection
  background on both spans. Classification occurs before status clipping.
- `Overview_tiles.fit_run_label ~width run` takes the actual available display cells.
  A fitting label/full ID stays intact; otherwise it preserves a meaningful label/ID
  prefix, an ellipsis, and up to eight final ID cells. Combining marks stay attached to
  their preceding scalar, suffixes are contiguous, and clipping never slices UTF-8 bytes.
  A supplied label and ID are both shown when room permits. Duplicate long human labels
  with different final hashes remain distinguishable.
- `Overview_tiles.row` has optional `?display_run:Run_ref.t`; its record has matching
  `display_run : Run_ref.t option`. Session's Run row supplies this typed identity, so
  rendering budgets after its label/indent. `value`, inspection details, action refs,
  cursor IDs, pin badges and registry state retain their complete original identity.
  Existing calls need no argument; record updates continue to preserve the new field.
- Carbon is the default and missing-scheme legacy fallback. Its base is RGB 0/0/0;
  card/surface grounds are neutral gray. `Host_view.Role.Heading` is bold RGB 255/255/255
  on the scheme background, used for actual tile titles independently of focus.
  Focused borders, semantic metrics/statuses/accent, live scheme switching and Timing
  topology retain their existing behavior. Validated evidence spans now use success.

Pure regression coverage serializes actual Notty ANSI images and compares cropped
token attributes: Evidence label versus value, selector status versus identity on
selected and unselected rows, clipped known status, unknown lifecycle values, and
actual default Session header white-on-black. Additional label tests cover fitting
full IDs, meaningful heads, suffix collisions, wide/combining Unicode and widths 0–99,
with full exact identity retained in inspection.

Verification passed, serial in exact switch `5.2.0+ox`, build dir
`/tmp/opencode/real-polish-render`, at `-j 2`:

```sh
opam exec --switch=5.2.0+ox -- dune runtest --force --build-dir /tmp/opencode/real-polish-render -j 2 terminal
opam exec --switch=5.2.0+ox -- dune build --build-dir /tmp/opencode/real-polish-render -j 2 terminal/main.exe @terminal/lint
opam exec --switch=5.2.0+ox -- ocamlformat --check terminal/appearance.ml terminal/overview_tiles.ml terminal/host_view.ml
git diff --check -- terminal/host_view.ml terminal/appearance.ml terminal/overview_tiles.ml
```

B can now assert these colors/labels in native PTY acceptance. A did not run producer
flows, alter physical evidence/live state, or mutate Git index/history.

### Agent B handoff — 2026-10-17

Implemented only the owned layout/tests/frontend scripts atop the existing sidebar
work. No Git/index/history changes, physical tools, live-session mutations, provider
source/semantic changes, or canonical evidence writes.

- `terminal/workspaces/overview.ml`: Session and Runs remain fixed above checklist
  and Planned run in the one-third-width sidebar. Named source policy is
  `checklist_height = planned_run_height = 10` and
  `checklist_weight = planned_run_weight = 1`. The remaining height is split within
  one row. Right side is exactly six full-width vertically stacked domains. Existing
  zero gutters, small-viewport fallback, selector runtime minima, membership order,
  extra/duplicate tiles and Timing definition are preserved.
- Workspace tests assert normal and six-row-selector 120x40 minima/split/coverage,
  ordered domain geometry, disjoint frames, bounds and existing sparse/extra cases.
- `scripts/test-frontend-refinement.py` geometry oracle now requires Planned run
  below stages, balanced sidebar heights and six zero-gutter right domains ending
  at the same bottom row. `test-overview-sidebar.py` retains its exact planning,
  delayed failure, launch/cancellation, pin and scheme checks; checks the grown
  selector against the new geometry. `test-frontend-composition.py` now also asserts
  typed neutral Freshness label versus independently colored validated value.
- New `scripts/test-real-example-polish.py` composes the complete sidebar acceptance
  with fresh-default black/bright-header proof, exact neutral `Evidence:` foreground
  versus success-green `validated`, exact completed/failed/running selector-token
  colors and independent identity paint, long Session head/eight-character hash
  suffix plus exact inspection, and live Crimson/Carbon switching. Uses normal
  HTTP registration/selection and actual PTY ANSI/cells/SVG evidence. Requires
  explicit prebuilt `--daemon`, `--client`, `--preset-export`; optional `--evidence`
  must be a new private `/tmp/opencode` path. No implicit build.
- Fixture limitation is explicit in code/docs: this is PRIVATE SYNTHETIC UI proof,
  not real ASIC evidence. The ordinary synthetic provider reports a live run as
  `observing`. Literal `running` token paint is covered by a private static snapshot
  with no execution/report/metrics. Normal read-only observation polling remains
  active for that token; the styling check excludes only those polls. Settled-run
  scheme checks still require byte-identical provider-call logs. No producer/backend
  contract is changed to manufacture this token in real evidence.

Verification passed serially with switch `5.2.0+ox`, build dir
`/tmp/opencode/real-polish-layout`, at most `-j 2`:

```sh
opam exec --switch=5.2.0+ox -- dune runtest --build-dir /tmp/opencode/real-polish-layout -j 2 terminal/workspaces terminal
opam exec --switch=5.2.0+ox -- dune build --build-dir /tmp/opencode/real-polish-layout -j 2 daemon/main.exe terminal/main.exe terminal/workspaces/export_presets.exe @terminal/lint
opam exec --switch=5.2.0+ox -- ocamlformat --check terminal/workspaces/overview.ml terminal/workspaces/test_workspaces.ml
```

Native HTTP/PTY passes using the matching three prebuilt executables above:

- New polish harness (includes full sidebar launch/error/schemes acceptance):
  `/tmp/opencode/real-example-polish-synthetic-4ac342f01e99/result.json`.
- Refinement, including exact Timing path/detail/source, pins, no unsolicited
  producers and two-run capacity: `/tmp/opencode/frontend-refinement-6f556e5c5242`
  and its `-two-runs` sibling.
- Composition, including Apply/Reset extras and pins:
  `/tmp/opencode/frontend-composition-a400470e7bd3`.
- FS2 native HTTP + PTY: `/tmp/opencode/fs2-native-ia0vq_dj`; used existing PDK-free
  counter `/tmp/opencode/refinement-overview/cyclesim/default/counter.exe` explicitly.
- Ctrl-C matrix: `/tmp/opencode/workbench-terminal-interrupt-o__b1jl4`, all five
  normal/filter/palette/unfinished-paste/completed-paste cases passed, exit 0.

Every acceptance command used explicit `--daemon`/`--client` (and exporter where
applicable); there were no implicit harness builds. An early outer-tool timeout
left one owned private daemon, which B explicitly terminated by its exact PID.
Successful harness runs clean up their own daemon/client processes. Full repository
format/lint/tests remain for the coordinator's serial final phase.

### Agent A final quality review — 2026-10-17

Concrete follow-up fixes in the same three owned OCaml files:

- Active utility labels are neutral too. `row_spans` always assigns `Foreground` to
  label/separator text. Additive optional `?selected_bg` on `Overview_tiles.render`,
  `render_row`, and `Stage_strip.render` preserves the selection background across
  marker, label and semantic value; all actual host utility call sites supply it.
  Markers retain selection styling. Removed the horizontal checklist selected-detail
  override that replaced its semantic status role with the selection accent.
- Empty/whitespace-only optional human labels now fall back to the actual ID for
  display, preserving meaningful prefixes. Neither the supplied label nor ID is mutated.
- Strengthened persisted appearance tests: default and missing-scheme legacy parse
  explicitly assert Carbon; every explicitly saved scheme parses unchanged and
  round-trips with all other appearance fields intact. No serialized schema changed.

Additional actual ANSI-image tests cover active Evidence/value spans with uniform
selection background across all four schemes, horizontal status markers/neutral
labels/colored values, and white-on-black actual Carbon headers across every preset
both focused and unfocused. Framed presets separately verify the actual corner still
uses Focus/Border paint. Existing tests retain field-specific lifecycle/unknown-state
coverage, clipped known status paint, distinct hash suffixes, exact inspection refs
and Unicode width bounds. The prior terminal test/build/lint/format commands above
passed again serially at `-j 2` in `/tmp/opencode/real-polish-render`.

Display limitation: extremely narrow panes necessarily shorten the eight-cell suffix
and may omit a wide prefix scalar; bounds and UTF-8 remain valid. Abbreviations are
display-only, not unique action keys; inspection/actions use the unchanged exact refs.
This review did not edit B's acceptance harness or C's demo scripts, rerun native
producer flows, or mutate Git state.

### Agent B final acceptance — 2026-10-17

Completed after A's final quality review above. All evidence in this section is
**synthetic UI/protocol proof only**, not adoption of actual ASIC evidence. C owns
the independent persistent-reader/real-demo work. B did not edit `terminal/main.ml`,
provider/runtime semantics, C's scripts, membership ordering or Timing topology.
The only additional checkout code edit during this final pass was indentation
alignment in B's `overview.ml`; the earlier split/tests/harness changes remain as
described above. No remaining uppercase/Slate-default assumptions required changes
in the executed synthetic-flow/refinement/composition scripts.

The historical polish receipt `real-example-polish-synthetic-4ac342f01e99` contains
exactly **196/196** passed checks, but its client hash predates A's final quality
fixes. It is superseded by the final serial runs below, performed after rebuilding
the final A/B sources and B's formatting. The full sidebar acceptance is invoked
directly by the new polish harness (`sidebar.acceptance`), including its delayed
planner failure, exact metadata, explicit Launch and cancellation; it is not skipped.

| Final suite | Passed | Private evidence root under `/tmp/opencode/` |
| --- | ---: | --- |
| Polish including full sidebar | 196/196 checks | `real-example-polish-synthetic-5126599a8d7c` |
| Refinement | 98/98 checks | `frontend-refinement-947bd5dccd4a` |
| Refinement two-run capacity | 12/12 checks | `frontend-refinement-947bd5dccd4a-two-runs` |
| Composition | 46/46 checks | `frontend-composition-4af1425af411` |
| FS2 native HTTP + PTY | 45/45 checks | `fs2-native-r_50_c9d` |
| Raw Ctrl-C | 5/5 cases, all exit 0, none hung | `workbench-terminal-interrupt-ukr9mg2q` |
| Synthetic provider/HTTP/PTY launch + cancel | 5/5 passed receipts | `synthetic-flow-26v5myxe` |

Total: **397/397 recorded check-array assertions**, plus **5 Ctrl-C cases** and
**5 synthetic-flow receipts** (`smoke-verified`, `preset-export-verified`,
`pty-verified`, `cancellation-verified`, `integration-verified`). These last receipts
are not represented as an invented assertion count. PTY Launch increased that
fixture's recorded provider-launch count exactly from 4 to 5. Cancellation reconciled
the exact cancelled run/stages through read-only Observe without another producer.
Cosmetic controls retain settled-run byte-identical provider logs; the literal
running-token fixture permits only the ordinary read-only observation polling
described in B's earlier handoff, with no additional producer/planner work.

Final capture root: `/tmp/opencode/real-example-polish-synthetic-5126599a8d7c`.
Each capture has `.txt`, `.ansi`, `.cells.json`, and `.svg` companions:

- `startup-120x40`: zero-based, exclusive-bottom rectangles are Session
  `(0,1,40,8)`, Runs `(0,8,40,15)`, checklist `(0,15,40,27)`, Planned run
  `(0,27,40,39)`. Thus the remaining left space splits exactly 12/12 rows. Six
  right domains cover x40–120 continuously from y1 to y39; no gutters/overlap.
- `polish-session-long-id-120x40`: actual Session row is
  `Run: synthetic-readable-pr…89abcdef`; all six stages and ready/endpoint/flow/
  profile/assignments remain visible. `polish-session-exact-detail` retains the
  complete exact identity, with no mutation of action keys.
- `polish-evidence-label-value`: label foreground RGB216/216/220, validated
  RGB151/198/151, both on RGB0/0/0.
- `polish-selector-exact-status-colors`: completed RGB151/198/151, failed
  RGB235/139/151, running RGB151/177/226. Completed remains green both on normal
  RGB0/0/0 and selected RGB48/48/56 backgrounds; identity paint is independent.
- All ten actual default title samples are bold RGB255/255/255 on RGB0/0/0.

Machine-readable final counts, rectangles, actual sampled ANSI attributes, source
fingerprints and binary hashes are retained in
`/tmp/opencode/real-polish-layout/final-acceptance-summary.json`. Final SHA256:

```text
client   b4bdb42feb8f794bcb3b4ac54d92ffdeba09f9510a582f26998afcb3ed15fcdd
daemon   e264f18d17b44b9b0fb170f909b10b6b90f7b408725313a7e1e82fd7f13257e1
exporter 5be05ecf6f698a5e1a2605a9d13e0cd20b0b5fd50f86082a13ba9c516b936780
```

Exact final commands (Bash variables below expand only to explicit prebuilt paths;
all commands ran serially; harnesses never build):

```sh
B=/tmp/opencode/real-polish-layout/default
NATIVE=(--daemon "$B/daemon/main.exe" --client "$B/terminal/main.exe")
PRESETS=(--preset-export "$B/terminal/workspaces/export_presets.exe")
opam exec --switch=5.2.0+ox -- dune build --build-dir /tmp/opencode/real-polish-layout -j 2 daemon/main.exe terminal/main.exe terminal/workspaces/export_presets.exe @terminal/lint
opam exec --switch=5.2.0+ox -- dune runtest --force --build-dir /tmp/opencode/real-polish-layout -j 2 terminal/workspaces terminal
opam exec --switch=5.2.0+ox -- python3 scripts/test-synthetic-flow.py --pty "${NATIVE[@]}" "${PRESETS[@]}" --timeout 600
python3 scripts/test-real-example-polish.py "${NATIVE[@]}" "${PRESETS[@]}"
python3 scripts/test-frontend-refinement.py "${NATIVE[@]}" "${PRESETS[@]}" --timeout 600
python3 scripts/test-frontend-composition.py "${NATIVE[@]}" "${PRESETS[@]}" --timeout 600
opam exec --switch=5.2.0+ox -- python3 scripts/test-fs2-native.py "${NATIVE[@]}" --counter /tmp/opencode/refinement-overview/cyclesim/default/counter.exe
opam exec --switch=5.2.0+ox -- python3 scripts/test-terminal-interrupt.py "${NATIVE[@]}"
opam exec --switch=5.2.0+ox -- ocamlformat --check terminal/workspaces/overview.ml terminal/workspaces/test_workspaces.ml
git diff --check -- terminal/workspaces/overview.ml terminal/workspaces/test_workspaces.ml scripts/test-real-example-polish.py scripts/test-overview-sidebar.py scripts/test-frontend-refinement.py scripts/test-frontend-composition.py docs/real_example_polish_plan.md
```

Build/lint, owned format and read-only diff checks pass. No Git/index mutations,
live-state mutations or physical tools were used. All final harnesses exited
normally and cleaned up their owned processes.
