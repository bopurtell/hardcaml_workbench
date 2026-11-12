# PT.6 — Resource inspector integration

Authorized 2026-10-28. ASIC `docs/phase_plan.md` remains the PT roadmap; Workbench
`docs/construction_phase_plan.md` tracks this implementation. This document records
contract, ownership and acceptance, not a competing queue.

**Complete in bounded inspector scope; accepted through native HTTP/PTY, 2026-10-28.** Implementation
sections below retain the agreed contract; see [closeout](#implementation-closeout)
and the [operating guide](resource_inspector.md) for the final tested behavior.

## Product scope

Make ASIC-owned requested, selected, elaborated and realized resource facts visible
in Workbench. A resource table and bounded drilldown must show `program`'s contract,
stock macro selection/reason, exact instances, synthesis/final retention, physical
footprint and qualified timing/electrical observations. Pure inventory and realized
evidence remain distinct. No new selector, synthesis/physical parser or reconciliation
algorithm belongs in Workbench. No EDA is needed to inspect retained evidence.

Create a Resources workspace and compact Overview entry tile using stock layout
definitions. Existing saved layouts, pins and context selections must not reset;
provide explicit create/add/navigation actions. Resource selection/filtering/details
are read-only; configuration controls reuse existing project flow/profile/assignment
staging, never launch merely by changing a view or manufacture unsupported memory knobs.

Bounded comparison pins two explicit evidence sources and compares resource IDs,
request/policy/selection and compatible scalar measurements. Numeric deltas require
matching stage, unit, definition and scope; unsupported comparisons remain explained.
No automatic variant sweep, "best" result or second execution scheduler.

## Provider-owned bridge is required

Existing `resources-inspect RUN_DIR` accepts coarse runs/retained snapshots, whereas
Workbench selects named executions and finalizations. Pre-run inventory comes from
an exact emitted bundle. Never pass guessed parent directories or fabricate an
observation stream for historical SRAM evidence.

Add a generic ASIC-owned, read-only resource inspection service with typed targets:

- verified emitted **bundle**: validate manifest and all member bytes, inventory only;
- **coarse run** / supported retained snapshot: existing Resource_evidence inspection;
- **named execution**: validate existing execution/checkpoint/bundle associations;
  show selected inventory where recoverable, realization unavailable unless an existing
  authoritative resource-evidence source establishes it;
- **finalization**: preserve named execution, finalization operation and evidence
  context identities, source-replaying available resource evidence using that context.

Checkpoint-only realization support is not fabricated from metrics. An unsupported
target/source association is explicitly unavailable. New named macro execution remains
outside this feature. Existing positional `resources-inspect` schema1/2 output and
exit behavior remain compatible. Add a separately advertised resource-inspection
capability for bounded index/detail/artifact queries; CLI4 alone is insufficient.

ASIC normalizes snapshot and legacy resource contracts/policy/selection into one
display contract without losing original contract structure. Index returns concise
rows plus section availability/counts. Detail pages carry provider-owned fields/tables,
units/scope/provenance and stable IDs. Workbench validates/projects this envelope into
typed protocol records rather than interpreting tool reports or legacy S-expressions.

### Bounded query and source contract

- Index ≤2 MiB and ≤4096 rows with explicit truncation/availability, not silent loss.
- Detail ≤64 KiB normalized payload per page with bounded offsets/limits and stable
  resource/section IDs. Actual timing payloads contain 186 paths/372 points and must
  not be embedded repeatedly into ordinary UI snapshots.
- Source artifacts use opaque provider-authorized handles, exact source/digest binding
  and bounded pages. No client-supplied arbitrary artifact path. Recorded external
  model refs remain not-retained; 76 sources need pagination rather than a 32-item cap.
- Every detail/artifact request supplies expected index/source digest; altered evidence
  or source switching rejects stale requests. Existing source-aware replay remains
  authoritative. Failed resource verdicts are valid inspectable evidence, not transport
  failures; unsupported/corrupt input is distinct from successful empty inventory.
- Provider configuration/generation and relevant companion identity bind caches; hashing
  only the unchanged dispatcher is insufficient. Bound process output and timeouts.
- Cache-only Get/render/filter/reopen; explicit load/refresh queries, coalesced bounded
  reads, stale-response fencing. Restored cache is Cached_unverified, never fresh success.

## Workbench evidence target and lineage

Resource inspection target is tagged and distinct from mandatory `Run_ref`:
workflow-owned bundle, registered execution/finalization, or explicitly imported
retained coarse evidence. Store selected exact source/identity, not project-latest
preparation. An emitted standalone bundle is useful before any physical allocation.

An **Import retained resource evidence** action creates a resource source record,
not a physical run or synthetic observation. It preserves original run/build/manifest,
capture-root/evidence digest and provider provenance. Use the new augmented SRAM
capture for actual-run acceptance, with original physical-p4 separately selectable.
All unavailable states carry reasons; rendering must distinguish source freshness,
execution status, resource verdict and optional measurement availability.

Normal run-follow/pin uses existing workspace semantics and exact workflow/bundle
association; explicit imported/bundle source selection must remain stable when Main
changes. Historical unlinked runs cannot borrow newer bundle inventory. Simulation
roles, fallback reason, unsupported contracts and optimized flop attribution remain
honest. Per-resource timing is sampled and electrical compliance not_assessed.

## Exclusive implementation assignments

| Owner | Files / responsibility | Dependencies and acceptance |
| --- | --- | --- |
| A — provider + backend (6 jobs) | ASIC new resource inspection service/CLI/capability and focused tests; WB new protocol resource types, `protocol/asic.ml`, backend resource service/cache/import, ASIC adapter/process seams and backend tests | Publish exact handoff early; typed source/index/detail/artifact/compare API; reuse reconciliation, exact target validation, bounded cache and failure semantics; no new EDA |
| B — UI (6 jobs) | WB terminal resources view, main/host/palette/plain_rpc integration, stock layouts and Resources builtin registration (`protocol/workspace_config.ml`), terminal tests | Consume frozen A contract; table/detail/source navigation, explicit source import/refresh, pre-run/run binding, compatible two-source compare and declared controls; preserve layouts/fences |
| C — acceptance (6 jobs) | New WB native resource inspector scripts/fixtures and retained-run script; example isolated provider capture/acceptance receipts if needed | Public HTTP+PTY and actual SRAM capture display, malformed/stale/failed evidence, cache-only reopen and artifact bytes, no fabricated run or EDA |
| Coordinator | Plan/status/public operating docs, contract arbitration, review and final binary build | Coordinate cross-repo schema and capability adoption; record actual evidence/limits |

A publishes `docs/resource_inspector_handoff.md` before B/C dependent integration,
including exact provider command/envelope, typed operations/records, source identities,
pagination budgets and binding rules. A may use a new ASIC test subdirectory; ASIC
shared test registration belongs to A. B owns terminal fixture record defaults;
A owns other protocol/backend defaults. C may prepare fixture research while waiting.

## Acceptance

1. Actual retained augmented SRAM: `program`,256×16/exact stock macro, exact
   `hc_resource_7_program`, distinct synthesis/final status, footprint28127.104 µm²,
   nonspacer4793.6448 µm², gross core902417.2416 µm²; sampled186 paths/372 points.
   Display slow setup11.246561 ns, slew0.067838 ns/load0.004815 pF and fast hold
   0.223533 ns, absent input Cap and separate analysis/model temperature.
2. Original physical-p4 retains unavailable timing. Separate synthesis capture has
   175 std cells+macro and30309.8272 µm² synthesis estimate; no cross-run borrowing.
3. Pre-run exact bundle, empty FIFO, explicit flops/fallback, simulation-role facts,
   failed/cancelled/no bundle, named realization unavailable and finalization provenance.
4. Failed required macro verdict displays failure with usable details; invalid source
   and unsupported capability are separate. No provider launch on rendering/filtering.
5. Slow reply after target/digest/session/context changes cannot populate another view.
   Warm reopen is cache-only; restart labels cached facts unverified; refresh failures
   remain visible rather than silently retaining fresh-looking success.
6. Artifact pages match actual authorized source bytes/hash/span; unknown IDs/path
   escapes/stale digests and over-budget data reject. All source entries are reachable.
7. Compare exact A/B sources without retargeting; incompatible scopes have no numeric
   delta. Staging declared controls remains explicit and nonpublishing until launch.
8. Native HTTP/PTY tests use private roots/state/ports/config, synthetic provider for
   failures/races and a captured real ASIC provider for historical SRAM inspection.
   No changes to user daemon, layout or pinned generation selections during tests.

## Operations and deployment

No Git add/commit/amend/push/config or authorship changes. Preserve dirty ASIC PT.5b
source and example evidence. At most3 agents ×6 jobs,2 reserved; every Dune explicit
`-j6`. Serialize WB with `/tmp/opencode/workbench-pt6-build.lock` and ASIC with
`/tmp/opencode/asic-pt6-build.lock`; private capture builds count within C's6.
No synthesis/P&R/signoff, Protemu modifications or live-daemon actions.

Private acceptance provider store may use `.dev/asic-pt6`; do not silently upgrade
the application's approved PT.5 provider. After final bridge compatibility tests,
ask before updating that configured path for user testing. Build matching default
WB daemon/client/exporter; report explicit restart/import/navigation commands.

## Implementation closeout

The generic ASIC bridge and Workbench Resources inspector are implemented, with
exact source kinds and bounded provider-owned projections. Existing raw schema1/2
`resources-inspect` remains compatible. No UI selector/reconciliation implementation
or fake SRAM observation was added. Named-stage realization remains unavailable
where existing provider evidence cannot establish it.

### Final implementation seams

- ASIC `Resource_inspection_service.inspect/run`, public `resource-inspect`,
  capability `resource_inspection1`, typed source/index/detail/catalog/byte envelope.
- WB `Asic_resources`, source/cache service, resource-specific process status handling
  and exact workflow/run/finalization resolution. Imports persist source descriptors;
  rendering/Get/warm reopening remain cache-only. Cached facts restore unverified.
- Resources view/stock workspace/Overview entry, precise source selection, paged
  qualified detail/source text, explicit refresh and A/B captures. Saved layouts and
  older custom definitions retain their own identity; no implicit reset or replacement.
- Inventory availability is typed Available/Unavailable/Unknown. Measurements are
  Observed/Derived/Estimate/Unknown; compatible finite Observed/Derived quantities
  alone support measured deltas. Older fields default unknown, not invented measured
  facts. Native failed resource evidence stays inspectable with its failed verdict.

Exact signatures/limits/field compatibility: [final r3 handoff](resource_inspector_handoff.md).

### Review findings and corrections

Independent review found and corrected:

1. Reserving the new `resources` builtin key invalidated older custom definitions.
   Existing version1 Custom resources snapshots now load/roundtrip unchanged and
   coexist with the new builtin; pins, geometry, zoom and definitions are preserved.
2. Reused read operation keys could admit an older failed poll before a new receipt,
   leaving an obsolete error after success. Admission/request/receipt floors now fence
   old responses, while genuinely lost acknowledgements remain explicitly uncertain.
3. Comparison validation needed captured provider **and normalized index** identity,
   not just underlying source digest. Fixed captures cannot acquire another projection's
   validation status or silently retarget.
4. Empty rows without typed inventory availability looked like a verified empty
   design. New typed availability preserves missing/history qualifications.
5. Truncation was not visible, and missing estimates were described as supplied values.
   All relevant views disclose truncation and actual unavailable reasons; provider-owned
   classification now guards measured deltas, including estimates at final_physical.
6. Accepted resource process exits lost their status before ingestion. Exit0 with
   pass/not_evaluated and exit1 with fail are accepted after validation; disagreements
   reject consistently across indexes and pages without replacing admitted evidence.
7. A cache-corruption diagnostic survived a successful repair. It now clears only
   after a successful atomic replacement; failed writes/reads retain the error.

Independent UI peer recheck passed **66 adversarial assertions**, including actual
persisted custom-layout loading, lost/late retries and captured-projection changes.
Its receipt is `/tmp/opencode/pt6-independent-resource-review/peer-recheck-results.json`.
Independent source/ingestion review ran **43 driver assertions / 19 cache cases**;
its two findings above were fixed and exercised by final native acceptance.
Original findings/receipts remain historical under `/tmp/opencode`.

### Final verification and retained evidence

Authoritative example receipt:
`acceptance/resource-inspector/closeout-final-02.json`.
Detailed evidence: [acceptance record](resource_inspector_acceptance.md).

| Route | Final result |
| --- | --- |
| Installed public bridge | 533 checks passed |
| Synthetic resource HTTP/PTY | 70 checks passed |
| Actual retained SRAM HTTP/PTY | 52 checks passed |
| Unified fresh-prefix regression | 99/99 |
| Saved custom Resources/builtin coexistence | 17/17 |
| Forced full WB build/tests/lint and matching targets | Exit0,39.304s |
| Full default ASIC forced runtest | Exit0,564.606s; no resume needed |

These are per-route assertion counts, not an additive independent test total. The
default ASIC suite omits some opt-in retained fixtures; the actual public bridge and
native SRAM acceptance above exercise their own exact evidence independently.

Actual retained UI proof includes program's exact contract/stock macro/instance,
matched synthesis/final observations,28127.104µm² footprint,4793.6448µm² nonspacer
sum,902417.2416µm² gross core,186 sampled timing paths/372 electrical points, paging
through76 authorized sources and exact source bytes. Original physical-p4 timing
remains unavailable; verified empty FIFO is separate from unavailable inventory.
Flops/fallback are separate exact bundle sources, not invented SRAM executions.

All276 original historical files,333 augmented files, earlier capture/receipt trees,
user app config and pre-existing provider pointers were unchanged **during tests**.
The explicit provider configuration change below happened afterward with approval;
acceptance receipts were not rewritten to hide that chronology. No EDA, user-daemon
actions, Protemu edits or Git publication operations occurred. Agent allocation was
at most18 jobs, with explicit six-job limits and per-checkout serialization.

### Capture, binaries and approved app configuration

| Identity | Final tested value |
| --- | --- |
| ASIC generation | `97b85a9e25e24615b758b97b21ca9697` |
| ASIC captured source SHA-256 | `304dee9cb923e57a1e2aaeadb39cafcacff91a8c35e0b32e8a6185d6a90f9b4a` |
| Resource bridge companion SHA-256 | `7a61c319d9d3073f3e9217cb57ef89e7002b80b19c9d18d9ab1727f74d5ef080` |
| WB daemon SHA-256 | `d8f08e4de5c19aaa764566d4c9894b2bb7c94b534151cff7b16a0cdd940e4a4c` |
| WB client SHA-256 | `ae9373490327e0ea0555798c7f1f7884e27a4e9abe5470d5b0530e1a5b9edae2` |

All19 installed executable hashes are retained; dispatcher identity alone does not
identify native companion code. Development capture is not a clean-source or historical
producer authentication stamp. Coordinator-only documentation follows final source freeze.

The owner approved updating only the example companion's `provider_executable` to
`.dev/asic-pt6/generations/97b85a9e25e24615b758b97b21ca9697/bin/hardcaml-asic-flow`.
Coordinator applied that exact tracked-file change and verified the configured
bridge read-only: available inventory, pass, one program resource, matched/matched,
76 sources,186 timing and372 electrical section entries. Project executable/tool
paths/results/timeout and all `current` pointers remain unchanged. The PT.6 current
pointer intentionally still names the earlier capture; use the final immutable path.

Matching default app pair is already built. The user's running daemon/client were
not restarted. [Restart/import controls](resource_inspector.md#start-the-tested-app-pair)
are the user visual-acceptance handoff. Resource inspection remains read-only;
separate fresh-launch actions can start real implementation as before.

### Supported scope

No new named SRAM physical execution/checkpoint support, automatic policy selection,
variant sweeps, independent PT.4-to-bundle linkage, or missing-source backfill.
Physical and sampled timing qualifications remain PT.5b's: stock/R0 supported checker,
gross rectangle sums rather than usable-site/routed occupancy, nonexhaustive paths,
electrical compliance not_assessed, and no timed-model/IR-EM/resource-power/flop-ownership
claim. Comparison makes only qualified compatible scalar deltas. Record/detail/cache
budgets and UTF-8 byte-page display boundaries remain explicit in the operating guide.
