# Workbench test-refactor continuation handoff

**Updated: 2026-11-10. First organization slice and initial execution/support/native
smoke refactor complete.** Owner requested this cache so another session can continue independently
of the ongoing `hardcaml_asic_example` verification refactor.

Start with [the overall session checkpoint](../session_checkpoint.md). The
[Workbench construction plan](../construction_phase_plan.md) remains the active
queue. This handoff groups migration steps; it is not a second queue or authorization
to run hardware/EDA or modify the sibling example.

## 1. Goal and accepted ownership policy

### Current continuation checkpoint

**Owner deferral:** remaining general refactor/coverage work is cached in the
[flow-coverage backlog](../backlog/tool-test-flow-coverage.md). Main PT.0–PT.8
completion takes priority. Resume this migration only when reactivated.

[Implemented changes and verified commands](../test_refactor_verification.md)
supersede the original blockers and proposed-only status below:

- Disposable scripted Git fixtures are permitted by the owner's clarified policy;
  no owner-checkout staging/commit/push/authorship mutation is permitted.
- RPC fixtures now explicitly request nested one-job Dune execution. Backend/setup
  passed separately at outer `-j1`; contracts/presentation/API passed at `-j2`.
  Setup intentionally launches twelve initializers; keep those runs isolated.
- `test/support/` now contains shared screen/PTY helpers. Ten controlled tests are
  registered as `@test-support`, normal `runtest`, and part of `@test-local`.
- Terminal-owned `@test-native-smoke` is registered, sandboxed and passed seven
  synthetic waveform-handoff assertions. It remains opt-in.
- Independent review corrections and targeted reruns are complete. Broader shared
  HTTP/process extraction, app-wide driver migration and example compatibility
  remain next work. `test/integration/` is still proposed.

The numbered sections below retain the original migration plan/history. Statements
that all support extraction is unimplemented or backend/API execution is blocked
describe the first slice, not this updated checkpoint. Use the current root test
README and verification page for execution commands and limits.

Make software tool tests discoverable, selectable, bounded and independent of
the example's evolving verification techniques. Preserve current tests/evidence
while extracting reusable support and migrating genuinely app-wide integration.

Use the **smallest owner of the behavior/composition contract**, not the number of
modules imported:

- Unit/parser/codec/reducer contracts: inline or subsystem `test/`.
- Backend + its provider/cache composition: `backend/test/`.
- HTTP/RPC server composition: `daemon/test/`.
- Rendering/input/catalog composition: terminal-owned tests.
- Installed client→transport→daemon→provider workflows: root app integration.
- Common HTTP/PTY/fake-provider/receipt helpers: reusable test-only support.
- DUT stimulus/model/assertions/scoreboards: the hardware project's verification.

A DUT Failed outcome may be a successful tool test when the tool reports and
retains it correctly. Workloads include scenario/checking/measurement requirements
beyond raw stimulus; that does not make the tool and hardware test suites the same.

## 2. Implemented starting state — do not redo it

No test sources, fixtures, baselines or historical review records were moved.

| Current source | Actual role |
| --- | --- |
| Root `dune` | Six forwarding suite selectors |
| `test/dune` | Aliases over existing subsystem `runtest`; data-only children preserved |
| `test/README.md` | First entry point for tests of Workbench itself |
| `docs/testing.md` | Ownership/location policy, current selectors and future steps |
| `docs/testing_inventory.md` | Representative registration, script/import and example-dependency inventory |
| `docs/test_suite_selection_verification.md` | Actual executed versus inspected verification |
| `docs/test_organization_plan.md` | Original preimplementation plan and first-slice closeout |

Implemented selectors:

| Alias | Existing selection |
| --- | --- |
| `@test-contracts` | protocol including production inline tests, provider, project integration, adapters |
| `@test-presentation` | recursive terminal tests, workspaces and focused terminal integration |
| `@test-backend` | recursive backend/test |
| `@test-setup` | setup/test |
| `@test-api` | daemon/test |
| `@test-local` | contracts + backend + presentation + setup; **not API** |

The names are mixed local test families, not claims of unit-only, complete or
uniformly fast coverage. Default `@runtest` registrations remain unchanged.
`test/{fixtures,baselines,pt8_frontend_review}` remain data-only. In particular,
`test/fixtures/example_project` is a specimen with its own Dune project, not active
Workbench test code. Never remove that boundary as incidental cleanup.

### Verified first slice

- All six root/index aliases discovered; existing registration inspected.
- `@test-contracts` and `@test-presentation` **forcibly rerun and passed**.
- Actual fixture target `test/fixtures/example_project/workbench/project_driver.exe`
  correctly rejected by Workbench Dune, proving that fixture stanza stays inactive.
- Process traces observed no nested Dune, Git, application pair, example provider,
  hardware simulator or EDA in those two suite executions.
- Independent source review found no alias/ownership/boundary blocker.

**Not executed in this slice:** backend/API/local, setup, broad default runtest,
standalone native scripts, sibling-example verification, synthesis or physical work.

## 3. Known blockers and coupling to address first

1. `backend/test/test_service.ml` initializes/configures/stages/commits a disposable
   Git fixture. These are not writes to the owner checkout, but still conflict
   with the current no-Git-mutation execution instructions. Do not call that suite
   "safe under the policy" without an explicit correction or owner decision.
2. `daemon/test/test_rpc.ml` submits disposable-project Build operations reaching
   `adapters/dune_adapter.ml`'s nested `-j20` command. An outer `-j2` cannot override
   child argv. Other standalone scripts also contain fixed job assumptions.
