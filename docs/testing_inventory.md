# Workbench test inventory and locality boundaries

**Continuation update:** [current refactor verification](test_refactor_verification.md)
records shared `test/support/` PTY/screen helpers, registered support/native-smoke
selectors and bounded local-suite execution. The tables below retain the original
pre-extraction inventory; the waveform-handoff script is now registered under the
opt-in native-smoke selector and FS0/FS2 use shared support.

2026-11-10. Source-only research slice. Paths below are relative to the Workbench
checkout unless explicitly identified as external. This is a representative
catalogue, not an exhaustive test count or a new execution/implementation queue.
It records declarations and inspected harness behavior, not fresh passing results.

**Subsequent first restructuring:** [suite selection and ownership guide](testing.md)
and [execution receipt](test_suite_selection_verification.md) record the implemented
root selectors. Root `test/` is now an index; `test/dune` keeps its existing fixture,
baseline and review children data-only. The initial inventory below remains source
classification, not evidence that every listed test was executed.

## Scope and interpretation

The task's user instructions, workspace instructions, Workbench README development
guidance, [testing status](testing_strategy_status.md), and current developer
workflow handoffs inform this inventory. Only this new document is owned by this
slice. No Dune invocation, build, test, provider, EDA job or daemon was started.
The refactoring `hardcaml_asic_example` checkout was neither inspected nor run;
references to its dependencies below come from WB scripts and path literals only.
Existing build products are not evidence of current test success.

**Registration vocabulary:**

- **Yes — inline:** a library has `(inline_tests)` and includes the test module.
- **Yes — test/action:** `(test ...)` or an explicit `(rule (alias runtest) ...)`.
- **Build only:** `(executable ...)` or a generation rule, without a test action.
- **No — opt-in/data:** no WB test registration found for the named entrypoint in
  the inspected source Dune declarations. It can still be executable acceptance.
- A fixture's own Dune project is distinguished from registration in WB's project.

Source `dune` files were located in WB and their test/action/executable stanzas
checked; the named standalone scripts were also checked against those declarations.
This is static registration evidence, not a resolved Dune dependency-graph audit.
Generated `_build*` trees, external project suites and every script branch were
not audited. The inventory establishes no automated N×M endpoint/client/provider
coverage matrix. Broader suite candidates below are proposals; the subsequently
implemented local selector aliases are documented in the testing guide.

Tool behavior and DUT verification are separate outcomes: a faithfully transported
hardware failure can pass a tool test. Fake-provider lifecycle tests do not prove
hardware correctness or real EDA execution; retained-byte replay does not rerun its
producer. See the two outcome axes in `docs/testing_strategy_status.md`.

## 1. Subsystem-owned tests: contracts, reducers and local lifecycles

These belong near their owning subsystem even when they compose several libraries.
“WB-only” means no mutable sibling example input is required; it does not mean
zero subprocesses, zero native dependencies or zero build cost.

