# PT8 frontend independent review — B

**Independent correction rerun: F1–F4 verified corrected.** The explicit corrected
B harness passes **78 checks, zero contract failures**, including all45 original
assertions. The original probe is preserved unchanged. See the correction rerun
section below for fixture differences, actual dispositions and fixed source hashes.

2026-11-05. Reviewed after A's initial pass against `pt8_workloads_ui.md` and actual
Workloads view, native transport, Testing artifact selector, navigation restoration
and workspace integration. **A production and test files were not edited.**

Independent executable: `backend/test/frontend_review/review_frontend.ml`, with its
own Dune stanza. It links production presentation/backend modules, constructs
adversarial state transitions, and obtains an actual FS2 public artifact identity
from `Simulation_service.capture_artifact`. No provider, daemon, simulator or EDA
is launched. Temporary artifact capture is under `/tmp/opencode/`.

## Initial findings (historical; corrected dispositions below)

### F1 — High: actual FS2 artifact IDs cannot enable fresh-result inspection

`backend/simulation_service.ml:437–441` namespaces the declaration ID as
`attempt.id ^ "-" ^ declaration.id`. The independently captured reference therefore
has public ID `sim-review-flops256-result-reference` and is Available with verified
size/hash. `terminal/testing_workspace.ml:84–100` admits only bare IDs
`flops256-result-reference` / `exact256-result-reference`, so neither automatic
selection nor explicit selection can expose it. The command in
`terminal/main.ml:4596–4603` depends on that selector: an ordinary fresh FS2 run has
no result-inspection action.

A's initial test uses a hand-written *unprefixed* public Artifact.t, which bypasses
the production namespacing boundary. The independent test calls the real backend
capture function and then the real Testing selector; both discovery assertions fail.

Suggested fix: match the exact current-attempt public namespace plus the declared
result-reference suffix (or retain a typed provider ID in an appropriate existing
boundary), keeping case, attempt, availability, media type and restored-identity
fences. Do not accept arbitrary suffix matches detached from the selected attempt.

### F2 — Medium: list reopening drops an exact reference's captured digest

`Workloads_view.input Open` (`terminal/workloads_view.ml:466–469`) reconstructs
`Inspect {result; expected_digest=None}` for every Enter. A result opened from FS2
with expected digest A therefore loses its reference fence after Esc → Enter.
There can already be a distinct cached unpinned query at that same path with newer
digest C; production reconcile accepts and displays C after this transition without
an explicit recapture/import action.

The independent test starts with a pinned result, backs out and opens it, verifies
the emitted query, then supplies the unpinned cache document. Two assertions fail:
the digest is absent, and C replaces pinned A. The distinct backend query keys are
working as designed; the frontend selected the weaker key.

Suggested fix: reopen the selected descriptor's full Inspect query or preserve the
currently selected exact query when reopening its path. Multiple cached queries for
one path need an explicit deterministic selection rule; do not discard their
expected_digest while deduplicating the result list.

### F3 — Medium: list selection and capture source can disagree

Esc/Move changes `selected`/generation but keeps the previous inspection query and
document. Capture (`terminal/workloads_view.ml:355–365`) uses that old query rather
than the highlighted result. The capture command remains available in Results mode.
With A loaded and B highlighted, a newly opened (non-stale) capture form binds
`result=A` to the bundle entered for B. The form token does not reject it: it was
captured *after* moving to B and is current.

Independent reproduction drives Back → Move to B → Capture with the current token.
It observes an A-result/B-bundle capture. The public comparator will normally reject
an actual mismatched pair, but the frontend has recorded a misleading capture and
cannot complete the intended comparison.

Suggested fix: require a loaded Detail inspection whose query result equals the
selected result, or disable capture while browsing Results until Enter loads that
row. Preserve the existing stale-form token protection.

### F4 — Medium: comparison refresh never pins its verified target generations

