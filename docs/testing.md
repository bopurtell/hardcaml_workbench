# Testing Workbench: ownership, suite selection and integration boundaries

2026-11-10. This guide is about **tests of the software tool**. Workbench's Testing
workspace executes project-defined tests and hardware verification; see
[Testing controls](testing_workspace.md) for that separate user workflow.

The next-session continuation plan is
[cached under migration guides](migration_guides/workbench-test-refactor.md).
Read [the session checkpoint](session_checkpoint.md) first for paused acceptance,
the independent example refactor and the authoritative feature queues.

## The hardware analogy is useful

Treat a software subsystem like an IP for test ownership: the subsystem owns its
behavioral contracts and tests, while the application owns composition contracts.
Reusable test infrastructure corresponds to a common verification-agent library.
Software build/runtime dependencies replace RTL elaboration dependencies; not every
dependency creates a separate integration test or needs a full-system test.

The main rule is **put a test with the smallest owner of the behavior/composition
being asserted**. The number of modules it imports is not the deciding factor.

| Behavior under test | Natural owner/location here |
| --- | --- |
| Codec or state-machine invariant | Inline next to its module, or that library's `test/` |
| Backend service + its provider adapter | `backend/test/` if the backend owns the composition contract |
| HTTP server request/response handling | `daemon/test/` even though it uses backend/protocol libraries |
| Terminal input/state/rendering + catalog behavior | `terminal/` inline/focused tests, or terminal-owned integration |
| Whole setup→daemon→client→provider scenario | Repository-wide integration/acceptance, currently often `scripts/`; future `test/integration/` |
| DUT stimulus/model/assertions/scoreboards | Project-owned verification/provider, not Workbench's generic tool tests |
| Shared fake provider/PTY/HTTP helpers | Test-only reusable support; future `test/support/`, not production imports from test entrypoints |

For example, a cache/provider test does not move to root just because it composes
two modules. A test of the complete installed client/daemon/provider workflow does
belong at the application-integration level. Keep responsibility visible rather
than sorting every two-module test into a global folder.

## Current layout

```text
protocol/                  production code and some inline contracts
  test/                    additional codec/validation contracts
provider/test/             provider wire/runner conformance
project_integration/test/  project/config/driver contracts
adapters/test/             invocation/parsing/identity contracts
backend/test/              services, caches, processes, lifecycle and provider integration
daemon/test/               native HTTP/RPC integration
setup/test/                setup/configuration/CLI integration
terminal/                  presentation code, inline tests and focused test modules
  workspaces/              workspace definition/preset tests
  test/                    additional terminal-owned integration
scripts/                   many opt-in HTTP/PTY/installed/real-provider/EDA harnesses
test/
  dune                     index/selectors over existing subsystem tests
  fixtures/                DATA ONLY, including miniature projects
  baselines/               DATA ONLY, expected terminal captures
  pt8_frontend_review/     DATA ONLY, retained review inputs
```

OCaml `let%test`/`let%test_unit`/expect tests run through explicitly enabled Dune
inline-test libraries. They need not have filenames starting with `test_` or be
inside root `test/`. Conversely, an executable named `test_provider` or a Python
file named `test-*` is not automatically a registered test.

Previously root `test/` was wholly data-only. This first restructuring makes it a
useful suite index while retaining data-only boundaries around its existing
children. Nested fixture Dune projects still cannot become Workbench targets.
No source/file reorganization or golden-output regeneration was performed.

## Runnable selection groups

See [root test README](../test/README.md) for commands and explicit constraints.

| Alias | Selection |
| --- | --- |
| `@test-contracts` | protocol + provider + project-integration + adapters |
| `@test-presentation` | terminal tests recursively, including workspaces |
| `@test-backend` | backend tests recursively |
| `@test-setup` | setup tests |
| `@test-api` | daemon HTTP/RPC tests, selected separately |
| `@test-local` | contracts + backend + presentation + setup; API is NOT included |

These are mixed unit/contract/local-integration groups over existing actions. They
do not imply complete API or frontend coverage. `@runtest` remains as before; the
new aliases do not add opt-in scripts or real EDA to its default closure.

Contracts and presentation were actually rerun and passed in this slice. The
backend/API/local groups were not executed: existing test-service Git-fixture
writes and nested `-j20` build paths conflict with the current execution policy.
Setup was inspected only. **An outer Dune `-j2` is not proof that a nested process
uses two jobs.** The next local-runner hardening should resolve these constraints
before advertising an unattended, uniformly low-budget aggregate.

Native PTY scripts, actual hardware providers, retained external evidence and EDA
need their own explicit input/budget/registration policy. This pass did not run or
inspect the independently refactored sibling example. The existing synthesis
acceptance remains paused, and no EDA was activated by this restructuring.

## Integration is about contracts, not a complete N×M product

Tests can be organized by the composition owner and parameterized over meaningful
dimensions. Important dimensions include protocol version, pass/fail/error/partial
outcome, endpoint, case selection, artifact kind and cancellation/reconnect phase.
Use equivalence classes, boundary cases, selected pairwise combinations and known
high-risk interactions, plus a small number of complete workflows. Do not claim
exhaustive combinations merely because tests run at the application level.

For stage prefixes, cheap controlled-provider tests verify stopping at the intended
endpoint and not launching successors; explicit real-tool tests establish actual
EDA behavior. Running all real physical endpoints after a styling edit is not a
reasonable default. Conversely, avoiding an expensive run does not make its old
measurements valid for newly changed hardware or backend inputs.

## Shared support and future migrations

The current HTTP/PTY support is scattered, with some tests importing other test
entrypoints using path-relative dynamic imports. Those imports should eventually
become small test-only libraries/helpers (process ownership, isolated state,
typed HTTP client, PTY driver, assertion/receipt utilities). Production modules
must not depend on that support. Subsystem-specific builders can remain local.

Safe next steps, in separate small migrations:

1. Fix nested job budgets and fixture Git-write assumptions for affected suites.
2. Extract one shared helper at a time without changing test semantics or golden
   outputs; declare its Python/OCaml dependencies and preserve invocation paths.
3. Register a representative Workbench-only native integration smoke explicitly.
4. Move genuinely app-wide drivers to `test/integration/` with compatibility
   entrypoints where needed; keep owned integration with its subsystem.
5. After the example refactor, adapt its real-provider integration tests against
   the new explicit interface/version. Do not make all local tool tests depend on
   its evolving DUT suite. Keep actual verification outcomes separate from tool
   correctness assertions and retain historical producer/evidence identities.

These future directories/migrations are not claimed implemented. We first made
the existing ownership and execution selection visible. A universal scheduler,
automatic change-impact oracle and full external-input fingerprint system are
outside this first slice.

## References and current acceptance

- [Representative source inventory and registration evidence](testing_inventory.md)
- [Selector execution and fixture-boundary verification](test_suite_selection_verification.md)
- [Tool tests versus hardware verification; Dune/external-input limits](testing_strategy_status.md)
- [Bounded restructuring plan](test_organization_plan.md)
- [Construction queue](construction_phase_plan.md)
