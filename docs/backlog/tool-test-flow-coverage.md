# Tool-test flow coverage and runner consolidation

Status: **Backlog / deferred by owner** (2026-11-10).

Owner direction: cache the remaining test-refactor and expanded coverage work;
prioritize completion of the main ASIC **PT.0–PT.8** feature track and its required
acceptance. This note is not an active implementation queue or a new prerequisite
for every feature closeout. Targeted tests needed for active work still belong
with that work.

## Starting point

The initial refactor is delivered: explicit nested RPC build limits, shared
screen/PTY helpers, ten registered support tests, and an opt-in synthetic native
waveform-handoff smoke. Existing subsystem suites passed under the execution
arrangements recorded in [verification](../test_refactor_verification.md).

Current aliases and commands live in [test/README.md](../../test/README.md).
The [migration handoff](../migration_guides/workbench-test-refactor.md) and
[inventory](../testing_inventory.md) preserve ownership and script dependencies.
Existing whole-flow and segmented harnesses are not all registered or consolidated;
this backlog does not imply they are absent or already fully verified.

## Deferred scope

1. **Coverage matrix:** map setup/discovery, preparation/emission, launch/progress/
   cancellation, completion/failure, result/artifact inspection, and restart/
   reconnect/rerun to actual tests. Identify UI, supporting RPC and direct-helper
   actions; distinguish controlled providers, retained evidence and real execution.
2. **Segmented workflow suites:** register useful existing controlled harnesses
   with explicit transitive dependencies, isolated state and execution budgets;
   add tests for concrete uncovered contracts rather than duplicate existing ones.
3. **Complete controlled journeys:** establish a small set of actual client →
   daemon → provider → results/history workflows, including real UI launch controls
   where UI behavior is claimed. Keep failure diagnosis available through focused
   segment tests.
4. **Stage-prefix coverage:** map synthesis, floorplan, placement, CTS, routing,
   timing and signoff stop points. Separate cheap orchestration/stop-successor tests
   from explicitly selected actual-tool qualification. Avoid an exhaustive N×M
   matrix or making full physical runs a prerequisite for presentation changes.
5. **Shared support and ownership:** continue HTTP/session/process extraction and
   move genuinely app-wide drivers into `test/integration/` in small batches.
   Keep subsystem-owned composition tests local and historical entrypoints usable.
6. **External integration maintenance:** reconcile broader real-example harnesses
   with the refactored provider/case/parameter/artifact interfaces. Required PT-track
   compatibility/acceptance may proceed independently of this general cleanup.
7. **Runner/index consolidation:** provide a bounded sequential entry point and
   documented selectors for routine, segmented, full controlled, and opt-in external
   coverage. The current `@test-local` excludes API/native smoke and has not itself
   been verified as a concurrent resource-bounded aggregate.

## Acceptance when reactivated

- A maintained matrix identifies coverage, gaps, ownership and exact invocation.
- Registered suites actually execute tests and declare their full input closure.
- Segment and complete-workflow runs have reproducible results and meaningful
  failure/cancellation/restart checks, without conflating DUT failure with tool failure.
- Runner limits account for nested builds/providers and stay within the owner's
  shared 20-job ceiling; subprocess counts are not claimed to cap all OS threads.
- Real-example/EDA runs remain explicitly selected with current input identities;
  historical receipts are not promoted to fresh passes.
- Update the active construction plan only when the owner reactivates this scope.

## Priority boundary

PT.0–PT.8 means nine numbered feature entries, not nine test suites or nine physical
stages. The authoritative ASIC phase plan and Workbench construction plan own
completion. PT.3 consumer adoption and the paused actual-synthesis acceptance have
distinct remaining obligations; this deferral neither closes nor launches them.
