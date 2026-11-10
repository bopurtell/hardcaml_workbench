# Workbench tool-test entry points

Tests are mostly **owned by their subsystems**, not collected as source files here.
This directory is the suite index, shared test support and fixture/baseline storage. The
application's **Testing workspace** runs project-declared cases; that is a different
thing from the tests of Workbench itself.

Start with [the testing guide](../docs/testing.md),
[source inventory](../docs/testing_inventory.md) and
[tool-tests versus hardware verification](../docs/testing_strategy_status.md).

To continue restructuring in another session, use the
[cached test-refactor handoff](../docs/migration_guides/workbench-test-refactor.md),
starting with the [overall checkpoint](../docs/session_checkpoint.md).

## Select existing suites

| Root alias | Existing owners selected | What it means |
| --- | --- | --- |
| `@test-contracts` | protocol, provider, project integration, adapters | Wire/config/argv contracts and controlled runner tests |
| `@test-presentation` | terminal, workspaces and terminal-local tests | Production parsing/state/rendering/input plus focused persistence/handoff integration |
| `@test-backend` | backend/test recursively | Service/process/cache/storage and controlled-provider integration |
| `@test-setup` | setup/test | Initialization/config/CLI/filesystem integration |
| `@test-api` | daemon/test | Native local HTTP/RPC server integration |
| `@test-support` | test/support | Shared PTY/screen helper contracts and compatibility imports |
| `@test-native-smoke` | terminal waveform handoff | Opt-in synthetic daemon/client HTTP/PTY integration |
| `@test-local` | contracts + presentation + backend + setup + support | Aggregate; **excludes API, native smoke and real EDA** |

These aliases select existing actions; they are not new coverage or "unit-only"
labels. Shared-support tests now participate in default `@runtest`; native smoke
remains opt-in. `local` describes
input ownership, not absence of subprocesses, Git fixture writes or nested builds.

Contracts, presentation and API passed forced reruns together at `-j2`. Backend
and setup each passed separately at `-j1`; support and native smoke passed with
copy sandboxing. Use the shared lock and explicit budgets. Example:

```bash
flock /tmp/opencode/workbench-pt8-build.lock \
  opam exec --switch=5.2.0+ox -- dune build -j2 \
  --build-dir _build_pt8_workbench @test-contracts @test-presentation
```

Run backend and setup separately with `-j1`: setup intentionally starts twelve
initializer processes. API tests explicitly request nested `-j1`; production
adapter defaults remain unchanged. Disposable Git fixture authoring is permitted
by the owner's clarified policy; owner-checkout staging/commits/pushes are not.
The combined `@test-local` alias has not itself been rerun or given a concurrent
resource bound. See [current verification](../docs/test_refactor_verification.md).

For either new selector:

```bash
flock /tmp/opencode/workbench-pt8-build.lock \
  opam exec --switch=5.2.0+ox -- dune build -j2 \
  --build-dir _build_pt8_workbench --sandbox=copy --force @test-support @test-native-smoke
```

## Data stays data

`test/dune` marks these children data-only:

- `fixtures/`: specimen inputs, including a separate miniature Dune project.
- `baselines/`: retained expected terminal output.
- `pt8_frontend_review/`: retained review data, not automatically active tests.

Their nested Dune files remain fixture bytes; they are not Workbench build targets.
No existing fixtures, baselines, test sources or evidence were moved in this pass.

`test/support/` now contains shared screen reconstruction and the PTY driver,
with controlled regression tests. Historical script exports remain compatible.
Future app-wide integration drivers can live under `test/integration/`; that
migration remains pending. The waveform smoke stays with its terminal owner.
