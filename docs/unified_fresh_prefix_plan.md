# Unified fresh-prefix execution

Authorized and implemented 2026-10-27. Status lives in `docs/construction_phase_plan.md`.
This is the implementation contract and evidence record, not a second queue.

## User contract

Elaboration is the first peer step in the user-facing fresh workflow:

```text
Elaboration (source build + bundle emission)
  → Synthesis → Floorplan → Placement → CTS → Routing → Timing → Signoff
```

Selecting any fresh endpoint executes all its predecessors, including Elaboration.
Every distinct fresh submission builds/emits again (incremental build and identical
bundle publication reuse are permitted). No independent preparation result is
silently borrowed. Synthesis consumes the exact emitted bundle and methodology
plan from its own workflow. Failure or cancellation blocks downstream work.
Explicit checkpoint/resume semantics remain distinct. Elaboration is not added
to the ASIC provider's physical enum; backend implementation differences do not
change its user-facing dependency semantics.

Existing standalone Elaboration fix must remain: an ASIC preview from a separately
pinned executable is not an implicit expected identity for a source-built emitter.
Fresh staging captures inputs/configuration scope, not generated-source bytes or
an exact rendered plan. An explicitly supplied expected plan identity remains a
strict assertion; physical launch always verifies the newly emitted exact identity.

## Architecture and shared contract

The daemon owns chaining, not the terminal. Extend existing ASIC launch ownership
and preparation job supervision, rather than introducing a competing scheduler.

- A workflow identity exists before physical allocation, including failed build or
  emission. Persist reservation before scheduling. Submission-key replay observes
  the same workflow, and conflicting reuse rejects.
- Captured inputs include selection and source/preparation/provider/environment
  scope. New source execution cannot implicitly reuse a pinned executable preview.
- Retain preparation attempt/status/diagnostics/timestamps and exact bundle identity,
  output directory, plan identity and immutable plan bytes/file digest. Session-only
  artifact/job handles are not durable execution dependencies.
- Physical handoff uses existing provider `stages BUNDLE --methodology-plan FILE
  --expected-plan-identity ID --workspace NEW --checkpoint-store ...` with configured
  tool paths. Never call pinned project `flow run` after preparing: it rerenders.
- Preserve early provider allocation, observation, cleanup and terminal-reconciliation
  machinery. Bind workflow → preparation → physical submission/reference/run explicitly.
- Workflow cancellation latches before async handoff, cancels owned preparation or
  physical execution, and fences every downstream admission boundary. A cancelled
  producer cannot later launch synthesis. No unowned PID cancellation.
- Restart retains facts but never replays producers automatically. Interrupted or
  unresolved ownership remains explicit. Historic runs without linkage stay unavailable.
- Serialize source build-through-emission per source root (or isolate immutable
  executable products), including standalone preparation versus chained preparation.
- Keep Elaboration status associated with the selected workflow/run, never project-wide
  latest preparation. Before provider allocation show workflow Elaboration progress;
  after allocation maintain the same linkage and guarded launch-and-view behavior.
- All fresh entry routes (manual planned launch, checklist R, palette selected/named
  launch) use the daemon chain. No old Run bypass may silently use pinned flow run.

Concrete typed additions and signatures are frozen by backend owner A in
`docs/unified_fresh_prefix_handoff.md` before dependent UI/test integration. Prefer
existing ASIC RPC and additive/defaulted fields with historical S-expression
compatibility. Preserve bounded records; retain full plan once instead of duplicating
16-MiB receipts into small preview fields. Missing preparation/provider capability
must be an explicit failure, not a legacy bypass.

## Agent ownership and dependencies

| Owner | Files and responsibilities | Dependencies / acceptance |
| --- | --- | --- |
| A, general agent, 6 jobs | `protocol/asic.ml`, preparation protocol if needed; `backend/asic_service.*`, `preparation_service.*`, `preparation_receipt.*`, `service.*`, exact prepared provider adapter; backend tests and related build declarations | Publish handoff first; implement durable workflow, build/emit serialization, direct exact-bundle launch, cancellation/restart/idempotency; backend fixtures prove no pinned flow-run call and no downstream work after failure |
| B, general agent, 6 jobs | `terminal/main.ml`, stage launch/planned-run/presentation/host/plain RPC and terminal tests | Read A handoff; every fresh UI path uses unified chain; show linked Elaboration and physical steps; retain selection/context fences, standalone fix and explicit user launch semantics |
| C, general agent, 6 jobs | New `scripts/test-unified-fresh-prefix.py` plus narrowly necessary existing frontend fixtures; isolated acceptance receipts and evidence guide | Read A/B handoff; HTTP/PTY exact handoff, failures/cancellation, fresh repeat/replay, restart and historical linkage tests; no real EDA |
| Coordinator | This plan/status docs, contracts/review, integration and binary deployment instructions | Resolve ownership collisions, independent review after implementation and focused then broader verification |

