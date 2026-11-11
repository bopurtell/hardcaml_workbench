# Tool-test flow coverage and runner consolidation

Status: **Backlog / deferred by owner** (2026-11-10).

**Bounded reactivation, 2026-11-11:** the owner requested real independent prefix
tests. [The pyramid runner](../real_prefix_pyramid.md) now implements endpoint
selectors and an opt-in serial aggregate, with actual Elaboration/Synthesis passes.
Later physical rungs and the full pyramid remain explicitly unrun. Broader test
refactoring/coverage in this note stays deferred.

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

## Workbench-owned real-tool regression specimens

**Owner-requested backlog addition, 2026-11-11; deferred, not activated.** Expand
full-tool regression coverage using one or a small set of self-contained ASIC
specimens owned by Workbench. A Workbench checkout must be testable without
`hardcaml_asic_example` existing alongside it or supplying private setup helpers.

### Ownership and scope

- Keep specimen source, project declarations, required verification inputs and
  fixture-specific expectations within the Workbench repository. Choose small
  representative designs for concrete tool contracts rather than duplicating the
  entire example project or creating an exhaustive design/endpoint cross-product.
- Keep orchestration, HTTP/PTY clients, provenance handling and receipt validation
  in Workbench-owned test support. Remove implicit requirements such as a consumer's
  `scripts/workbench_git.py` from the generic runner.
- Exercise real source build/emission, simulation where applicable, fresh physical
  prefixes through signoff, result/report inspection, and retained-state reopening.
  Include meaningful rejection/failure/cancellation cases and exact stage-stop checks.
- Declare compiler, installed ASIC provider/SDK, EDA tools and PDK as explicit
  external dependencies. Independence from a sibling source checkout does not imply
  vendoring those tools or claiming dependency-free physical execution.
- Keep actual `hardcaml_asic_example` adoption tests separate and explicitly selected.
  They may reuse generic Workbench support, but should not supply the default tool
  regression specimen or be a prerequisite for Workbench's own tests.

### Runner and configuration experience

- Reuse the existing opt-in pyramid selectors where appropriate, replacing their
  example-coupled default setup with Workbench-owned specimens and support.
- Separate portable specimen definitions from machine-local tool paths. Allow a
  conventional ignored local configuration file so repeated commands need no long
  environment-variable assignment; retain explicit config overrides.
- Keep endpoint selection independent of machine configuration. Real EDA, signoff,
  and full-pyramid runs remain explicit opt-in actions, excluded from ordinary
  `runtest`/local aggregates. Full pyramids run serially under stated budgets.
- Record which behavior each specimen establishes, actual executed results and
  limits. A registered test or an old retained physical run is not a fresh pass.

### Acceptance when activated

1. In an environment where the sibling example checkout is absent, Workbench-owned
   discovery/build and selected real-tool regressions run using only their declared
   installed dependencies and repository-owned specimens.
2. No generic runner imports, generated config paths or source inventories silently
   reach into the sibling example, its `.dev` stores or its setup scripts.
3. Document a coverage matrix linking specimens to workflow segments, physical
   prefixes, complete journeys, failures and restart behavior; retain exact receipts.
4. Verify default-suite exclusion even when real-tool configuration is present;
   missing dependencies/configuration produce actionable diagnostics.
5. Preserve external example acceptance as a distinct integration target and record
   which expensive endpoints/full pyramids were actually executed.

Current gap: `test/integration/pyramid/configure.py` reads the example's prepared
main installation, the selected specimen is its source tree, and the runner's Git
isolation currently consumes its dispatcher. The new pyramid provides useful real
acceptance coverage but does not yet satisfy the repository-independence goal above.

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
completion. PT.3 consumer adoption remains separate. Developer synthesis/collection
and restart acceptance has since [closed at its recorded scope](../developer_workflow_refactored_closeout.md);
this broader regression expansion is not a prerequisite for that closeout.
