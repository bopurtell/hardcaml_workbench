# C final independent acceptance — PASS

2026-11-05. Both reported production findings are independently verified corrected.
**No remaining blocker or definite issue found in C's assigned waveform/native
integration scope.** C made verification scripts/probes/review notes only. Owner
stable user store and live pairs remained untouched. EDA allocation0 throughout.

## Final receipts

| Gate | Receipt | Result |
| --- | --- | --- |
| Original adversarial waveform review | `/tmp/opencode/development-c-waveform-deep-04/receipt.json` |86/86 checks, no findings |
| Complete production native workflow | `/tmp/opencode/development-c-native-09/receipt.json` |PASS, no continuation/xfail option |
| Independent raw evidence/oracle audit | `/tmp/opencode/development-c-native-audit-09/receipt.json` |PASS, `native_acceptance_passed=true` |
| Post-native repeat/rollback/refresh preservation | `/tmp/opencode/development-c-refresh-04/receipt.json` |PASS,93 durable state files and2 client preference files preserved |
| Extended source-drift/status/invalid-option controls | `/tmp/opencode/development-c-refresh-05/receipt.json` |PASS, same real histories/artifacts/preferences preserved |

All earlier failed and blocked receipts, including native08, and their exact app
generations remain intact. No retained receipt was rewritten to passing.

## Independent correction verification

The original deep-03 `clock-short.vcd` is byte-identical to deep-04's input
(`cmp -s` passes). It still contains five10ps periods over0..50ps. The real painted
view now says:

```text
Cursor 0 ticks × 1 ps · window 0..50
8-cycle target (clipped to trace) · inferred clk period 10 ps (view heuristic) · extent 50 ps
```

Only the conflicting generic `8 cycles` inference assertion was specialized for
this clipped control: explicit clipped target, actual50ps extent, inferred10ps
period and exact bounds are required; the separate rejection of the old achieved
eight-cycle label remains. All original event/cursor/budget/resize/reload controls
run again unchanged. Original reproductions and findings remain historical evidence.

The real FIFO child's original `text/x-vcd` metadata now admits the actual native
artifact through the production palette. No MIME rewrite or replay fixture was
substituted. Actual FIFO seeded waveform opened, showed inferred clock periods,
and retained cursor40/filter `outputs.occupancy` after PT8 investigation without
cross-case contamination.

## Complete native workflow

`native-09` starts the actual B `daemon` and `client` launchers against C's private
fixed editable project `/tmp/opencode/development-c-store-02/project`.

- Same session discovers exact FIFO-then-PT8 union. Actual UI catalog/forms launch
  directed+seeded FIFO normal and mismatch, preserving maxuint64 seed, checker and
  cycles64. Both real cases pass normally; mismatch is semanticFailed/exit0 with
  injected native assertion reports. Normal/mismatch DUT VCD bytes agree.
- Both PT8 positive cases launch through the actual UI with fixedseed34097.
  Hash-bound VCD/JSON transport, exact selected-case result handoff and actual
  Flops/Exact comparison produce seven comparable zero deltas.
- Actual PT8 Default shows80ns. Fit displays inclusive0..13070000 ticks/13.07us;
  real PTY resize120x40→180x55→80x24→120x40 keeps those exact bounds. Cursor2595000
  shows13C6 (`0001001111000110`); `l` moves one original tick to2595001.
- Returning to FIFO preserves its original investigation pin/navigation. Restart
  keeps exact prior attempt set, shared workspace, captured inputs and artifact
  metadata/bytes. Actual restarted client restores Stacked display and reopens
  retained PT8 with exact response. Normal same-case metadata hydration is checked
  against original attempt/case/digest/size.
- After restart, real UI targeted rerun of FIFO seeded mismatch creates a fresh
  job/attempt with exact immediate parent and original inputs. It remains semantic
  Failed/exit0, and independently audited VCD bytes equal the parent's seeded trace.
- Standard/balanced/synthesis normal source-only Plan and physical-intent staging
  pass. Preparation is Available. Actual current-source build and elaboration-only
  bundle emission complete through the captured two-job shim, with private bundle
  and no physical run/reference. Build/emission logs and workflow are retained.

