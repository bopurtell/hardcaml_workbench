# WB-065 bounded ASIC lifecycle matrix

Verified 2026-11-05 on `bpurtell/asic-lifecycle-matrix`, based on `oxcaml`
`2b42815`. This completes the selected deterministic matrix, supplementing the
[retained FS1 evidence](fs1_lifecycle_and_artifacts.md) and the already-delivered
failed-launcher reconciliation. It does not establish exhaustive race coverage.

## Coverage matrix

| Boundary | Prior evidence | New deterministic evidence |
| --- | --- | --- |
| Reserved but queued | Persistent reservation and same-key deduplication | Cancel queued finalization behind gated producer: zero launches for cancelled key, captured run retained, active producer unaffected |
| Started, allocation unpublished | Owned process cleanup | Cancel before allocation; interrupted reservation cannot relaunch on same-key retry |
| Allocation during cancellation | Exact allocation capture | Late allocation retained without resurrection; queued replacement gets its own attempt and survives repeated old-key cancellation |
| Collection / client detach | Real FS1 collect and detach | Independent HTTP clients share one submission; submitting socket closes before accepted response; retry retains allocation and conflicting inputs fail |
| Postcheck cancellation | Real FS1 `wtprmfgc`: interrupted receipt, failed task, not-evaluated acceptance | Gated postcheck preserves run/execution/attempt/phase; earlier adopted terminal summary survives |
| Failed launcher / final observation | Existing reconciliation fixtures and recovered real incident | Existing regression suite rerun; delivered fix unchanged |
| Read-only reconnect | FS1 restart without replay | Restored service is unowned; concurrent HTTP observations coalesce; newer decoy directory cannot retarget inspection |
| Reader cancellation / shutdown | Ownership contract | Successful JSON emitted during termination cannot complete cancelled task; shutdown joins exact reader while original producer stays active; unrelated sentinel survives |
| Receipt identity | Hash and exact-reference validation | Ten mismatches rejected: operation ID, execution request/hash/attempt, accept flag, five acceptance inputs; valid reconnect clears observation error but retains producer error |
| Completion after detach | Real collect/accept verdicts | Producer completes naturally; third service imports same operation/results path read-only; completion and not-evaluated acceptance remain distinct |
| Late frontend response | View generation, artifact tickets, host lifetime | Production receipt callback rejects stale success/error after A→B→A, reconnect and tile recreation with reused counters; current error remains visible |
| Concurrent artifact pages | Distinct offset/limit, eviction/retry, attempt/hash, stale-ticket fixtures | Baseline retained and full suite rerun |

## Implementation

- `backend/test/asic/test_asic.ml`: `finalization_cancellation_matrix`.
- `backend/test/asic/fake_provider.py`: private FIFO producer/reader gates and
  termination markers. Rendezvous establishes ordering; snapshot polling waits
  for publication rather than using elapsed sleeps to choose a winner.
- `daemon/test/test_asic_clients.ml`: HTTP against in-process RPC services,
  including a held response after dispatch. See [transport details](../daemon/test/WB065_COVERAGE.md).
- `terminal/evidence_session_test.ml`: focused production callback-seam tests.

Two demonstrated defects were fixed in `backend/asic_service.ml`: queued
finalization and read-only observer pending records now capture their run when
scheduled. Exact keys, allocations, ownership and final-observation behavior remain
intact. Backend and transport/test implementation ownership was partitioned between
agents; frontend edits are confined to the evidence-session test file. No frontend
production or shared `hardcaml_asic` / `hardcaml_asic_example` files were changed.

## Verification

Commands ran serially through `./scripts/with-switch.sh`, with exclusive Dune
allocation of at most five jobs:

| Command | Result |
| --- | --- |
| `dune runtest -j5 backend/test/asic --force` | PASS |
| `dune runtest -j5 daemon/test terminal` | PASS |
| `dune build -j5 @lint` | PASS |
| `dune build -j5` | PASS |
| `dune runtest -j5` | PASS, full suite |
| `ocamlformat --check backend/asic_service.ml backend/test/asic/test_asic.ml daemon/test/test_asic_clients.ml terminal/evidence_session_test.ml` | PASS |
| `dune build -j5 @fmt @lint` | Formatting failed; changed OCaml files subsequently formatted and checked, lint independently passed |

`git diff --check` passed. Initial transport compilation found deprecated
`Ivar.fill` and a missing summary annotation; both were corrected. Global formatting
also reports baseline differences in untouched files, including resource backend
tests, `terminal/main.ml` and `terminal/workspace_host.ml`; these were not promoted.

## Remaining limits

- No fresh EDA/container/acceptance campaign; real-tool claims remain limited to
  retained FS1 specimens.
- Reconnect uses persisted state with the original owner alive, not OS-crash,
  power-loss or arbitrary persistence-failure simulation.
- HTTP coverage is collect-only; backend gates and prior real evidence cover
  postcheck cancellation. Frontend additions exercise callbacks, not a new
  PTY/Bonsai event-loop session.
- Replacement cancellation uses distinct keys on the same run; cross-run selection
  fencing is tested separately through frontend callbacks.
- No exhaustive pipe-drain, timeout/escalation, every physical-stage boundary,
  high-volume concurrent-client or filesystem-failure permutations.
