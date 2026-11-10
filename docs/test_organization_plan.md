# Workbench test organization — first bounded restructuring

2026-11-10. Written before Dune/fixture-boundary changes. Owner requests parallel
Workbench test organization while `hardcaml_asic_example` verification is refactored.
That checkout, its configurations, generated outputs and hardware verification are
outside this slice. The prior real-synthesis acceptance remains paused.

For continuation after this first slice, read the grouped
[migration handoff](migration_guides/workbench-test-refactor.md) and
[cross-repository checkpoint](session_checkpoint.md). This original implementation
plan stays at its existing path; historical verification/evidence is not moved.

**First slice delivered:** [ownership/selection guide](testing.md),
[root test index](../test/README.md), [inventory](testing_inventory.md) and
[actual selector verification](test_suite_selection_verification.md). Contracts
and presentation actions were forcibly rerun and passed; the other groups remain
explicitly unexecuted in this slice. Independent source review found no selector/
fixture-boundary/documentation blocker. No file migration or example execution.

## Ownership model

Use the smallest component that owns the behavior or composition contract:

- A module's invariants, codec/parser/reducer tests: inline or in its subsystem's
  `test/` directory, consistent with surrounding Dune conventions.
- Integration owned by a component (for example backend cache + provider adapter):
  that component's tests. Integration does not automatically mean root-level.
- Composition spanning independently owned client/transport/daemon/provider pieces:
  repository-level integration/acceptance entry points, currently often `scripts/`.
- Common fixtures, fake providers, HTTP/PTY clients and assertions: reusable
  test-only support with no production dependency on the tests. Extract small
  modules later; do not mechanically import other acceptance tests as a framework.
- Hardware DUT verification stays project/provider-owned. Workbench asserts the
  tool contract using stable fixtures and separately selected real-project checks.

Test the meaningful contract/risk combinations, not an exhaustive N×M cross-product
of every implementation. Use focused pairwise/cross-layer tests, boundary and
failure cases, plus a small number of complete workflows. Case counts and exact
test placement are implementation organization, not proof of coverage.

## Exclusive first slice

| Owner | Scope | Acceptance |
| --- | --- | --- |
| A | Root `dune`, new `test/dune` suite aliases; inspect/exercise selected aliases and data boundaries | Additive suite selectors over existing actions, archived fixture projects stay data-only, current default runtest behavior unchanged |
| B | New `docs/testing_inventory.md` | Representative exact locations/runners/registration, example-sensitive paths and shared-helper dependencies clearly identified |
| Coordinator | Plan/queue, root test README and ownership/developer guide, review | Explain current vs proposed layout, validate preservation and publish commands/limitations |

Do not move existing test sources, fixtures, Python scripts or retained review
evidence. Preserve all current tracked/untracked/staged source and paused evidence.
This is discovery and entry-point organization, not a broad rewrite or an assertion
that the whole external-tool dependency graph is audited.

## Suite and fixture-boundary contract

Currently root `(data_only_dirs test)` hides all of `test/`. To make that directory
a useful suite index while preserving its fixtures, move the data-only declaration
one level down to `test/dune`, explicitly covering existing `fixtures`, `baselines`
and `pt8_frontend_review`. Their nested Dune files remain inert fixture/evidence
bytes. Add no executable tests inside those data directories.

`test/dune` declares only selectors over existing owned `runtest` actions:

- `contracts`: protocol (including production-library inline tests), provider,
  project_integration and adapters.
- `backend`: recursive existing backend/test actions (includes controlled process/
  storage and some cross-layer presentation regressions).
- `presentation`: terminal inline/local/workspace tests.
- `setup`: setup/test validation/CLI/filesystem tests.
- `api`: daemon/test real local HTTP/RPC tests, explicitly selected.
- `local`: contracts + backend + presentation + setup, excluding optional API,
  standalone native PTY, hardware-provider and EDA scripts.

Root aliases are `@test-contracts`, `@test-backend`, `@test-presentation`,
`@test-setup`, `@test-api` and `@test-local`. Names are selection groups, not new
"unit-only", "complete" or measured performance guarantees. Do not change the
existing `@runtest` registration or put real EDA on an implicit/default path.

## Verification and current constraints

Check alias expansion and that actual nested fixture targets remain excluded.
Execute only selected Workbench-owned contracts/presentation groups whose inspected
actions do not launch the independent example or real EDA. Every build invocation
uses explicit `-j1` or `-j2`, switch5.2.0+ox, `_build_pt8_workbench` and the shared
`/tmp/opencode/workbench-pt8-build.lock`. No tools outside Workbench are run.

Backend/daemon tests have known constraints: disposable test-service setup invokes
Git init/config/add/commit, and daemon RPC build tests reach a nested `-j20`
adapter invocation. Do not execute those groups under this slice's no-Git-mutation
and bounded-worker policy, or claim an outer Dune limit fixes nested argv. Inspect
their aliases without running them and document the next resource/fixture-isolation
work. Do not silently change production adapter defaults just to validate aliases.

## Later bounded migrations (not implemented here)

Once the example refactor settles, audit its provider interface and update only
the real-example test adapters/contracts affected. Register stable app integration
tests with explicit scripts/imports/binary/fixture dependencies, factor test-only
support out of copied test entry points, and move app-wide test drivers in small
reviewable batches. Keep hardware and real-EDA suites opt-in with exact external
input identities. Fix nested job budgets before promoting affected process tests
into an automatically executed low-budget aggregate.