3. Many Python HTTP/PTY scripts are opt-in, not Dune-registered. Their filename
   does not register them; a helper executable is also not automatically a test.
4. Common helpers are imported from other test entrypoints via `importlib`,
   `Path(__file__)` parent lookups and `sys.path` changes. Moving them can break
   imports, fixture lookup and historical invocation paths.
5. Inline/expect tests have switch-specific `-source-tree-root .` requirements.
   Preserve their registration/source-path semantics when extracting modules.
6. Real-example scripts pin suite/case IDs, source paths and immutable generations.
   Their compatibility must be reassessed after the example refactor; do not
   silently run against its mutable defaults or update expected results to pass.

## 4. Staged continuation plan

Activate one bounded step in the construction queue before implementation. Prefer
exclusive owners/files and a short shared interface handoff over broad file moves.

### A. Harden the local test execution envelope

- Inventory actual nested command argv, worker multiplication and fixture writes.
- Make job limits explicit through the relevant command/test interfaces; don't
  alter synthesis semantics or silently rewrite recorded argv to claim compliance.
- Replace/segregate authoring Git fixture setup using immutable fixture inputs or
  an explicitly agreed non-writing fixture strategy; preserve tested provenance
  semantics and genuine clean/dirty/untracked cases.
- Keep owned temp directories, bounded timeouts, cancellation/reaping and no-owner-
  daemon invariants. State what each test may write or launch.

Acceptance: execute backend/API/setup/local groups only after their envelope is
admitted; inspect actual child argv/processes and failure controls. Local tests must
not launch real EDA or mutate the sibling project. This is runner/fixture hardening,
not a generic scheduler.

### B. Extract shared test support in small batches

Proposed destination: `test/support/` with an internal OCaml/Python support API;
it is **not implemented yet**. Start with one helper family, such as isolated
process/state ownership or the typed HTTP client, before tackling all PTY utilities.

- Inventory consumers from `docs/testing_inventory.md`.
- Specify a small test-only API; no production dependency on acceptance helpers.
- Move logic without changing assertions, golden output or DUT/oracle behavior in
  the same patch. Preserve temporary compatibility entrypoints/imports if needed.
- Declare transitive Python imports/fixtures/executables in Dune when registered.
- Test helper failures, deadlines, cancellation and cleanup with controlled inputs.

Acceptance: before/after equivalent targeted results and meaningful negative
controls; no hidden `main` execution on import; path-independent invocation.

### C. Register one Workbench-only native integration smoke

Pick an existing synthetic/provider-controlled HTTP/PTY test whose entire input
closure is Workbench-owned. Explicitly classify real-counter versus synthetic
modes; shared imports do not prove that a script never touches the example.

- Use prebuilt or explicitly Dune-declared app/fixture executable inputs.
- Declare scripts, imported helpers, fixtures and budgets.
- Verify actual keys/forms/rendered state plus supporting typed RPC/evidence.
- Ensure no toolchain/PDK/Docker/sibling-example dependency or physical launch.

Acceptance: registration is real and selectively rerunnable, not merely building
an executable. Record exactly which paths are TUI, RPC and direct helpers.

### D. Migrate app-wide drivers without moving subsystem tests

Proposed destination: `test/integration/`, **not implemented yet**. Keep backend/
terminal/daemon-owned composition tests with their owners. Move cross-app scenarios
in small batches, with compatibility wrappers where historical commands matter.
Leave fixture/baseline/evidence paths stable unless a separate migration explicitly
preserves and verifies them. Do not reactivate historical failing review oracles.

### E. Rejoin the refactored example and expensive acceptance

Wait until the example's owner supplies its new provider/verification interfaces
and baseline. Compare suite/case/parameter IDs, event/artifact schemas, source
inventories, Dune targets, workload/checker versions and VCD signal/time semantics.
Classify failures as tool, DUT, intentional contract change, stale fixture, harness
oracle or environment defects before editing expectations.

Keep actual hardware/provider and real-EDA suites opt-in with exact external
input identities. Build a stage-prefix coverage matrix separating fast controlled
orchestration from selected real tool runs. Source→synthesis→floorplan→placement→
CTS→routing→timing→signoff have distinct stop-point and qualification obligations.
Do not require the full physical chain for every rendering change, or reuse old
routed measurements as proof for newly changed hardware.

## 5. Safe verification starting point

From Workbench, subject to the shared global job budget:

```bash
flock /tmp/opencode/workbench-pt8-build.lock \
  opam exec --switch=5.2.0+ox -- dune build -j2 \
  --build-dir _build_pt8_workbench @test-contracts @test-presentation
```

Those two groups are the admitted first-slice executions. Do not replace them
with `@test-local`, `@test-api` or broad `@runtest` while the above nested-budget/
Git-fixture constraints are unresolved. They are selectors, not resource overrides.
No fresh hardware simulation or EDA is authorized by this handoff.

## 6. Next-session pickup checklist

1. Read workspace `AGENTS.md`, applicable repo instructions and Git status. Preserve
   staged/untracked work and retained evidence; don't reset/clean/stage/commit it.
2. Read the checkpoint and authoritative queues; confirm what the owner wants
   resumed. The synthesis acceptance is paused, not a background job.
3. Read the inventory, selector verification and specific test owner sources.
4. Confirm the sibling example refactor's boundaries; don't inspect/change/run it
   merely to organize Workbench-only tests.
5. Propose/activate a small step above, freeze helper interfaces and exclusive
   ownership, then implement, targeted-test and independently review.
6. Update the queue and this guide's status with actual commands/results/limits.
   Do not claim unexecuted suites passed because registrations exist.
