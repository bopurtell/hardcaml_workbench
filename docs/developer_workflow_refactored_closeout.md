# Refactored-example developer workflow — acceptance closeout

2026-11-10. **Bounded developer acceptance complete**, independently reviewed.
This supersedes the paused synthesis status in the earlier session handoffs.
It closes the example/Workbench workflow, not PT.3 Protemu adoption, physical
signoff, or independent-installation release qualification.

## What actually passed

- Fresh ownership-v1 example preparation and production daemon/client startup.
- FIFO normal/mismatch and both PT.8 cases through actual Testing launch forms;
  report/VCD identity checks, waveform investigation, A/B comparison and restart.
- Actual production TUI source Plan → preparation → synthesis submission.
- Completed native synthesis and actual TUI Finalize (collect).
- Actual TUI synthesis/report/check inspection, all six artifact byte checks,
  then same-store restart/reopen without additional producer attempts.
- Independently verified resource enforcement and exact receipt/output associations.

This is **joined acceptance evidence**, not a passing uninterrupted producer-phase
harness invocation. The producer-phase receipt failed after successful synthesis
and collection, during presentation-focus handling. It remains failed. Corrected
inspection-only and restart invocations supplied the remaining evidence without
rerunning synthesis or collection. Independent review passed 115 read-only checks.

## Exact accepted capture

| Identity | Value |
| --- | --- |
| Private store | `/tmp/opencode/developer-workflow-envelope-v1-store-04` |
| Capture generation | `acdeab22bec448f48f0245c756d4b312` |
| Manifest SHA256 | `37cd04fdb38fb2fe9bf6e4e3b81bcaac3fbb7548822a283a1aba6832d66a0eaf` |
| ASIC generation | `hardcaml_asic_example/.dev/asic-synthesis-envelope-v1/generations/36205ea4748c4972877ac198356d8e44` |
| ASIC installation receipt SHA256 | `27ebc2967f25975a6ac77d1e7059da90cf7eed5e84072175c155dbda613a0d24` |
| Daemon SHA256 | `cd024de286ba68f09477434825a354e8dcb45e1563c56fbdf63ad31432963bed` |
| Client SHA256 | `d4b2b23914bd8156fe572bd726a2c3fbdc1045dc9c834df45cf835a2c8e25b16` |
| Run | `5923d45a1ab0421b953067be5a961053` |
| Workflow | `workflow-b44fa7b29086527c0e8bfd2419e491090a28d2f8c50ec59e5e0dfdcf1bcb034e` |
| Collection | `0787c2701aa54a7bb815e570ee29db38` |

Final durable history contains exactly **one workflow, one run, one launch and one
finalization**. These are captured development inputs, not a clean-release claim.

## Results and truthful limits

Synthesis completed with exit0 in **11.391377 seconds** for its occurrence:

| Observation | Result |
| --- | --- |
| Mapped cells | 673 across 23 types |
| Mapped cell area | 13,041.6048 µm² |
| Recorded synthesis errors / inferred latches / unmapped instances | 0 / 0 / 0 |
| Collected metrics | 2 available, 5 unavailable |
| Report artifacts | 6, totaling 193,428 bytes |
| DRC / LVS / antenna | unknown |
| Acceptance / external postcheck | not_evaluated |

No P&R, physical qualification or Protemu execution occurred. No signoff state,
GDS or LEF was fabricated for synthesis-only collection. Restart reopened original
reports and simulation artifacts, restored supported display preferences and A/B
comparison, and performed explicit FIFO cursor/signal navigation. Cursor/filter
navigation is not claimed as durable restoration.

Source build/emission job records show completed exit0. Their original log reads
returned `Invalid_request: invalid log read bounds`; they are **not successful raw
source-job logs**. This nonblocking harness-evidence limitation remains a follow-up.

## Resource enforcement and monitor correction

The opt-in `HARDCAML_ASIC_SYNTHESIS_TASK_LIMIT=6` enforces **six total container
Linux tasks**, including controllers, through Docker's PID cgroup. This is stronger
than native-thread≤6 but reduces usable executor concurrency. It is not merely a
CPU-quota claim. The profile is synthesis-only; incompatible routes reject.