| Owner / representative exact paths | Actual WB Dune registration and proof | Boundary / suite candidate |
| --- | --- | --- |
| Protocol: `protocol/test/test_protocol.ml`, `protocol/test/test_asic_stages.ml`, `protocol/test/test_asic_workloads.ml`, `protocol/test/test_workspace_restore.ml` | **Yes — inline**, `protocol/test/dune:8–17`; production protocol library also enables inline tests in `protocol/dune:1–8` | Wire, validation, stage and workspace contracts; WB-only contract candidate |
| Provider SDK: `provider/test/conformance.ml`, `provider/test/frozen_wire.ml`, `provider/test/runner_test.py`, `provider/test/fixture.ml` | **Yes — test/action**, `provider/test/dune:8–19`; `fixture.exe` is a helper executable at lines 1–6, explicitly consumed by the Python action | Frozen wire/conformance and controlled provider process behavior; not actual FIFO verification |
| Adapter: `adapters/test/test_dune_adapter.ml` | **Yes — inline**, `adapters/test/dune:3–12` | Invocation construction/identity. Expected argv strings containing `dune ... -j20` are assertions, not permission to run a 20-job build |
| Project integration: `project_integration/test/test_project_integration.ml` | **Yes — inline**, `project_integration/test/dune:1–11` | Project/config/driver contracts; WB-only candidate |
| Setup: `setup/test/test_initialization.ml`, `setup/test/test_project_discovery.ml`, `setup/test/test_simulation_setup.ml` | **Yes — inline**, explicit modules in `setup/test/dune:1–12` | Local initialization/discovery; keep tests with setup |
| Backend service/simulation/preparation: `backend/test/test_service.ml`, `backend/test/test_simulation.ml`, `backend/test/test_preparation.ml` | **Yes — tests**, `backend/test/dune:1–50`; `fs2_provider.py` and `fresh_provider.py` declared as dependencies | Controlled process/state/preparation lifecycles. Preparation source injects shell build/emission behavior; it is not evidence of example synthesis |
| Backend ASIC/catalog: `backend/test/asic/test_asic.ml`, `backend/test/asic/test_catalog.ml`, `backend/test/asic/fake_provider.py`, `backend/test/asic/production_flow_list.json` | **Yes — tests**, `backend/test/asic/dune:1–32` | Fake-provider orchestration and recorded catalog contracts, not actual execution of every production endpoint |
| Backend readers/state: `backend/test/execution/test_execution.ml`, `backend/test/stage_normalization/test_stage_normalization.ml`, `backend/test/asic_artifacts/test_asic_artifacts.ml`, `backend/test/workspace/test_workspace.ml` | **Yes — tests**, each matching directory's `dune` contains its named `(test ...)` | WB-owned execution normalization, artifacts and workspace state; local fixtures |
| Backend inspectors: `backend/test/inspection/test_inspection.ml`, `backend/test/inspection/test_timing_analysis.ml`, `backend/test/resources/test_resources.ml` | **Yes — tests**, `backend/test/inspection/dune:1–34` and `backend/test/resources/dune:1–6`; local Python providers declared | Controlled inspection/cache/failure and resource behavior; WB-only integration candidate |
| Backend workloads/storage: `backend/test/workloads/test_workloads.ml`, `backend/test/workloads/test_storage.ml`, `backend/test/workloads/provider.py` | **Yes — tests**, `backend/test/workloads/dune:1–15` | Workload associations/storage with controlled producer; not PT.8 hardware proof |
| Colocated terminal inline tests: `terminal/waveform_data.ml`, `terminal/waveform_time.ml`, `terminal/testing_workspace.ml`, `terminal/launch_preferences.ml` | **Yes — inline**, all included by `terminal/dune:3–59`, runner at lines 76–78; actual `let%test_unit` declarations are present in these files | Parsing/exact time, selected-result handoff, state and preference contracts; WB-only candidate |
| Terminal test modules: `terminal/stage_launch_commands_test.ml`, `terminal/workloads_view_test.ml`, `terminal/resources_view_test.ml`, `terminal/preparation_test.ml` | **Yes — inline**, explicitly included in the same `terminal_presentation` library | Production composition/input/rendering under controlled state, not merely filename-based test discovery |
| Workspace definitions: `terminal/workspaces/test_workspaces.ml` | **Yes — inline**, `terminal/workspaces/dune:40–48` | Stock/custom workspace validation and behavior. `export_presets.ml` is a separate **build-only** helper at lines 35–38 |

Some inline runners preserve `-source-tree-root .` in their Dune flags. Moving
modules without preserving runner/source-path behavior risks breaking expect tests;
registration and test locality should not be inferred from `_test.ml` names alone.

## 2. Application integration: nearest composition owner versus cross-app

