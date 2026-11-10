# Unified example development session and useful waveform time navigation

2026-11-05. Written before implementation. Owner requests one useful development
session instead of successive PT.8-only demonstration sessions. The construction
phase plan owns Workbench's active queue; ASIC library scope is unchanged.

**Accepted after independent corrections, 2026-11-05:**
[stable session guide and actual closeout](development_session.md). Original plan
follows. Native verification identities remain distinct from the final prepared
user capture; the user daemon was not started automatically.

## User-visible outcome

One stable project/state/discovery/client-preferences location exposes both existing
assertion-backed FIFO suites and verified PT.8 memory workloads through Testing,
normal ASIC Plan/Preparation, Workloads comparison and case-bound Waveforms.
Opening a waveform shows several clock periods when reliably inferable; Fit shows
the whole retained trace. Cursor inspection always uses exact original VCD ticks.
No automatic daemon launch/restart, EDA, root project adoption or evidence rewriting.

The editable development source root is explicit and fixed:
`hardcaml_asic_example/.dev/workbench-development/project`. Initial preparation
copies/inventories the source-complete example; later refresh uses those editable
files, never silently recopies the owner checkout. Root configuration, other live
agents, earlier source modifications and all retained sessions stay preserved.

## Exclusive implementation slices and shared contracts

| Owner | Files | Acceptance |
| --- | --- | --- |
| A — waveform time/graph | `terminal/waveform_time.*`, `waveform_data.*`, `waveform_view.ml`, `waveform_probe.ml`, minimal palette/main hooks, focused tests/PTY | Useful clock-based default, full-trace Fit, bounded event-aware graph projection, exact high-tick cursor and truthful dense/X/Z cells |
| B — combined provider/stable setup | New example composite provider and `scripts/workbench_dev.py`, generation/SDK/environment capture, small PT.8 cancellation correction, example docs/tests | Both child catalogs preserved, exact exec routing, fixed editable project/state paths, idempotent prepare, explicit transactional refresh, pinned libraries/apps, old artifacts/history retained |
| C — independent integrated acceptance | New verification-only Workbench scripts/tests and review notes; no A/B production edits | Real native Testing FIFO normal/mismatch + PT.8 cases, actual useful waveforms/Fit and result handoff, normal source-only Plan, restart/refresh history and preservation checks |
| Coordinator | This plan/queue, API agreement, orchestration, cross-review and guide | Review after initial tests; fix/retest findings and concrete end-user launch instructions |

B publishes `hardcaml_asic_example/docs/workbench_development_handoff.md` early:
manifest shape, CLI options, child provider commands and immutable generation.
Recommended stable commands (from example checkout):
`python3 -B scripts/workbench_dev.py prepare|daemon|client|status`;
`prepare --refresh` is explicit, refuses while state lifetime lock is held, preserves
project edits/state/artifacts/preferences, keeps prior selection on failure. Normal
repeat prepare validates without replacing anything. Capture matching client/daemon
binaries, provider SDK and ASIC environment; never use a mutable `current` pointer.
Source drift must report/reject stale frozen simulation programs with an actionable
refresh command; no build during provider discover/run. ASIC Fresh still builds
current editable source under existing preparation semantics.

Composite FS2 discovery is exact FIFO-then-PT.8 union, rejecting duplicate suites,
invalid/oversize/failed child discovery without silently partial catalogs. Run
parses the bounded request only to select the suite then execs the original child
command with the untouched request/events/artifact-dir arguments. Keep suite IDs
`controlled-fifo` and `pt8-memory-workloads`, original seeds/options/cases, attempt
IDs, event ordering, artifact IDs and process group. Cancellation belongs to FS2:
do not emit provider terminal constructors its validator rejects. Preserve partial
evidence and terminate/reap children under the existing supervisor.

## Waveform contract

Separate inclusive requested time bounds from renderer/sample grid. Support exact
retained span including `[0,Int64.max_value]` without overflow, floats, or allocating
one element per original tick. Resize changes resolution, not requested extent.
Exact `value_at`, duplicate-timestamp semantics, artifact transport/digest/selection
guards and conservative lane-local X/Z/uninitialized markers remain authoritative.

Initial view: approximately eight clock periods only after bounded unambiguous
clock inference; otherwise Fit with a stated basis. Clock inference is a view
heuristic, not declared timing evidence. Add explicit Fit (`f` proposed) and Default
actions; preserve one-original-tick h/l, raw timestamp entry, zoom and pan. Expose
physical duration/timescale and original cursor ticks. No magic PT.8 timestamps.

Compressed rendering must inspect original events per cell: pulses or even toggles
between sample points get transition/dense markers, not a false stable line.
Label cell-resolution compression and hidden ordering honestly; never fabricate
cycle counts, pulse widths, unknown values or dense-cell bus values. Known lanes
remain graphed in their original rows; X/Z excursions between samples cannot vanish.
Keep exact conversion API separate from the bounded projection API.

Suggested projection limits:16 lanes,4096 samples,100000 unique-history events,
16MiB inspected/projected value bytes; aliases charged once. Clock inference<=4096
events. Existing parser limits remain8MiB/4096signals/width4096/500000changes/64MiB.
On exhaustion show unavailable and retain requested range, never silently truncate.

## Acceptance and independent review

1. Composite catalog and delegation parity; unknown/duplicate/invalid selections,
   child discovery failure, exact uint64 FIFO seed and fixed PT.8 seed validation.
2. Actual FIFO directed/seeded normal pass and checker=mismatch semantic failure
   with real assertion report/VCD; PT.8 positives retain verified same-execution
   VCD/JSON closures and counts. Cancel each suite: accepted event prefix, child
   reaping and correct FS2 cancelled/incomplete outcome.
3. Actual production UI launches FIFO and PT.8 in the SAME project/session, opens
   case-specific waves/results and maintains independent pins/history/navigation.
4. PT.8 default spans about80ns at1ps resolution, Fit includes13.07us, exact cursor
   retains known13C6 at2595000ps; FIFO uses its own actual period/timescale. Dense
   cells, sub-sample pulses, X/Z, one-point/high-int64/narrow/resize and budgets have
   meaningful controls. Projection never changes original evidence.
5. Repeat prepare/restart keeps history/source edits/prefs. Explicit refresh keeps
   fixed root and old attempts/artifacts, failed refresh preserves selection, active
   state lock prevents switching. Stale simulation sources cannot claim fresh use.
6. Normal ASIC source-only Plan/staging/build/emission works without EDA. Existing
   Resources/Timing/Workloads/Testing paths retain relevant regressions.
7. Independent cross-review AFTER initial passing suites, fix/retest actual findings,
   retain all failed attempts and exact provenance. No release/authentication claim
   is inferred from source hashes or private generation labels.

## Resource/preservation policy

At most three agents, each2 jobs; coordinator uses at most2 when allocation allows.
Global ceiling20 includes other sessions and nested processes. Every Dune explicit
`-j2` or lower, switch5.2.0+ox; Workbench `_build_pt8_workbench` under
`/tmp/opencode/workbench-pt8-build.lock`; example/ASIC keep
`/tmp/opencode/example-pt7-build.lock` and `/tmp/opencode/asic-pt7-build.lock`.
Use private builds with explicit `--root`. Functional simulation allowed bounded
and sequential; EDA allocation0. No Git add/commit/amend/push/config changes, live
daemon restart, existing provider/config rewrites, Protemu or scheduling expansion.
