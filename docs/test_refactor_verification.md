# Tool-test refactor: bounded execution, shared support and native smoke

2026-11-10. Continuation of the first selector-only slice. The construction plan
remains the active queue. No sibling repositories were changed or executed.

## Delivered

- `Dune_adapter.action_invocation ?jobs` validates positive explicit budgets for
  Build and Test. Production default remains 20; RPC tests request one nested job.
- RPC tests exercise successful Build and deliberately failing Test, retained logs
  and final state. Marker assertions concatenate arbitrary transport log chunks.
- `test/support/{screen,terminal}.py` extracts the shared screen oracle and PTY
  driver. Historical FS0/dashboard exports remain compatible; FS2 imports the
  shared driver. Capture deadlines, failed-spawn FD cleanup and close/reaping have
  controlled coverage. Session daemon teardown now also bounds its post-kill wait.
- `@test-support` runs ten helper tests in a mandatory sandbox with a 30-second
  budget. It is included in `@test-local` and normal `runtest`.
- `@test-native-smoke` selects the existing terminal-owned synthetic waveform
  handoff through a mandatory sandbox. It declares apps and transitive Python
  dependencies, uses private state, and has a 180-second scenario deadline.
  Cleanup has separate bounded waits. It remains outside default `runtest`.

The smoke's seven assertions cover JSON-only waveform refusal, result-action
visibility, exact case waveform handoff, workspace pinning, late-response fencing
and cross-case exclusion. Navigation/display actions use real PTY keys; discovery
and simulation launches use supporting typed RPC. This is not UI launch-form or
hardware verification. Dune's ephemeral mode removes successful temporary evidence;
historical direct invocation retains receipts.

## Executed verification

All Dune invocations used `flock /tmp/opencode/workbench-pt8-build.lock`,
`opam exec --switch=5.2.0+ox --`, and `--build-dir _build_pt8_workbench`.

| Dune command after that envelope | Actual result |
| --- | --- |
| `dune build -j1 --build-dir _build_pt8_workbench @test-backend --force` | Passed all 15 registered executables |
| `dune build -j1 --build-dir _build_pt8_workbench @test-setup --force` | Passed inline tests, 10 initializer CLI and 6 simulation-setup CLI tests |
| `dune build -j2 --build-dir _build_pt8_workbench @test-contracts @test-presentation @test-api --force` | Passed |
| `dune build -j2 --build-dir _build_pt8_workbench --sandbox=copy --force @test-support` | Passed all 10 tests |
| `dune build -j2 --build-dir _build_pt8_workbench --sandbox=copy --force @test-native-smoke` | Passed all 7 assertions; repeated after cleanup fixes |
| `dune build -j2 --build-dir _build_pt8_workbench @daemon/test/runtest --force` | Passed after chunk-independent marker correction |

The initial backend attempt exceeded the tool's 120-second timeout during build;
the retry with a longer timeout passed. No result from the interrupted attempt is
counted as a completed suite.

Process traces for backend, setup and combined contracts/presentation/API observed
peaks of 6, 14 and 7 live descendant processes including Dune respectively. Allowing
four launcher/tracer processes gives conservative observed totals of 10, 18 and 11.
These are isolated-run observations, not OS thread caps or bounds for concurrently
running the groups. Setup intentionally exercises twelve simultaneous initializers.
Backend uses controlled provider/shell fixtures, not actual EDA. RPC child argv
was traced as `dune build -j1` for both `@all` and `@runtest`.

Trace files under `/tmp/opencode/`:

- `workbench-bounded-backend-process-retry.log`
- `workbench-bounded-setup-process.log`
- `workbench-bounded-final-process.log`

Negative controls: RPC budgets 0 and 3 reject; its supported two-job path passed
separately with `--no-build`. The smoke's one-second deadline failed as intended,
with cleanup receipts; `/bin/false` daemon and nonexecutable daemon paths failed
without surviving test processes. Mocked daemon teardown covered pre-start stop,
terminate timeout, kill/reap and final-wait timeout with log closure.

Independent source review found no blocking regression. Its chunk-sensitive RPC
assertion, sandbox enforcement and unbounded final daemon wait findings were fixed
and targeted checks rerun. Formatting and scoped `git diff --check` passed.

## Remaining boundaries

The aggregate `@test-local` itself was not rerun: its constituent groups were
verified under the distinct budgets above. Do not infer a safe concurrent bound
from the alias. Fixture/baseline data boundaries remain intact.

Broader HTTP/process helper extraction, application-wide driver migration and
compatibility with the newly refactored example are still pending. Existing
synthesis acceptance remains paused. No owner-checkout staging, commits, pushes,
or authorship changes were performed. Disposable Git fixture operations were
explicitly permitted by the owner. Existing generated build products were preserved.