| Representative exact paths | Registration proof | Scope / locality |
| --- | --- | --- |
| `daemon/test/test_rpc.ml` | **Yes — test**, `daemon/test/dune:1–14`, links native HTTP and RPC server | Public transport/server composition; belongs with daemon. `native_http/dune` declares only a production library, not a separate native-HTTP test suite |
| `setup/test/test_cli.py`, `setup/test/test_simulation_cli.py` | **Yes — runtest actions**, `setup/test/dune:14–24` invokes setup executables | Real CLI boundary, nearest setup composition owner |
| `terminal/endpoint_prompt_test.ml` | **Yes — test**, `terminal/dune:87–94`, explicitly passes `backend/test/asic/production_flow_list.json` | Production prompt/catalog composition; local terminal test with a cross-directory fixture dependency |
| `terminal/workloads_handoff_probe.ml` | **Yes — test**, `terminal/dune:96–101` | Despite “probe” in the name, this one is registered; terminal/backend handoff belongs with terminal |
| `terminal/test/evidence_activity/test_evidence_activity.ml`, `terminal/test/evidence_activity/refresh_provider.py` | **Yes — test**, `terminal/test/evidence_activity/dune:1–15` | Evidence refresh composition with backend and local provider |
| `terminal/test_navigation_hydration_restart.py`, `terminal/test_presentation_preferences_restart.py` | **Yes — runtest actions**, `terminal/dune:137–153` passes `navigation_hydration_probe.exe` / `presentation_preferences_probe.exe` | Registered restart/preferences tests. The helper executable stanzas alone would not provide that registration |
| `terminal/test_endpoint_prompt_native.py`, `terminal/test_standard_plan_recovery.py`, `terminal/test_workloads_native.py` | **No — opt-in**; `terminal/dune` registers the OCaml prompt/handoff tests and two restart Python actions, not these scripts | Actual private HTTP/PTY UI integration. Endpoint script permits catalog/version reads only, with no source execution/physical launch; keep near terminal composition |
| `terminal/test_waveform_handoff_pty.py` | **No — opt-in**; absent from terminal test actions | Private real daemon/client with a generated synthetic JSON/VCD provider. WB-only PTY candidate, not actual PT.8 simulation |
| `scripts/test-frontend-composition.py`, `scripts/test-frontend-refinement.py`, `scripts/test-synthetic-testing.py`, `scripts/test-testing-workspace.py` | **No — opt-in**; no source Dune test action references these entrypoints | Cross-process HTTP/PTY acceptance using prebuilt apps and controlled WB providers; plausible WB-only native suite candidates after per-mode dependency/cost admission. Testing-workspace config points to `scripts/fixtures/fs2_provider.py`; importing native helpers does not run their main hardware acceptance |
| `scripts/test-native-application.sh` | **No — opt-in**; no Dune action invokes it | Install/initializer/client/daemon/driver composition using copied WB root fixtures and private HOME/XDG state. Cross-app/package suite candidate, explicitly build-bearing |
| `scripts/test-unified-fresh-prefix.py` | **No — opt-in**; no Dune action invokes it | Actual native UI and source-preparation orchestration with synthetic EDA providers. WB-owned inputs, but nested fixture Dune builds and a `-j6`-checking wrapper: not an immediately admitted `-j2` smoke |

The ordinary root integration location should be reserved for genuinely cross-app
flows such as installed setup → daemon → client → driver. A test of terminal
composition need not move to root merely because it links backend/protocol. The
root fixture/baseline subdirectories are data-only. Root `test/` now hosts selectors;
adding cross-app executable tests there later still requires an intentional
registration/layout decision, not just dropping in a file.

## 3. Hardware/provider integration and example-sensitive routes

All named script entrypoints in this table are **No — opt-in** under the inspected
WB Dune declarations. Hardware providers have their own contracts and costs.

