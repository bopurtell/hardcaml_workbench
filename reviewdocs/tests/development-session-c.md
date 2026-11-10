# C — isolated unified development verification

Current result: **PASS**. Corrected waveform review86/86; complete native09 without
continuation/xfail allowances; strict raw closure/oracle audit09; actual-history
post-native refresh04 and extended drift/status/invalid-option refresh05 all pass.
See `development-session-final-c.md` for exact receipts and final app/source hashes.
No remaining blocker or definite issue found in C's assigned scope. Earlier failed
and blocked receipts below, including native08, remain intact.

2026-11-05. Initial harness ready; integrated execution awaits B's prepared private
store/root contract and final A/B code/apps. No passing native receipt claimed yet.

`scripts/test-development-session.py` uses existing native HTTP/PTY support and the
actual production terminal. Requires prebuilt matching apps and a private prepared
project inside a store beneath `/tmp/opencode`. It creates its own daemon state,
discovery, HOME, client preferences and artifact evidence. It launches no build or
EDA. B: please expose `--store /tmp/opencode/...` (or equivalent) for prepare and
refresh, including a private editable project root; never point this at the owner
stable session. App capture must follow the final Workbench build.

Initial acceptance coverage: same-session two-suite discovery; actual form FIFO
directed+seeded normal and checker mismatch; exact uint64 inputs and assertion/VCD
transport; PT8 flops256+exact256 actual form launch and VCD/JSON transport; useful
default waveform, full Fit and exact cursor; return to preserved FIFO pins; daemon
restart history/artifacts/workspace/client preferences. Wire/ANSI and failed
attempts are retained. Expectations will be reconciled with documented final UI
and manifest contracts before execution, without weakening evidence semantics.

Outstanding controls: setup prepare/refresh/rollback/active lock; stale source
diagnostic; source-only standard Plan/StageFreshAvailable; actual Workloads result
handoff and seven zero deltas; cancellation/reaping; adversarial composite routing;
independent production diff review after initial passing suites. These remain
explicitly untested until recorded receipts exist.

## Harness bring-up

- CLI/import smoke passes for `test-development-session.py`,
  `test-development-prepare.py`, and `review-development-session.py`.
- B's private `--store` contract is published. Native harness now launches the
  real `workbench_dev.py daemon/client`, checks their manifest app paths/hashes,
  and retains the complete generation inventory. Standard source-only
  Plan/staging/Available preparation and actual digest-pinned Workloads handoff /
  seven zero deltas are included.
- `test-development-prepare.py --initial` prepares an unused private store;
  `--exercise-refresh` checks repeat, preserved editable source, stale-provider
  rejection, failed-build rollback, successful explicit refresh, retained histories
  and preferences, and held-state-lock refusal. Builds are sequential through B's
  locked `-j2` helper. Native execution must finish before refresh controls.
- First locked matching-main build encountered in-progress A compile errors:
  `to_waveterm` forward reference and unavailable installed `Bits.to_hex`.
  Reported to A; no production edits by C. No app readiness claimed from that run.
- Potential FIFO clock-reference mismatch (`inputs.-clock` vs exact
  `clk`/`clock` heuristic) reported to A for real-trace confirmation.

## Initial direct suites and native blocker

- Matching mains/probe subsequently built successfully with switch `5.2.0+ox`,
  explicit root, `_build_pt8_workbench`, shared Workbench lock and `-j2`.
- Initial private preparation **passed**:
  `/tmp/opencode/development-c-prepare-01/receipt.json`; private store
  `/tmp/opencode/development-c-store-01`, captured generation
  `a28671b13f3440359c765f3a16cd3abd`. Both captured app hashes matched the freshly
  built originals at preparation time.
- Independent direct provider controls **passed**:
  `/tmp/opencode/development-c-provider-01/receipt.json`. Exact real child catalog
  union; failed/invalid/oversize/duplicate child discovery emits no partial catalog;
  both exec routes preserve PID/PGID/exit/argv/request bytes; real children reject
  unknown suite, invalid FIFO uint64/duplicate case, invalid PT8 seed/unknown case
  before evidence. No simulation or builds in that control suite.
- Initial native **blocked/failed**, retained at
  `/tmp/opencode/development-c-native-01/receipt.json`. Actual B launcher daemon and
  client start; app/capture identity checks pass. `simulation Discover` fails with
  `Invalid_request (Failure "Symlink in simulation artifact path")` because B's
  config transaction uses a symlink for `hardcaml-workbench-simulation.sexp` and
  backend config capture rejects symlinks. This is a real production integration
  blocker, reported to B/coordinator. No FIFO/PT8 native passing claim yet. Config,
  app and generation hashes remained unchanged through the failed native run.

## Subsequent independent results

`reviewdocs/tests/development-session-review.md` is the current independent review
after A/B's initial suites. The source-only Plan Git-context failure is resolved
and independently retested; normal staging and actual private source build/emission
pass in `native-03`. Repeat/stale/rollback/explicit refresh/lifetime-lock controls
pass in `development-c-refresh-01`; this early store has real workspace/preferences
but has no FS2 attempt history yet. Native simulation remains blocked by the config
symlink contract.

Independent event/exact-time controls pass in
`/tmp/opencode/development-c-waveform-01/receipt.json` using
`scripts/test-development-waveform.py`: subcell pulse/dense marker, alias, X/Z,
one-point, narrow Fit, above2^53/max-int64 samples and contiguous full-span cells,
explicit projection budget exhaustion. These are synthetic controls; no actual
simulation provenance is inferred from them.

Resource budget: at most two jobs; every Dune command `-j2` and the shared
Workbench/example/ASIC locks, EDA zero. No root config, old provider/evidence/live
pair changes or Git mutations.
