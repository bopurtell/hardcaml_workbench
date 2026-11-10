# Test suite selector verification — slice A

2026-11-10. Implemented against the pre-existing
[test organization plan](test_organization_plan.md). This is an execution receipt,
not a hardware/EDA acceptance result or a complete external-dependency audit.

## Source changes and selector expansion

Only root `dune`, new `test/dune`, and this receipt were edited by this slice.
Root `dune` replaces `(data_only_dirs test)` with six forwarding aliases.
`test/dune` preserves `(data_only_dirs fixtures baselines pt8_frontend_review)`.
No fixture, baseline, retained review, owned test stanza or existing source was moved.

| Root selector | Index alias | Existing actions selected recursively |
| --- | --- | --- |
| `@test-contracts` | `test/contracts` | `protocol/runtest`, `provider/runtest`, `project_integration/runtest`, `adapters/runtest` |
| `@test-backend` | `test/backend` | `backend/test/runtest` |
| `@test-presentation` | `test/presentation` | `terminal/runtest` |
| `@test-setup` | `test/setup` | `setup/test/runtest` |
| `@test-api` | `test/api` | `daemon/test/runtest` |
| `@test-local` | `test/local` | Index aliases `contracts`, `backend`, `presentation`, `setup`; **excludes API** |

The table follows the actual `alias` / `alias_rec` dependency declarations.
Protocol selection includes production-library inline tests, not only `protocol/test`.
Presentation selection includes workspace and evidence-activity tests. Backend
selection includes the corrected frontend review and its presentation build closure.
These are mixed local tool-test families, not exclusively unit tests.

There is no new `runtest` action or dependency on these selectors from `runtest`.
The existing registration remains in its owning directories; exposing the index
does not activate the three data-only children. The broad default suite was not run.

## Execution envelope

Every Dune command used switch `5.2.0+ox`, explicit `-j2`, build directory
`_build_pt8_workbench`, and shared lock `/tmp/opencode/workbench-pt8-build.lock`:

```sh
flock /tmp/opencode/workbench-pt8-build.lock \
  opam exec --switch=5.2.0+ox -- \
  dune <subcommand> -j2 --build-dir _build_pt8_workbench <arguments>
```

Test execution additionally used `--disable-promotion --force --display short`.
`--force` re-executed the selected alias actions; these results are not merely
cached success. `strace -f -e trace=execve -s 4096 -o <log>` wrapped Dune inside
the same lock and switch for each of the two test commands.

## Checks and actual results

1. **Alias discovery: passed.** `dune describe aliases ... . test` listed all six
   root selectors and all six index aliases. `test/` has no `runtest` alias.
2. **Registration inspection: passed.** `dune describe tests ...` listed existing
   owned tests, including production protocol inline tests and terminal workspace/
   activity tests, and no test under the root data-only children. This command is
   metadata inspection, not test execution, and does not enumerate arbitrary Python
   `runtest` rules as named tests.
3. **Rule inspection:** `dune rules ...` accepted all six selector names, but
   produced no rule text for alias-only queries, including a recursive contracts
   query. This is not claimed as an independently dumped alias dependency graph.
   The expansion table above was inspected from source. A recursive rules query
   for the presentation/helper executable targets and provider fixture/conformance
   targets succeeded, writing
   `/tmp/opencode/workbench-suite-selection-rules.sexp`.
4. **`@test-contracts`: passed, exit 0.** Ran production protocol, protocol test,
   project-integration and adapter inline runners; provider frozen sexp/bin_io and
   validation conformance; and Python foreground runner/process conformance.
5. **`@test-presentation`: passed, exit 0.** Ran terminal and workspace inline
   runners, endpoint prompt/catalog checks, Workloads/waveform handoff checks,
   generated frontend review recheck (45 checks, zero contract failures), navigation
   hydration/restart, presentation-preference fresh-process checks, and synthetic
   evidence-activity integration. Backend libraries were built as dependencies;
   the backend test suite was not executed.
6. **Real fixture-target negative: passed by expected rejection.** Inspected
   `test/fixtures/example_project/workbench/dune`, which declares executable
   `project_driver`. Requested this exact build target:

   ```sh
   flock /tmp/opencode/workbench-pt8-build.lock \
     opam exec --switch=5.2.0+ox -- \
     dune build -j2 --build-dir _build_pt8_workbench --disable-promotion \
       test/fixtures/example_project/workbench/project_driver.exe
   ```

   Dune exited 1 with `Don't know how to build` that target. Its executable stanza
   remains inactive within Workbench. This checks a real declared fixture target,
   not a fabricated missing filename; no fixture driver or hardware test ran.
7. **Whitespace check:** `git diff --check` passed.

The contracts and presentation execution logs are respectively:

- `/tmp/opencode/workbench-suite-contracts-exec.log`
- `/tmp/opencode/workbench-suite-presentation-exec.log`

Exact-file `rg -c 'execve\("[^"]*/dune",'` found **one invocation in each log**:
the top-level bounded build. Thus no nested Dune metadata probes or builds were
observed during either selected suite. Exact-file searches found no Git, Docker,
Yosys, OpenROAD, counter executable, application `main.exe`, sibling-example path,
`-j20`, or backend-test executable in either trace. The presentation provider is
the local synthetic evidence-activity fixture, not an external hardware provider.
Execution tracing is subprocess evidence, not a filesystem-access trace.

## Intentionally unexecuted and remaining gaps

- **Backend, API and local were not executed.** Their source alias expansion and
  existing registration were inspected only. Backend service tests initialize,
  configure, add and commit a disposable Git fixture. API transport tests reach a
  real disposable-project Dune build through the adapter's nested `-j20` path.
  An outer `-j2` does not constrain that argv. The local aggregate includes backend.
- Setup was registered and inspected but not executed in this slice.
- No default `@runtest`, standalone native/PTY script, installed acceptance,
  example checkout, actual hardware simulation, real EDA, or owner daemon was run.
- The new selectors do not repair existing nested concurrency defaults or remove
  temporary Git fixture writes. Those need a separately owned follow-up before
  executing the affected groups under the current restrictions.
- Existing tracked/untracked work was present before this slice. Git was used only
  for status/diff inspection; nothing was staged, committed, reset or cleaned.

Both executed suites passed. The fixture-target rejection is an intentional
negative check, not an unresolved suite failure.
# Subsequent verification

This page records the original selector-only slice. See
[test refactor verification](test_refactor_verification.md) for the subsequent
backend/setup/API passes, explicit nested budgets, shared support tests and
registered synthetic native smoke.