The read-only audit independently checks both PT8 same-execution ledgers, every
result/simulation/stimulus/trace/model reference's size/hash,1307 raw trace rows
per case and the memory oracle (525reads/262writes/2083defined observations). It
also rechecks FIFO normal/mismatch evidence and exact post-restart rerun linkage.

Post-native refresh controls operate only after C's daemon is stopped. Repeat
prepare preserves source/state; `status` explicitly flags C's edited FIFO source;
stale simulation rejects before child events/artifacts with actionable refresh;
an invalid prepare flag rejects without changing source/selection; failed build
rolls back selection; explicit refresh captures the actual edited private source
and preserves all real histories/artifacts/preferences; held state lifetime lock
blocks switching. Prior generations remain retained.

## Final app provenance / B handoff

Tested native immutable generation:
`/tmp/opencode/development-c-store-02/generations/df99bf701e6b49d3ac8b3985a774239b`.
Prepared only after explicitly refreshing the stopped private store. App-pair
capture follows a successful matching-main build under the shared Workbench lock.

| App | Independently verified SHA256 for B's final capture |
| --- | --- |
| client | `896cee9b6546be5c5d7fcd132306a55cf33cbc43d1c25edbd7cea9c467bd7a42` |
| daemon | `ec0108fd3ae65ac8bc8113462bfc1eb4dcdcbecf6410c144fbc982113f495a38` |

Tested generation manifest SHA256:
`fd43eb0a4ce7e525a4ac6115c9f3bbfcf9004baee532e5202d3580940b423947`.
Native run confirms configs, apps and complete immutable capture unchanged during
execution. Later explicit private refreshes retain the tested generation and all
native attempt evidence. B owns capturing this final pair into the stable user
store; C has not mutated that store.

Final deep-review source/probe SHA256:

| File | SHA256 |
| --- | --- |
| `terminal/waveform_time.ml` | `e44d50630c3c6840a62c3ee567cf87eaeac4b95ad0e49ac8ee9251108a725921` |
| `terminal/waveform_data.ml` | `5c580249a0e0be20ece375f0dc1a8ef647011bf1e3e1ffbbd72590ebd1eb45f6` |
| `terminal/waveform_view.ml` | `08888a15cdeb44a957790aba83e7a61e5ddb2d5e366b0665d21f659141c8c981` |
| C native review probe | `f474df00f9dd09d5b5b26636edfc8148e4db6e40d8fcbd7b6917b5e75c7e4b94` |

All Dune commands use switch5.2.0+ox, explicit root, shared appropriate locks and
`-j2`; functional workloads are sequential. No EDA or Git mutations. C's native
runner does not claim per-suite cancellation/reaping verification; Main owns the
separate B setup/cancellation/routing review. Its `untested` entries for separate
setup/provider controls are scoped to that native invocation, with C's actual
refresh and earlier direct-provider receipts recorded separately above.

## Final stable installed capture audit — PASS

2026-11-05, after B's authored-source closure correction and explicit migration.
Read-only verification of stable generation
**`26f0d5e474bc4d45b5fc5859325c162d`** passes with no final blocker found.
Its exact manifest SHA256 is
`2170d35af3be1dc350f8dd1b8a49e2cf0aecf5bdc55adea75e6d20eedf5d139c`.
The installed client/daemon hashes equal the final native09 pair above.

Final installed-capture receipt:
`/tmp/opencode/development-c-installed-audit-03/receipt.json`.
Own reproducible read-only script: `scripts/audit-development-installed.py`.
The exact textual router delta is retained alongside the receipt as `router.diff`.
All stable-store access in this audit was read-only: no daemon/client/provider/setup
execution, no lifetime-lock acquisition, no writes to source/config/state/preferences.
The selected generation, full captured inventory, actual authored project bytes and
regular configs were checked for agreement and remained unchanged during the audit.

### Exact applicability to native09

- Every captured provider executable, provider runtime script, stock model, SDK file
  and two-job Dune shim is **byte-identical** to native09's tested generation,
  except the composite router file's authored inventory constants. The receipt's
  `runtime_byte_differences` is empty after separately checking that router.
