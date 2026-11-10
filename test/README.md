# Workbench tool-test entry points

Tests are mostly **owned by their subsystems**, not collected as source files here.
This directory is the suite index plus shared fixture/baseline storage. The
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
| `@test-local` | contracts + presentation + backend + setup | Aggregate; **excludes API, opt-in native scripts and real EDA** |

These aliases select existing actions; they are not new coverage or "unit-only"
labels. Existing default `@runtest` registration is unchanged. `local` describes
input ownership, not absence of subprocesses, Git fixture writes or nested builds.

Verified in this restructuring: contracts and presentation were forcibly rerun and
passed under the shared build lock, switch5.2.0+ox and explicit `-j2`. Example:

```bash
flock /tmp/opencode/workbench-pt8-build.lock \
  opam exec --switch=5.2.0+ox -- dune build -j2 \
  --build-dir _build_pt8_workbench @test-contracts @test-presentation
```

**Execution constraints:** backend/API/local were inspected but not run in this
slice. Backend service tests perform Git initialization/config/add/commit in a
disposable fixture. API tests reach a nested `-j20` Dune invocation; the outer
limit does not override child argv. Setup was also not executed. Do not treat these
aliases as resolving the current no-Git-mutation/job-budget policy. See
[actual verification and remaining work](../docs/test_suite_selection_verification.md).

## Data stays data

`test/dune` marks these children data-only:

- `fixtures/`: specimen inputs, including a separate miniature Dune project.
- `baselines/`: retained expected terminal output.
- `pt8_frontend_review/`: retained review data, not automatically active tests.

Their nested Dune files remain fixture bytes; they are not Workbench build targets.
No existing fixtures, baselines, test sources or evidence were moved in this pass.

Future app-wide integration drivers can live under `test/integration/`, and common
test-only libraries/helpers under `test/support/`, after explicit dependency/runner
migration. Those locations are a policy for subsequent work, **not implemented
directories or a claim that the current `scripts/` harnesses have been moved**.