| Representative exact paths | WB-visible dependency evidence | Disposition |
| --- | --- | --- |
| `scripts/test-fs2-provider.py` | Invokes `examples/fs2_cyclesim/provider.py` with explicit prebuilt `--counter`; checks real simulation outputs, deterministic signal bodies and injected failure | Small WB-owned hardware/provider candidate; requires the independently built specimen, not the sibling example. `examples/fs2_cyclesim/dune:1–13` declares `counter` and `test_provider` as **executables only**, not test actions |
| `scripts/test-fs2-native.py` | Requires prebuilt daemon/client/counter; combines controlled provider negatives with real counter Cyclesim and actual PTY launch/rerun/artifact checks | WB-owned hardware plus app integration candidate, not a wholly fake-provider smoke. Its `Session`/`Terminal` are also imported independently by controlled-provider scripts |
| `scripts/test-native-provider.py` | `--only counter` selects WB counter adapters; FIFO route references `--fifo-root/simulation/provider.py` and explicit `--fifo-provider` / `--fifo-simulator`. `--fifo-root` defaults to the sibling example | Split candidate by route, not filename. FIFO deferred. Even counter-only currently resolves every supplied/default path including `fifo_root` with `strict=True`: do not advertise the entire entrypoint as example-independent without addressing that coupling |
| `scripts/test-fifo-testing.py` | Defaults `--root` to sibling example, copies `simulation/` and `scripts/install-fifo-simulation.py`, uses a real simulator | FIFO hardware route deferred; it also supplies terminal support to the combined development-session harness |
| `scripts/test-development-session.py` | Imports native/FIFO harnesses; default launcher is sibling `scripts/workbench_dev.py`; requires prepared private store/root and runs combined FIFO/PT.8 native forms | Example-sensitive app/provider integration; defer fresh runs during refactor, or later use explicitly approved immutable capture and exact private store identities |
| `scripts/test-development-prepare.py`, `scripts/test-development-capture-smoke.py`, `scripts/test-development-provider.py` | First two reference sibling `scripts/workbench_dev.py`; provider test consumes a private store manifest's `provider_command` and compares real child discovery | Deferred example-sensitive preparation/router checks, even when no simulation/EDA is performed. Prepare/refresh can build and deliberately edits private copied source |
| `scripts/test-developer-workflow.py` | Imports `scripts/test-development-session.py`; pins `OWNER_GENERATION` and `ASIC_GENERATION`, consumes captured SDK/apps and same-store phase receipts; optional preparation builds apps with shared lock and `-j2` | Example-sensitive phased acceptance, explicitly gated as described below; not a WB-only fast suite |
| `scripts/test-fs0.py`, `scripts/test-fs0-dashboard.py`, `scripts/test-fs1-investigation.py` | WB scripts contain sibling-example defaults/path references; native helper consumers import these files too | Whole-script runs deferred unless a specific synthetic mode's complete input closure is established. Helper import does not itself prove that the example is executed |
| `scripts/test-real-asic-example.py`, `scripts/real-asic-example-demo.py` | Test imports demo and composition oracle; demo sets `EXAMPLE = REPO.parent / 'hardcaml_asic_example'`; test consumes prepared persistent manifest/provider/project paths | Retained real-provider app integration, not fresh EDA. Still example-sensitive and deferred; “no build/EDA” is not “WB-only” |
| `scripts/run-fs1-physical.py`, `scripts/run-fs1-finalization-acceptance.py` | Literal external example/project/tool paths; historical thread environment values of 20; real physical or external acceptance producers | Expensive explicit qualification utilities. Deferred, no execution authorization from their presence or historical successful evidence |

### Current developer-workflow gate: simulation pass is not synthesis pass

The [acceptance handoff](developer_workflow_acceptance_handoff.md) records
`scripts/test-developer-workflow.py --phase simulations` as passed, including real
FIFO/PT.8 forms, waveform/report transport, simulation restart and source Plan
readiness. Its final phase-1 receipt is
`/tmp/opencode/developer-workflow-simulations-05/receipt.json`; the native simulation
receipt it references is
`/tmp/opencode/developer-workflow-simulations-02/native-simulations/receipt.json`.
These are handoff-reported historical evidence, not receipts revalidated here.

The **positive synthesis/report/check and post-synthesis restart routes are
implemented but not exercised** at this handoff. They remain pending explicit
coordinator resource activation and runtime-owner evidence. Do not launch them.
Enabled Launch-and-view, successful source prewarm, denied-allocation negative
controls, or old synthesis records do not close this gate.

The [resource handoff](developer_workflow_resource_handoff.md) separately reports
synthetic resource-policy tests and metadata observations; its observer has not
yet been attached to the actual acceptance flow. Neither quota declarations nor
those tests prove observed native-worker bounds. This inventory uses EDA0 and
starts or adopts no owner daemon. Later example-sensitive runs need explicit
pinned source/capture, SDK, apps, provider/image, store and receipt identities;
mutable `current` pointers/default sibling paths do not supply that identity.

## 4. Root fixtures, baselines, retained evidence and review/manual utilities

