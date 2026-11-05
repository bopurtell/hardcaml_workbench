# WB-065 client/reader coverage handoff

Built and verified after the parent granted exclusive shared-build budget at
`-j5`. The backend agent owns `backend/asic_service.ml` and
`backend/test/asic/{test_asic.ml,fake_provider.py}`. This addition consumes that
fixture's FIFO gates without modifying those files.

## Coverage map

| Boundary | Existing evidence | Added specimen |
| --- | --- | --- |
| Exact-key producer deduplication | Backend `finalization_lifecycle` directly invokes the service; retained FS1 harness records same-key retry | `daemon/test/test_asic_clients.ml`: independent real HTTP connections submit identical inputs while one accepted response is held; one producer call and one exact allocation; conflicting execution filename rejected over HTTP |
| Client detach before receipt | FS1 retained real-tool detach record | Close the submitting TCP socket before releasing its accepted response; independent client/retry retains the original owned task, run, execution and attempt; producer later completes naturally |
| Read-only reconnect while another daemon owns production | Backend direct-service restart/observation cases | A new RPC server/service loads the persisted live allocation as unknown/unowned; rejects obsolete daemon instance; concurrent HTTP `Observe_finalization` calls share one gated reader; all inspection argv name the original attempt despite a newer decoy operation directory |
| Reader shutdown vs producer lifetime | Backend cancellation matrix and ownership fixtures | Shut down the reconnected service with its reader held; verify the exact reader's termination marker, no producer termination marker, and the original owner's task still executing; release original gates and require natural collection completion |
| Terminal read-only reconnect | Retained FS1 restart/observation specimens | A third daemon observes the same completed attempt; terminal summary/results retain original operation ID, exact results path, physical completion, operation status and `not_evaluated` acceptance; no extra producer or physical launch |
| Late response after selection/reconnect | `inspection_view.ml`, `artifact_view.ml`, `workspace_host.ml` already test pure identity/generation rejection and basic reconnect | `terminal/evidence_session_test.ml`: use the actual `Evidence_activity.inspection_receipt` callback seam after run A→B→A and same-session reconnect; stale success/error cannot change current view or global notice; current reconnect failure still surfaces |
| Removed/recreated frontend target | Host lifetime fencing exists; pure view tests cover numeric generations | Recreate the same tile ID, exact operation and numeric generation after removal; obsolete lifetime receipt cannot publish a notice; a current-lifetime receipt is the positive control |

The FIFO rendezvous gate the producer after allocation, its automatic reader, and
the reconnected read-only reader independently. Snapshot polling is only a
publication barrier; elapsed sleeps do not determine ordering. The RPC wrapper
holds a response **after** real daemon dispatch so socket detach is unambiguous.
All filesystem/provider effects are in a private temporary fixture tree.

## Verification

The parent's initial combined run identified a deprecated `Ivar.fill` and a
missing `Asic.Summary.t` annotation in the new daemon test. Both were corrected.
The following commands then passed serially from the checkout under the granted
exclusive budget:

```sh
./scripts/with-switch.sh dune runtest -j5 daemon/test
./scripts/with-switch.sh ocamlformat --inplace daemon/test/test_asic_clients.ml terminal/evidence_session_test.ml
./scripts/with-switch.sh dune runtest -j5 daemon/test terminal
./scripts/with-switch.sh dune build -j5 @daemon/test/lint
./scripts/with-switch.sh ocamlformat --check daemon/test/test_asic_clients.ml terminal/evidence_session_test.ml
git diff --check
```

The daemon test alias supplies the fixture's declared dependency and working
directory, and includes the existing RPC regression suite. Only the two owned
OCaml test files were formatted. The backend matrix and repository-wide checks
remain the parent's verification scope.

## Explicit gaps / limits

- These are injected-provider transport and pure frontend callback-seam fixtures,
  not new real EDA/container/postcheck runs or an exhaustive race matrix.
- The reconnect specimen keeps the original owner alive while constructing a new
  observer from persistent state; it does not simulate an OS crash. Actual restart
  evidence remains the retained FS1 harness and backend restart tests.
- The transport scenario is collect-only. Acceptance verdict and cancellation at
  allocation/postcheck boundaries belong to the backend agent's gated matrix and
  existing FS1 collect/accept/cancel evidence.
- Existing artifact offset/limit, hash/attempt, eviction/retry and stale ticket
  cases were intentionally reused as baseline rather than duplicated.
- The terminal tests call the existing production receipt seam; they do not drive
  the Bonsai event loop, a PTY, or browser/frontend production code.