- Router SHA256 changed from
  `eebd560025b972c947e0911342f068e970f5d0eec9d96a9c0effe3b799fb54e5`
  to `8685ac3b718253e27c691bfaf8115b2e15890011895c298cf193ab0638a4aad3`.
  Its only textual changes extend `SOURCE_DIRS`/`SOURCE_FILES`, introducing the
  exact four-file `ACCEPTANCE_FILES` inventory. Removing those three assignments
  yields an identical Python AST. Discovery, validation, source-drift checks,
  suite selection, untouched argv forwarding, environment and `execve` logic are
  unchanged. Final `source_dirs` metadata equals the router's constants; both
  suite guards exactly cover their declared current source paths and digests.
- The exact immutable ASIC provider path, entire external ASIC inventory/receipt
  and SDK contents agree. Normalizing only the manifest's generation/project/store
  absolute paths makes provider argv, runtime environment and all three regular
  project configs identical to the native-tested metadata.
- Added authored closure comprises66 files: ordinary `test/`, `asic_test/`,
  `timing/`, `named_timing/`, `physical_timing/`, executable `bootstrap.sh`, and
  exactly `acceptance/{dune,export_trace.ml,check_bundle.py,replay.v}`. Existing
  captured authored inputs were not removed. Common-source differences are B's
  launcher/acceptance-test migration support, router inventory metadata, and
  removal of C's exact comment-only private refresh controls from
  `lib/controlled_fifo.ml`. The compiled FIFO/provider bytes nevertheless agree
  exactly, as do every other runtime artifact compared.

These comparisons establish applicability of native09's actual FIFO/PT8 UI and
functional behavior to the installed equivalent runtime without repeating the full
real FIFO/PT8 UI workload. **Native09 remains an actual execution only of its
private generation `df99bf701e6b49d3ac8b3985a774239b`.** Its attempt IDs, source
hashes, workload results, artifact digests and absolute paths are not attributed to
the stable user generation. The installed generation's local paths, source metadata
and migration provenance are distinct and recorded as such.

### Current authored closure / ordinary tests

Independent fresh preparation from current source passed in a new private store:
`/tmp/opencode/development-c-prepare-03/receipt.json`.
The small follow-up receipt
`/tmp/opencode/development-c-capture-smoke-01/receipt.json` passes:

- Actual production daemon native Discover: exact controlled-fifo/PT8 catalog and
  all three regular configs.
- Normal standard/balanced/synthesis source Plan with matching plan identity,
  zero EDA runs/workflows.
- Actual `dune runtest --root PRIVATE_PROJECT -j2 test asic_test timing` through
  the captured shared-lock/two-job shim. Authored FIFO directed7330edges,
  seeded20017edges, wrapper directed/seeded, catalog, resolution and timing reset/
  latency checks pass. Exact command/output are retained. No PT8 workload/provider
  simulation or UI acceptance was repeated in this small smoke.

Ordinary targets were also read directly from the stable project's current
`test/dune`, `asic_test/dune` and `timing/dune`: real FIFO directed+seeded aliases,
wrapper/resolution/catalog tests and timing core test are present, with their exact
source digests matching the selected immutable capture.

### Edited source / migration failure controls

C's actual-history source-edit/status/stale-run/invalid-option/failed-and-successful
refresh preservation receipt remains `development-c-refresh-05`. B's corrected
retained12-test suite was independently inspected read-only at
`/tmp/opencode/workbench-dev-b-jzc4uvlt/store/test-evidence/`:
`result.json`, `source-import.json`, `refresh.json`, ordinary-test command/output,
and staged empty-directory/symlink collision migration receipts. The final capture
audit records their exact SHA256 references and checks their results, alongside
source review of test11/12 assertions. They show failed-build imports retain added
bytes and old selection, user test/source edits survive, arbitrary support edits
are refused, and no-replace directory/symlink races preserve staged source. Setup
rollback/crash recovery retains edited configs rather than overwriting them.
These remain B's executed tests, independently reviewed by C, not new C migration
executions. Their reviewed results and C's fresh current-closure smoke expose no
remaining authored-source or migration blocker.

All new daemon/build/test work occurred solely in C's private store03. The stable
user store was never launched or mutated; no live pair/Git/EDA action occurred.