Initial pair construction correctly assigns inspection digests to
`expected_left_workload_digest` / `expected_right_workload_digest`, leaving target
digests absent. However `Workloads_view.compare` (`384–398`) does this unconditionally
even after a verified comparison has supplied `left.source_digest` and
`right.source_digest`. Refresh therefore pins only workload generations and never
the target-side generations it just displayed.

Independent reproduction attaches a comparison with distinct side digests C/D, then
invokes the real Refresh input. Both expected target digest fields are still None.
An across-query target-generation/alias change compatible with the same workload
binding is consequently a new capture, rather than rejection of the captured pair.
The backend's per-read root/hash fences do not pin generations across separate reads.
This is a frontend capture-policy gap; this test does not mutate original retained
evidence or claim a new public reader race.

Suggested fix: retain verified target-side digests for refresh of that ordered
pair/axis; clear/reacquire them deliberately when changing the pair/axis. Do not put
workload inspection digests into those fields. Any query-key transition needs the
existing receipt/generation fences.

## Controls and source-review conclusions

- Initial pair, swap and axis emission keep each workload digest attached to its
  original result/bundle. The first pair uses the *workload* fields correctly.
- Distinct source/pair/axis generation tickets reject late receipts; production
  Workloads queries include ordered paths, axis and workload expectations in keys.
- Same-key pre-receipt failure cannot acknowledge a newer request; post-receipt
  failure retains facts and reports diagnostics. Reconnect revokes cached view
  validation and fences old generation receipts. Project/daemon replacement drops
  local view state.
- Main transport source review: `perform_asic_request` checks captured client,
  daemon instance and project before `fresh_receipt` or snapshot publication;
  `workload_request` additionally checks tile lifetime and view generation. Testing
  handoff checks original client/instance/project/session/workspace, navigation
  intent, simulation identity and the exact selected artifact after the await.
  These project/transport closures are reviewed statically: the independent unit
  executable does not import/run `terminal/main.ml` or claim native network-race
  coverage of its closures.
- Reference JSON uses exact object fields/version, absolute non-control-character
  paths and lowercase source digests; duplicate paths with otherwise valid digests,
  relative paths, NUL/newline and uppercase digests are adversarial controls.
  Artifact SHA and public inspection digest remain distinct. Main explicitly checks
  page attempt/artifact/SHA/size/offset/next-offset/EOF, decoded length and raw-byte
  SHA before parsing the reference, and imports with `Some source_digest`.
- The independent byte-page corruption matrix exercises the exported production
  `Simulation_export.validate` (wrong attempt/artifact/digest/span/hex/EOF). Main's
  PT8 branch implements its own gate rather than calling that validator; its gate
  was source-reviewed, not misrepresented as executed by those control assertions.
- Workloads rows/host paint are pure consumers; read intents occur in explicit
  action handling. Repeated geometry/paint and non-read navigation do not emit
  provider intents. No subprocess/HTTP API exists in the view's render path.
- Hidden-layout preservation and project replacement are exercised through the
  production host. Existing custom keys named `workloads` remain permitted by
  `Workspace_config.custom_key_allowed`; the main opener identifies stock workspaces
  by preset and does not rewrite user layout definitions. Native custom-layout
  creation was not rerun by this independent suite.

## Initial commands / results (historical)

Use only the isolated build, six-job ceiling, switch and shared lock:

```sh
flock /tmp/opencode/workbench-pt8-build.lock opam exec --switch=5.2.0+ox -- \
  dune runtest -j6 --build-dir _build_pt8_workbench backend/test/frontend_review
```

The suite deliberately exits nonzero while the contract assertions above fail; it
is a regression reproducer, not a passing smoke receipt. The first complete run
reported 41 checks, five failed assertions covering F1/F2/F3. The final run adds F4
and additional strict-reference controls: **45 checks, 39 passing controls and six
failed assertions covering the four findings**. All inspection/comparison document
fixtures are admitted by B's production response validator before presentation,
including the comparison fixture with distinct target and workload digest domains.