| Exact paths | Registration / interpretation |
| --- | --- |
| `test/fixtures/example_project/lib/counter.ml`, `test/fixtures/example_project/test/test_counter.ml`, `test/fixtures/example_project/workbench/project_driver.ml` | **No WB registration:** now preserved by `test/dune`'s data-only `fixtures` boundary (previously root `data_only_dirs test`). The copied fixture has its own `dune-project`, a `(test ...)` in `test/fixtures/example_project/test/dune`, and fixture-root `runtest` / `workbench-test` aliases. These become executable when used as a separate project, not WB root test discovery |
| `scripts/test-fixture.sh` | **No — opt-in** fixture build/test/driver integration. Copies the fixture to an external temp root; source currently hardcodes `-j20` in several Dune calls. Requires a later bounded-cost adaptation/admission, not immediate execution under this slice |
| `test/baselines/terminal/dashboard.120x40.txt`, `test/baselines/terminal/dashboard.120x40.ansi`, `test/baselines/terminal/artifact-output.80x24.txt` | **No — data**, root data-only subtree. `test/baselines/terminal/README.md` describes generated captures; `scripts/capture-terminal-baseline.sh --check` is a standalone check, not a registered Dune action. Captures are not live PTY acceptance |
| `scripts/fixtures/fs2_wire.py`, `scripts/fixtures/fs2_provider.py`, `scripts/fixtures/fresh_frontend.py`, `scripts/fixtures/unified_fresh_prefix.py` | Support/controlled producers, not standalone registered tests by location. Actual consumption/declarations decide dependency tracking |
| `scripts/fixtures/resource-inspector/`, `scripts/test-resource-inspector.py`, `scripts/test-resource-inspector-retained.py` | **No — opt-in/data.** Inspector groundwork can copy/verify external evidence; its default example/protected-history reads mean even a synthetic-looking wrapper can depend on example state. Retained test fences allowed provider reads. Defer external replay until explicit immutable inputs are agreed |
| `terminal/test_waveform_mixed_rows_pty.py`, `terminal/test_development_waveform_pty.py` | **No — opt-in** real-PTY replay using explicit `--vcd` bytes; latter imports former. No new simulation, but external retained VCD is still an input. Candidate for offline app integration only with a pinned self-contained fixture and explicit binary paths |
| `review_pt8_endpoint_defaults/review.ml`, `review_pt8_endpoint_defaults/grammar.ml` | **Build only**, corresponding `dune:1–11` has two executable stanzas, no test/runtest action |
| `review_pt8_waveform_frontend/review.ml`, `review_pt8_waveform_frontend/async_review.ml` | **Build only**, corresponding `dune:1–11`, not automatic regression registration |
| `review_pt8_workloads_backend/probe.ml`, `review_pt8_workloads_backend/schema2/cases.ml` | **Build only**: root review `dune` declares `probe`; `schema2/dune` generates `recheck.ml` using `generate.py`, `cases.ml`, `../probe.ml`, then declares an executable. Generation/build is not test execution |
| `reviewdocs/tests/development_waveform_probe.ml`, `reviewdocs/backend_review/cancellation_prefix_probe.ml` | **Build only**, each directory's `dune` declares an executable, no test action. Nearby Python review runners and Markdown reviews are opt-in utilities/retained review records |
| `backend/test/frontend_review/review_frontend.ml`, `backend/test/frontend_review/review_frontend_corrected.ml` | Historical original **build only**; corrected harness **Yes — test**, proved by `backend/test/frontend_review/dune:1–15`. Dune comment records the original F2 fixture's repaired-precondition incompatibility; do not turn it into a passing current oracle silently |
| `terminal/frontend_review_recheck.py` | **Yes — generated test dependency**, `terminal/dune:103–116` generates and registers `frontend_review_recheck.ml` from the historical frontend source. A review-derived regression actually registered with Dune, unlike the review executables above |
| `scripts/developer-workflow-resources.py`, `scripts/test-developer-workflow-resources.py` | **No — opt-in** observer/manual runtime utility versus synthetic policy unit-test script. The latter dynamically imports the former. Neither is a passing actual synthesis/runtime acceptance gate |
| `scripts/synthetic-flow-demo.py`, `scripts/real-asic-example-demo.py`, `scripts/run-resource-inspector-regressions.py` | **No — opt-in** demo/recorder utilities. Synthetic demo prepares private providers; real demo consumes example captures. Regression recorder includes external protected-evidence reads, six-job builds and an `asic-full` sibling-library branch: not a generic WB-only launcher |

The inspected listings of `review_pt6_resource_probe/` and
`test/pt8_frontend_review/` were empty. No active suite or evidence payload is
inferred from those directory names. Historical reviews/handoffs should retain
their original producer and failure disposition rather than being relabelled as
current regression success.