B/C may research and design fixtures while A establishes the concrete API. Do not
edit another owner's files without an explicit handoff. Protocol record additions
may require fixture defaults outside A's directory; coordinate them rather than
running overlapping source edits. Shared generated/build declarations have one owner.

## Acceptance gates

1. Fresh Synthesis and CTS each run their own source build+emit first; provider
   receives exactly the receipt's bundle/plan/identity and complete physical prefix.
   No pinned project `flow run` invocation or second render occurs.
2. Standalone Elaboration stops after emission; fresh repeated launches rerun it
   even with identical/reused bundle bytes. Same submission-key retry never reruns.
3. Build/emission/receipt/persistence failures block physical admission. Explicit
   expected-identity mismatch fails. Source/profile/provider scope cannot be swapped
   under a captured intent. Missing preparation config fails explicitly.
4. Cancel during build, emit, between stages, queued launch and allocated physical
   execution; verify actual owned cleanup and no later producer start.
5. Durable restart/replay does not relaunch. Successful and failed workflows retain
   own lineage; a later preparation cannot relabel an older selected run.
6. Real terminal/HTTP paths cover r/manual launch, R, named/selected palette launch,
   preallocation progress, Elaboration and physical status, cancellation, and guarded
   focus changes. Existing unrelated layouts and pinned provider selections survive.
7. Targeted backend/frontend tests first, broader Workbench tests/build next. Use
   synthetic physical providers to prove orchestration without running EDA. A bounded
   real example source-build/emission check may run isolated if useful; physical
   result claims require real EDA and are not part of this feature's acceptance.

## Operational constraints

- No git add/commit/amend/push/config or authorship/publication operations.
- Preserve existing standalone-fix changes in `terminal/main.ml` and
  `scripts/test-preparation-frontend.py`, plus untracked example PT.5 acceptance.
- Three agents at six jobs maximum each, two reserved; global maximum 20 including
  nested builds. All Workbench Dune uses explicit `-j6` and shared lock
  `/tmp/opencode/workbench-fresh-prefix-build.lock`; serialize within checkout.
- Physical EDA allocation is zero. Isolated fixture daemons only; do not stop/restart
  the user's live daemon, change selections or silently deploy demo-pinned binaries.
- Build the matching default daemon/client pair for explicit user restart after
  acceptance. Report actual tested guarantees and unresolved limitations.

## Delivery and user verification

Implemented the daemon-owned chain with durable workflow reservation, exact
preparation/plan/bundle/run linkage, input-scope fences, source transactions,
submission replay and cancellation. All fresh terminal paths now stage input intents
and launch that exact intent. Elaboration-only uses the same core and stops after
emission. Physical execution uses provider `stages` directly, never a second render
through pinned project `flow run`. Generated plan identities become known only
after source emission; explicit caller expectations remain strict.

The selected run's Elaboration evidence comes from its own workflow. During source
work, the planned-run tile shows the active workflow before a physical run exists;
an older selected run is not temporarily relabeled. Historic runs with no linkage
stay unavailable. A build cache hit or identical published bundle is legitimate
reuse within a newly executed Elaboration step, not skipping the source operation.

### Controls

- Select a checklist endpoint and press **r** to stage inputs without execution.
  Launch the staged fresh workflow through the planned-run/palette action.
- **R** stages and launches a new fresh prefix. Synthesis includes Elaboration;
  CTS includes Elaboration, Synthesis, Floorplan, Placement and CTS.
- Elaboration R runs only source build/emission. Named/selected palette launches
  use the same daemon chain. Cancellation targets the exact workflow before or
  after physical allocation.
- A new fresh submission creates a new source build/emission attempt. A retry of
  the same submission key observes the original attempt, including after restart.
- A staged intent superseded by another client is stale even for identical visible
  selections. Restage locally; do not reuse the old launch action.

### Review and evidence