The root `dune` marks `test/` data-only, so the independent test was placed under
`backend/test/frontend_review/` without changing shared build declarations. Initial
review harness compile/buffering issues were corrected in these independent files.
No shared `_build` directories were used or cleaned. Root configs/live daemons and
concurrent ASIC/example/feature work remain untouched. The reported concurrent
feature daemon's missing `hardcaml_asic.execution` is not attributed to root config
or investigated by changing its environment; this review does not require it.

## Independent correction rerun — B

2026-11-05, after A's F1–F4 corrections and locator UX changes. This rerun was
performed by B, not accepted from A's generated `frontend_review_recheck` output.
Only independent review files/build declarations and this document changed; no
production files or A tests were edited. No private native session was started or
interfered with; C's concurrent final native acceptance remains its own evidence.

### Original probe and exact fixture corrections

Built and ran `review_frontend.exe` from the preserved source. Its first eight
assertions pass, including target-digest refresh and pinned reopening. It then
aborts at original line111 with `Captured workload/target digest changed`: the
original helper tries to backend-admit digestC under `reopened.query`, which now
correctly expects digestA. This is a broken adversarial fixture precondition after
the fix, not proof that the complete original suite passed.

Added the **explicit, non-generated**
`backend/test/frontend_review/review_frontend_corrected.ml`. Before adding new
controls, `git diff --no-index` against the original was inspected. Apart from
comments/summary wording, it makes only these two fixture corrections and retains
**every original assertion and predicate**:

1. The alternate cached C payload is created under an explicit
   `Inspect {result="/retained/shared.json"; expected_digest=None}` query, as the
   scenario describes. It is not created under the repaired pinned query. Backend
   admission still validates the fixture; frontend reconciliation must reject it
   for the pinned selection.
2. The synthetic FS2 attempt requests and records **both** Flops and Exact before
   invoking the unchanged `select_case state "exact256"` assertion. The original
   one-case fixture never allowed this navigation: production `select_case` rejects
   unavailable cases and retains Flops. A's supplemental generator instead forces
   an absent case into the view; B used the stronger, ordinary legal two-case state
   and separately asserts that the selection really becomes Exact.

The original `.ml` remains byte-for-byte unchanged at its original path. Its Dune
stanza is now an explicitly runnable historical executable; the corrected harness
is the active regression test. Thus ordinary review `runtest` runs a valid test
rather than aborting on the archived fixture's known-invalid precondition. No
original assertion was removed, relaxed, or rewritten to match current behavior.

First corrected run: **45/45 original assertions pass**. The final run adds33
independent controls: **78/78 pass**.

### Dispositions

| Finding | Independent disposition | Executed evidence |
| --- | --- | --- |
| F1: FS2 namespace mismatch | **Corrected** | Real `Simulation_service.capture_artifact` creates prefixed Flops and Exact references. Automatic and explicit selections resolve them. Both selected cases are tested together. Foreign-attempt metadata/prefix, suffix-only impostor, bare ID, wrong case, suite artifact, wrong media type and changed bytes all reject. |
| F2: expected digest lost on reopening | **Corrected** | Esc→Enter retains expectedA; a separately valid unpinned cacheC cannot hydrate it. A defensive inconsistent pinned-key/response-digestC wrapper also cannot populate its document. |
| F3: capture binds old A while B is highlighted | **Corrected** | The original Back→Move B→Capture assertion now rejects the stale capture. `capture_ready` requires Detail, selected/query equality, descriptor query/key and validation metadata. Added metadata mismatch controls reject key/query/freshness/provider/digest inconsistencies. |
| F4: target generations unpinned on refresh | **Corrected** | Backend-admitted comparison with distinct workloadA/B and targetC/D domains produces a Refresh query pinning targetC/D in target fields; the original workload-field, ordered swap and axis assertions still pass. |

Source inspection confirms the production causes, not merely the test outcomes:

- `Testing_workspace.workload_artifact` requires exact
  `detail.id ^ "-" ^ selected_case ^ "-result-reference"`, matching attempt and
  artifact case, captured request membership and retained result membership.
