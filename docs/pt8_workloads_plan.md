# PT.8 Workbench integration — bounded plan

2026-11-05. Written before implementation. The construction phase plan owns the
Workbench queue; the ASIC phase plan continues to own library scope. User goal:
open an interactive session, inspect retained workload results and explicit A/B
comparisons, then launch and inspect a fresh example workload through Workbench.

**Accepted 2026-11-05:** [launch guide and actual closeout](pt8_workloads.md).
Original bounded plan follows; independent review and corrected real UI execution
are recorded separately from initial passing suites.

## Boundaries

Reuse the accepted ASIC `Workload_result`/`Variant_comparison` public services for
all verification, metrics, controls and deltas. Add a thin public workload-inspect
CLI where missing. Workbench owns transport, async bounded cache, selection and
presentation, not an independent memory oracle or metric eligibility engine.

Fresh execution uses existing FS2 discovery/selection/supervision/history/artifact
protocol. The example owns emission and actual Icarus Flops/stock-macro RTL replay.
Only positive Flops/Exact cases are ordinary catalog choices. Retain full PT.8
relative-file closure outside FS2's disposable work directory and publish an exact
result reference artifact. No synthesis/P&R/STA, scheduler, arbitrary parameter
sweeps, physical winner, Protemu work or new SRAM feasibility work.

Keep existing configured providers, root project configurations and live daemon
unchanged. Deliver an explicit isolated PT.8 example-session setup/launcher with
new provider store/build/state and immutable configured generations. A private
session project can reference the real example as its producer source root. Root
configuration adoption is a separate owner choice after trying the session.

## Shared contract and exclusive slices

| Owner | Exclusive scope | Acceptance |
| --- | --- | --- |
| B backend | New `protocol/asic_workloads.ml`, `protocol/asic.ml`, adapter/process/provider bridge, new backend cache module, `backend/asic_service.ml`, protocol/backend tests | Freeze exact OCaml types first; explicit result and compare queries, provider-fenced async coalescing, bounded JSON/exact numeric values, cache-only Get, failures/freshness and stale pair rejection |
| A frontend | New pure Workloads view/tests; terminal main/host/render/palette/plain RPC/build; stock workspace and builtin registration | Consume B frozen types; explicit imports/captures/axis/compare/refresh, distinct outcomes and reasons, exact ratios, no provider calls during paint, Testing launch and exact result handoff, old layouts preserved |
| C example/provider | Thin ASIC public workload-inspect CLI/capability and tests; new example FS2 provider/run helper/templates; isolated setup/launcher and acceptance | Real foreground Flops/Exact fresh execution via FS2; complete retained closure and exact result reference; capability-compatible captured install; private session config, fresh native HTTP/PTY smoke checks |
| Coordinator | Plan/queue/interface agreement, integration, independent review, final launch instructions | Review after initial passing suites, fix/retest findings, verify real retained comparison and fresh actual workload in isolated session |

B owns all shared Workbench protocol/backend declarations; A owns terminal shared
files and workspace builtin declaration. C owns ASIC CLI edits and all example
changes. No same-file concurrent edits. B publishes `pt8_workloads_handoff.md`
before A compiles. C publishes suite/artifact handoff before frontend completion.

Suggested protocol: explicit `Inspect {result}` and
`Compare {left;right;axis;left_workload;right_workload}` queries, request key covering
both ordered sides/axis, optional expected source digests for captured pairs.
`Load {query;refresh}` routes through existing ASIC operation scheduler. Publish a
bounded cache inventory plus at most one selected full JSON document, with exact
provider/source/comparison digest and validated/cached-unverified/failed status.
ASIC JSON remains authoritative; preserve integer/rational tokens without floats.

Result artifact schema `hardcaml-workbench.pt8-result-reference`, version1:
`result` absolute retained result.json path, `source_digest` public inspection digest.
FS2 attempts/cases, PT.8 simulation attempts and bundle identities remain separate.
Provider suite/case identifiers, supported fixed seed and option limits are frozen
by C's handoff. Never silently accept ignored seed/hardware/workload options.

## Acceptance

1. Public CLI/library inspection parity; readable functional fail/partial distinct
   from invalid evidence; explicit compare axes, wrong bundle/variant/source refs.
2. Backend strict envelope/size/count/numeric admission, capability failures,
   launcher and helper identity fencing, coalescing, refresh failure retaining stale
   data honestly, restart cached-unverified, no raw source arrays in ordinary paint.
3. Pure/production frontend source/pair/axis/request/tile lifetime fences, warm
   reopen/filter/resize causes no subprocess, narrow/wide display, custom layouts.
4. Private daemon/native client sees actual retained positive pair: seven zero
   deltas, failed functional result with performance unavailable, qualified no
   physical winner. Existing Resources/Testing/Timing remain usable.
5. User-driven FS2 form launches a fresh positive case (or explicit both), records
   actual emitted implementation RTL and stock vendor models, durable history and
   exact result handoff. Cancel/reconnect/retry semantics reuse FS2 with focused
   integration checks; inspection never launches execution.
6. Independent cross-review after initial pass, corrected installed capture and
   real native HTTP/PTY acceptance. Document failures, skips and exact provenance.

## Preservation and execution budget

Initial Workbench Git status clean; ASIC/example prior PT.8 and older retained work
remain preserved. No Git add/commit/amend/push/config changes. No live daemon
restart. Three agents maximum, six jobs each plus two reserved; global ceiling20
includes nested builds/simulator workers. EVERY Dune explicit `-j6` or lower,
switch5.2.0+ox. All Workbench builds serialize on
`/tmp/opencode/workbench-pt8-build.lock`; ASIC/example keep required shared locks
`/tmp/opencode/asic-pt7-build.lock` and `/tmp/opencode/example-pt7-build.lock`.
New build `_build_pt8_workbench`, new isolated example store
`.dev/asic-pt8-workbench`. EDA allocation0; functional Icarus sequential/bounded.

Exit: a documented launch pair opens the isolated PT.8 session with retained
inspection/comparison and an explicit fresh Testing workload path. Completion is
bounded UI integration, not root provider adoption or physical qualification.