## 5. Shared helpers are scattered imports, not yet a test-support boundary

Representative observed import edges:

- `scripts/test-fs2-native.py` → `scripts/fixtures/fs2_wire.py`,
  `scripts/test-fs0.py`, `scripts/test-fs0-dashboard.py`; its `Session` extends the
  FS0 session and its `Terminal` extends the dashboard PTY driver.
- `scripts/test-frontend-composition.py` → `scripts/synthetic-flow-demo.py` →
  `demo/synthetic_flow/http_client.py`, `provider.py`, `simulation_provider.py`.
  The demo mutates `sys.path`; composition then imports `http_client` by name.
  `Screen`, wait/status normalization and PTY/cell-oracle code live in the test
  entrypoint and are reused by other tests.
- `scripts/test-development-session.py` → `scripts/test-fs2-native.py` and
  `scripts/test-fifo-testing.py`; the new workflow script imports that session
  harness. FIFO also imports `scripts/test-synthetic-testing.py` for terminal support.
- `terminal/test_endpoint_prompt_native.py` →
  `scripts/test-resource-inspector.py` (`native_setup`) and
  `scripts/test-fs0-dashboard.py`; `terminal/test_standard_plan_recovery.py`
  imports the endpoint module's `ROOT`/loader.
- `terminal/test_waveform_handoff_pty.py` and
  `terminal/test_waveform_mixed_rows_pty.py` → `scripts/fixtures/fs2_wire.py`;
  `terminal/test_development_waveform_pty.py` imports mixed-row replay and native
  harness support.

These `importlib.util.spec_from_file_location`, `Path(__file__)` parent/sibling
lookups and `sys.path` changes encode locality. A file move can break imports,
fixture copying, subprocess script paths or default binary roots while OCaml
library dependencies remain unchanged. Loading a helper executes its top-level
imports; it is not equivalent to running the imported script's main acceptance.
Conversely, standalone imports are not automatically tracked by Dune. Existing
registered Python actions show Python can be tracked when dependencies and helper
executables are declared; opt-in scripts need their transitive inputs recorded
explicitly in any future registration.

## 6. Candidate suites and locality recommendation

1. **WB-only contracts/state:** protocol/provider conformance, adapter invocation,
   project integration, setup inline, waveform/time and workspace reducers. Use
   existing local registration; these are strong fast-suite candidates.
2. **WB-only controlled integration:** backend fake-provider tests, daemon RPC,
   terminal prompt/handoff/evidence tests, registered preference restarts; then
   individually admitted synthetic HTTP/PTY entrypoints using explicit prebuilt
   binaries and private state. Keep nearest composition owner.
3. **WB-owned install/hardware specimens:** cross-app installed-application fixture
   flow and standalone Cyclesim counter, separately selectable from fast contracts.
   Builds/installs/simulations are explicit costs. Existing hardcoded six/twenty-job
   wrappers require a later bounded execution decision; this inventory runs none.
4. **Pinned external integration:** FIFO/PT.8, development launcher/router/capture,
   real-example/provider and retained external inspector routes stay deferred
   during example refactor. Later admission must identify immutable inputs and
   distinguish read-only replay, simulation, source preparation and real EDA.
5. **Qualification/evidence utilities:** explicit synthesis/physical/finalization
   producers and runtime observers remain opt-in. Preserve exact receipts and
   unverified scope; do not fold them into a cheap default suite.

A later `test_support` boundary could extract native HTTP/wire transport,
owned-process/private-runtime setup, PTY input/resize/capture and ANSI-cell oracles.
Start with one helper and a small set of consumers, preserve historical receipts
and entrypoints, and verify import/fixture closure before the next batch. Keep
scenario assertions and hardware-specific providers with their composition owner.
This is a locality direction, not a big-move plan or authorization to register
every historical probe. The main owner retains the bounded plan, root READMEs and
existing documentation queue.

For any later approved execution in this shared work period, use explicitly
coordinated cost, the appropriate shared build locks and `-j2` for actual builds;
historical `-j6`/`-j20` script contents are inventory findings, not approved limits.
No owner daemon adoption or EDA activation follows from this catalogue.
