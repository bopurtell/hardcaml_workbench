# Tool tests, hardware verification and selective expensive acceptance

2026-11-06. Owner clarification and current-source assessment. This records test
boundaries and recommendations, not a claim that all proposed aliases/matrices are
implemented. The construction phase plan remains the active Workbench queue.

**Later first organization slice:** [test ownership and runnable selectors](testing.md)
now provides explicit local test groups, with actual contracts/presentation passes.
It does not register all native/EDA scripts, fix nested budgets, or complete the
external-input dependency audit described below.

## Two independent outcome axes

**Tool tests** verify Workbench/provider behavior: protocol admission, selection,
process ownership, launch/cancel/reconnect, rendering, artifact transport, identity,
cache freshness and truthful reporting. **Hardware verification** checks the DUT's
behavior under stimulus/workloads, with assertions/reference models/scoreboards.

A correct tool must faithfully display a hardware Failed outcome, preserve its
failure report and VCD, and distinguish it from a failed provider process. A failing
DUT is not automatically a failing tool test. Conversely, a DUT pass cannot prove
the correct artifact was shown, the launch button used current inputs, or restart
restored the intended execution. Record these outcomes independently.

The actual FIFO `checker=mismatch` control demonstrates this distinction: hardware
checking is deliberately Failed while provider completion and Workbench's faithful
failure transport can pass their own tool acceptance.

## Current implementation, not an aspirational complete matrix

| Layer | Existing sources / registration | Established boundary |
| --- | --- | --- |
| Wire/schema contracts | `protocol/test/dune`, provider wire/validation/conformance tests | Versioned sexp/bin_io, supported fields, invalid input/outcomes |
| Backend/API lifecycle | `daemon/test/test_rpc.ml`, `backend/test/{asic,workloads,resources,inspection,execution}`, simulation/preparation tests | Public requests, state transitions, ownership, failures/caches; many use fake providers |
| Pure rendering/state | `terminal` inline tests and focused executables, including prompt, Workloads, waveform and workspace tests | Production reducers/renderers given controlled state; no actual EDA required |
| Native client integration | `scripts/test-development-session.py`, terminal PTY scripts and new `scripts/test-developer-workflow.py` | Real client/daemon/key paths plus supporting RPC/evidence assertions; opt-in scripts, not all registered in Dune |
| Project hardware verification | Example `test/dune`, `simulation/fifo_sim.ml`, PT.8 producer/oracle and installed acceptance | Actual FIFO Cyclesim and emitted Flops/stock-SRAM functional replay |
| Real EDA qualification | Retained library/example synthesis/physical records; current developer acceptance adds a fresh synthesis gate | Evidence is exact design/provider/profile/run scoped, not proof that every current TUI endpoint was rerun |

Source-only Plan and elaboration/emission have real acceptance. The combined
FIFO/PT.8 actual-client workflow and simulation restart/reopen pass. At this
assessment the new section-1 synthesis/report/restart extension is implemented
but **not yet executed**: simulation phase passes, EDA activation remains pending.
An enabled Launch command or successful preflight does not close that gate.
Broader ASIC lifecycle/race coverage remains explicitly partial in WB-065.

## Recommended segmentation

1. Fast tool contract/reducer/parser tests.
2. Fast production rendering/input tests from deterministic states.
3. Backend and native TUI lifecycle integration with controlled providers.
4. Actual hardware simulation/provider integration on small stable specimens.
5. Explicit real-EDA endpoint-prefix tests, separately selectable by endpoint.
6. Slower release/nightly physical/finalization acceptance where that release
   scope requires it. Never silently put hour-long physical runs in the fast set.

These are recommended test families, not newly introduced Dune aliases. A single
end-to-end test cannot replace the smaller layers; direct RPCs cannot prove client
defaults/focus/input/rendering; TUI screenshots cannot prove raw artifact integrity.

The supported fresh ASIC prefix is:

```text
Elaboration (source build + bundle emission)
  → Synthesis → Floorplan → Placement → CTS → Routing → Timing → Signoff
```

Collection/reporting and external finalization/postchecks remain separately
recorded operations. Endpoint tests must cover both cheap orchestration stop-point
behavior and selected actual-tool execution. `elab→placement` includes required
synthesis/floorplan predecessors; it is not permission to skip those stages.
Macros/named checkpoints keep their documented unsupported boundaries.

For each endpoint, fast tests should verify the exact intended prefix, required
handoff, predecessor failure behavior, no later-stage launch, cancellation and
terminal state. Real runs then validate that the external tool adapter and retained
evidence actually work. The current repo does not establish a complete, uniformly
registered current-client real-EDA matrix for every endpoint.

## What Dune tracks and what it cannot infer

Dune can track OCaml dependencies and Python actions when scripts, imported modules,
fixtures and executable targets are declared in `deps`/`source_tree` and actions.
Python is not inherently outside the dependency graph. Current ASIC tests contain
many explicit Python action registrations; Workbench has both declared Python test
actions and opt-in standalone native/EDA scripts. Those have different coverage.

Dune cannot infer undeclared Python imports, live Docker daemon state, mutable
external checkouts, container tags, PATH-selected tools or state left in a provider
store. Existing explicit declarations help, but no complete audited external-input
fingerprint/selective-rerun system is currently delivered. A cached test action is
not automatically evidence that today's external execution environment was tested.

Recommended expensive-test input identity: actual DUT/bundle/config/SDC, provider
and harness code, tool/image digests, collateral and relevant runtime settings,
fixture identity and test-contract version. Use immutable snapshots/digests rather
than mutable labels. Keep scheduler/CI policy separate from evidence validity.

A small rendering change normally needs targeted rendering/state tests and a PTY
smoke, not physical implementation. A synthesis adapter change needs relevant
contract/lifecycle checks plus real synthesis smoke; it does not require a fresh
full physical run after every edit. **However, if new synthesis changes the netlist,
old routed/signoff measurements are not current-design evidence.** Releasing a
physical-qualified candidate requires appropriate downstream acceptance eventually;
choosing not to rerun an expensive test now must remain visible as unverified scope.

## Evolving verification without moving every tool-test oracle

- Keep small, deterministic contract fixtures and known pass/fail/error/partial
  records separate from large evolving design regressions. Tool tests assert
  lifecycle, associations and truthful presentation, not the current number of
  DUT assertions or arbitrary full log text.
- Use real minimal hardware specimens for integration. Broad DUT verification
  grows independently; its checker/model/workload versions remain in provenance.
- Preserve raw execution artifacts. Reader/parser/tool tests replay retained
  inputs offline without rerunning synthesis/physical tools for every reader edit.
- Version intentional contract changes and explicitly migrate expected fixtures.
  Do not edit historical failure receipts or silently relabel an old producer.
- Keep independent checking where it matters: compare actual outputs against an
  independent oracle, and cross-review changes to checkers, adapters and expected
  results. Reusing the DUT algorithm as its checker can make both pass incorrectly.
- When a test fails, distinguish a tool defect, DUT defect, intentional contract
  change, stale/invalid fixture, harness/oracle defect, and changed environment.
  Retain the failure and its disposition rather than changing the assertion until
  it passes. Test the testing helpers with deliberate mutations/negatives.

This reduces the chicken-and-egg coupling without freezing verification techniques
forever or assuming the acceptance harness is infallible. Later hardening should
make test registration, endpoint coverage and expensive-test selection explicit,
not claim Dune currently solves all three automatically.