Final [acceptance record](unified_fresh_prefix_acceptance.md): **223** scripted
assertions (99 unified HTTP/PTY, 83 checklist, 37 preparation, 4 native capability
probe cleanup), matching binaries and forced full `@runtest @all @lint` passed.
The comprehensive receipt is
`/tmp/opencode/workbench-fresh-final-81cac6ffa064/receipt.json`.

Independent review identified and corrected captured-intent substitution and
uncancelled capability-probe issues; migrated native tests exposed and verified
same-client recovery after rejection. Follow-up independently passed **38**
adversarial local receipt/recovery checks, including lost/late responses and
uncertain-launch fencing. Backend review additionally passed **24** checks for
handoff scope drift, frozen-plan mutation, concurrent same-key admission and
older-workflow bundle ownership after newer preparation. No blocker remained in
these reviewed paths. Source is covered by repeatable backend/terminal/script tests;
temporary repro receipts are linked in the handoff/acceptance records.

All physical execution in these tests was synthetic. No synthesis/P&R/signoff or
user-daemon launch/cancellation was performed. History is bounded (256 workflows,
4-MiB registry); full plans are bounded at 16 MiB. Restart retains facts and marks
unfinished orchestration Interrupted rather than replaying work. Session job/log
handles are cleared; crash windows around external allocation remain explicitly
unresolved rather than claiming exactly-once process execution.

### Real example compatibility and authorized provider update

The real example still pinned provider `f64dd69b9a1845018b6e677a296f7031`, whose
strict plan parser rejects the PT.5 bundle's new `resource_snapshot` field. Both
old and new providers advertise CLI4/package 0.1.0, so that metadata alone does
not establish content-schema compatibility. Installed-library probes confirmed:

| Plan | Old pinned provider libraries | PT.5 provider libraries |
| --- | --- | --- |
| Current PT.5 source emitter | Rejected: `object fields do not match versioned schema` | Accepted |
| Old pinned project emitter | Accepted | Accepted |

The PT.5 `Methodology_execution_service.check` also accepted the real emitted
bundle, exact plan/configuration and all member hashes (`actions=1`), without
tool probes, allocation or execution. Evidence:
`/tmp/opencode/workbench-provider-compatibility-a2fc2f64556e/result.json`.

After explicit owner approval, only `provider_executable` in the example's local
`hardcaml-workbench-asic.sexp` was updated to:

```text
/home/wayne/devel/jane/hardcaml_asic_example/.dev/asic-pt5/generations/dd1ec9002cdc40f2936488cedd9eb0fe/bin/hardcaml-asic-flow
```

The project executable remains available for catalog/legacy preview, while new
fresh workflows build the configured source target. Tool paths, results root,
timeout, old provider generation directories and all `current` pointers remain
unchanged. The companion is tracked; its provider-path change remains unstaged.
The new configured provider's `--version --json` succeeds and advertises
`namedflow1`, `preparation1` and `resource_evidence1`.

### Restart the app explicitly

Both daemon and client changed. Exit the old client and stop the old daemon when
no jobs are active; this implementation has not stopped them for the user. Reuse
the previous state directory only after its owner exits. The earlier session used
`/tmp/opencode/workbench-pt5-Zcj6Y5`; substitute the intended directory if different.

Server:

```sh
cd /home/wayne/devel/jane/hardcaml_asic_example
source .dev/asic-pt5/current/activate.sh
export OCAMLPATH="$OCAMLPATH:$PWD/.dev/workbench-provider-sdk/lib"
export DUNEJOBS=6 OPAMJOBS=6 OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 MKL_NUM_THREADS=1
/home/wayne/devel/jane/silver/scripts/with-switch.sh \
  /home/wayne/devel/jane/silver/_build/default/daemon/main.exe \
  --port 41735 --state-dir /tmp/opencode/workbench-pt5-Zcj6Y5
```

Client:

```sh
cd /home/wayne/devel/jane/silver
./scripts/with-switch.sh _build/default/terminal/main.exe \
  --connect http://127.0.0.1:41735 \
  --project-root /home/wayne/devel/jane/hardcaml_asic_example \
  --environment inherited
```

Stage a **new** intent after reconnecting; old session staging does not carry over.
Fresh Synthesis now starts real physical execution after Elaboration succeeds.
Provider configuration changes scope the ASIC cache separately; old result files
remain intact and may need explicit re-registration for inspection in the new scope.