The final observer completed successfully across four serial containers: metadata,
execution, and two publication/collection validators. Thirteen kernel observations
confirmed `pids.max=6`; observed maximum was6 with `pids.events max 0`. Sampling
observed two native OS threads/processes and three Python threads. Of 2,500 samples,
four were explicitly partial terminal/removal transitions; their native counts are
null, not zero. Sampled peaks are observational, not exhaustive scheduler proof.

The first attempt exposed a real observer defect: an already-exited `removing`
container with PID0 was treated as live. The correction recognizes confirmed exit,
uses bounded exact-ID reinspection for live-root races, rejects identity/restart/
configuration changes on every path, and preserves coverage gaps. Independent
review found and corrected a restarted-terminal edge case. All 69 controls passed.

## Evidence index

All paths below are under `/tmp/opencode/`; they are local temporary evidence,
not a durable committed archive. Recheck existence and hashes after a reboot.

| Receipt | SHA256 |
| --- | --- |
| `developer-workflow-envelope-v1-simulations-03/receipt.json` | `fabf82cde1d11012771da40a4945a17720b7125bc5ed4ae5e44cac963f65686b` |
| `developer-workflow-envelope-v1-execution-04/acceptance-closeout.json` | `3cd6ad7e469a2ed50b342093ac4ea490032d637e03529500d6e7068b318bcdd7` |
| `developer-workflow-envelope-v1-inspect-04-05/receipt.json` | `cb03b6931ea3aa58f68905dffa54c02717cd1d7b7b9e9fb911aa1859b569c277` |
| `developer-workflow-envelope-v1-restart-04-02/receipt.json` | `6a493d3adad9d334d6fc946120ea1b1217f21c61afa7130c5fb051073a4dbf24` |
| `developer-workflow-envelope-v1-watch-04/summary.json` | `7374185fc9ad42818fa9953bf8312c7bf8b01cfc65a7e23e8033408b6b505a78` |
| `developer-workflow-envelope-v1-synthesis-04/receipt.json` (original failed harness) | `1f6a73eebf805a2c977941651db6bba987122c653a3aed2541334c732e1ad473` |
| `developer-workflow-final-independent-review-01/receipt-1794351072498546092.json` | `d34ef4a9b312781adeb841e5b50e1e86dcf5b27aecb270e5f2421e9f2354cfd1` |

Simulation prerequisites passed 125 native plus26 workflow assertions. Final
acceptance contract controls passed56 tests. Independent audit verified all six
artifacts, 33 sealed producer files, and 535 baseline-listed prior-store files.
Actual PTY actions and supporting RPC reads/refreshes remain separately recorded.

## Implementation and external changes

- **Workbench:** ownership-v1 admission, exact source closure and phase identities;
  guarded monitor/cap handshake and correct cancellation ownership; robust observer;
  explicitly capability-gated synthesis collection; strict inspection-only
  continuation and restart verification. Focus checks use actual zoomed tile identity.
- **ASIC:** optional transport task cap throughout the synthesis route, validated
  synthesis envelope, public collection capability, and synthesis-only collection
  from real checkpoint/netlist/metrics. Default physical behavior is preserved.
- **Example:** captured opt-in configuration retained across refresh, explicit
  app-only recapture support, and installer exclusions for known private build roots.
  App-only recovery was tested but not used for the accepted store04 journey.

Old installations/captures and failed attempts remain intact. Owner preservation
checks cover selected manifest, root companions and discovery, not every history
file. No owner session was adopted/restarted, no Git staging/commit/push/authorship
changes were made, and no test-owned processes or containers remain running.

## Next work

Main PT.0–PT.8 library/example workflow acceptance is now closed at this scope.
PT.3 Protemu adoption remains separately pending. General test-refactor/coverage
expansion remains [backlogged](backlog/tool-test-flow-coverage.md). Before adopting
the new capture for everyday use, choose a deliberate persistent store using the
[example continuation guide](../../hardcaml_asic_example/docs/migration_plans/workbench_continuation.md);
the owner's legacy store was not migrated by acceptance.