- `inspection_query` recovers the complete prior query from current state,
  remembered inspections or deterministic pinned-first cache descriptors.
- Moving the results selection clears old query/document/descriptor state;
  `capture_ready` rejects browsing-mode captures and inconsistent metadata.
- Validated comparison reconciliation retains both target-side source digests;
  compare/refresh uses them separately from captured workload digests. Axis changes
  clear axis-specific target expectations; swap reverses their ordered association.

### Locator UX independently checked

The new projection fixture includes `binding.bundle` and passes B's production
response validator. Tests call the production `verified_bundle`/capture path and
confirm that it captures the exact result, standalone source digest, bundle locator
and inspection reader identity **without a provider intent**. A conflicting manual
bundle cannot override that locator. Missing locator remains a legacy manual-capture
case; relative/null/NUL locators fail backend admission. Cached-unverified or
inconsistent metadata cannot expose auto-capture.

The corresponding production transport branch was read at
`terminal/main.ml:6104–6146`: valid locator goes directly through the same pure
capture function with `Effect.Ignore`; only the legacy no-locator branch opens the
manual bundle form. This is unit execution plus source verification of wiring,
not a claim that B reran C's real native UX/PTY scenario.

### Fixed source and probe identities

SHA256 values captured after the passing run. Build-tree copies of Workloads view
and Testing selector matched these source hashes.

| File | SHA256 |
| --- | --- |
| `terminal/workloads_view.ml` | `52e0962b6f7514a95e2c779209e1890baa250a60925641ec11490788f8005117` |
| `terminal/testing_workspace.ml` | `c211b439497b0d4acdc6f862252fb520d43c91989faea9f2f524bb93c70d6d98` |
| `terminal/main.ml` | `33486bc4e9e2123b5843617c8fadaad551f752561a0bbded2cafd18b7f10c793` |
| `terminal/workspace_host.ml` | `343c9e3a4c34496f63a0e2c682214be54f068470966b5aa19eb657c8ac730665` |
| `terminal/navigation_preferences.ml` | `22a4f07d9f43bb8a9a9b76f8616a642ff5cbb3660225e5a7af5aa54babb6c33d` |
| `backend/simulation_service.ml` | `f83094361472544cfc4868fe7590dd0bf9e483211813e00d289cde14ecd6df30` |
| `backend/asic_workloads_service.ml` | `a487d0add6b89a8c1bf29b5dbff1bf06c40f8e04b6415eca18773c564fdb9984` |
| Preserved `review_frontend.ml` | `3b759c0e5bbacaefd7fa02b6e33b95b4aff4072eefc8ac14a9514a1d4ca2d87b` |
| Explicit `review_frontend_corrected.ml` | `bb38ded602c0eef31dcb945fe2a49f26b49b70415b56b2eb0ea0c8d9fd6914ec` |
| Built `review_frontend_corrected.exe` | `8bce61d46b704d81cfc4dd89fdb0f38fcb88d3dcd41f138ff5d87a2b550c1849` |

### Rerun commands and scope

```sh
flock /tmp/opencode/workbench-pt8-build.lock opam exec --switch=5.2.0+ox -- \
  dune build -j6 --build-dir _build_pt8_workbench \
  backend/test/frontend_review/review_frontend.exe
# Preserved historical probe: expected precondition exception after eight passes.
_build_pt8_workbench/default/backend/test/frontend_review/review_frontend.exe

flock /tmp/opencode/workbench-pt8-build.lock opam exec --switch=5.2.0+ox -- \
  dune runtest -j6 --build-dir _build_pt8_workbench backend/test/frontend_review
# Independent corrected frontend review: 78 checks; 0 contract failures
```

**F1–F4 are closed for these reviewed source hashes and bounded frontend contracts.**
No additional finding was reproduced by this correction rerun. Original caveats
about source-reviewed main transport closures and exported byte-page validator
coverage still apply; this does not claim an extra simulator/native acceptance run.
