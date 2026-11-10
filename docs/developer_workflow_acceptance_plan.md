# Developer workflow acceptance — section 1 closeout

2026-11-06. Written before acceptance-harness implementation or new EDA. User
authorized startup, FIFO verification, PT.8 comparison, a fresh synthesis run,
report/check inspection and restart/reopen as one bounded acceptance slice.

## Acceptance contract

Use the production stable development launcher with one new TEST-OWNED fixed store,
not the owner's `.dev/workbench-development` state. Preserve all existing staged,
modified, untracked and retained work, configured providers and live daemons.
Capture actual source/app/provider/tool identities and all failed attempts.

The durable automated harness must distinguish:

- Actual production TUI key input over PTY for suite/case/form selections, launch
  confirmation, source Plan and synthesis launch, and report/workspace navigation.
- Public typed daemon RPCs for supporting state/evidence assertions and negative
  controls. An API-only launch is not proof of a TUI launch route.
- Direct library/provider/unit tests and diagnostic commands, recorded separately.

The final receipt records which path actually exercised each gate. No hand-built
RPC transcript is presented as a production-client action. Do not infer synthesis
success from elaboration, planning, metadata preflight or a visible enabled command.

## Gates

1. Prepare a source-complete private development store with corrected scoped Git,
   pinned ASIC and SDK environment and matching immutable app pair. Start its real
   foreground daemon/client; only the harness's own pair is stopped/restarted.
2. Actual Testing forms execute FIFO normal and deliberate checker mismatch, with
   genuine reports and case-bound VCD; waveform Default/Fit/cursor and provenance.
3. Actual Testing forms execute Flops/Exact PT.8 cases, inspect the exact result
   artifact, capture explicit A/B and compare seven provider-approved zero deltas.
4. Actual Plan→synthesis form→fresh staging→Launch-and-view executes current-source
   build/emission, then the exact emitted bundle through installed named synthesis.
   No P&R endpoint; no changing constraints or synthesis profile to make it pass.
5. Verify execution completion, original reports/artifact bytes, synthesis cells/
   metrics, available checks and unavailable/not-evaluated acceptance separately.
   Exercise production inspection/report controls as well as supporting public RPCs.
6. Stop/restart only the test-owned pair on the SAME store. Reopen exact simulation
   and synthesis attempts, reports/VCD/results, pins/selections and history without
   relaunching implementation. Record what is restored unverified versus refreshed.
7. Independent review after initial passing gates, including raw process/attempt/
   bundle/report association, no writes to owner history and resource-budget proof.

## Exclusive work slices

- Acceptance implementation owner: new reusable section-1 harness and receipt
  schema under Workbench `scripts/`, reuse existing native Testing/PT.8 helpers.
  Own its new private store and logs, complete startup/simulation gates, and add
  synthesis/report/restart extension. No production code workaround without a
  reproduced defect and coordination.
- Runtime/EDA owner: inspect exact pinned synthesis runtime, admission and tool
  limits, implement verification-only resource monitoring and execution checks;
  new synthesis launch only after coordinator activates the allocation below.
  No separate competing physical run or duplicate synthesis launch.
- Coordinator: plan/queue, actual allocation, orchestration, independent review,
  source changes agreed on findings and final completion/limitations.

## Explicit allocation and justification

A fresh synthesis is justified because the ordinary Workbench path has not yet
completed one in the unified developer acceptance. Retained historical runs and
metadata-only preflight cannot establish this gate.

The immutable installed provider uses a SIX-worker segmented bridge and Docker
transport. It has no supported two-worker control; Docker quota-only rewriting
would not reduce its internal six-worker executor. **Use the supported six-worker
ceiling for this one synthesis**, not a new scheduling/API project or a modified
unattributed bridge. The sole endpoint is synthesis; no P&R is authorized.

Global maximum20 includes other sessions. Before activation confirm no competing
EDA/build jobs and no running flow containers; only one acceptance EDA workflow
may run. While it runs, stop this session's Dune/functional/other native workloads
and reserve the other14 slots for unrelated sessions. Record requested/effective
Docker quota, executor limits, tool commands and observed native process/thread
usage; monitor competing work and stop the acceptance run if the shared ceiling
would be exceeded. If the runtime cannot establish the six-worker ceiling, do not
silently treat CPU quota as a thread limit: diagnose and bound the concrete gap.

All setup/test Dune commands use switch5.2.0+ox, explicit `-j2` or lower, private
`--root` and build dirs, and shared checkout locks:
`/tmp/opencode/workbench-pt8-build.lock`, `/tmp/opencode/example-pt7-build.lock`,
`/tmp/opencode/asic-pt7-build.lock`. Finish needed builds before EDA activation.
Metadata/functional checks run sequentially outside that EDA interval. No Git
add/commit/amend/push/config writes, existing-provider adoption, user-daemon
restart, tool/PDK checkout edits or original-evidence rewriting.

## Exit

Rerunnable automated test and independently checked retained evidence pass all
gates, or clearly record a concrete blocker rather than claiming completion.
Synthesis acceptance remains `not_evaluated` where the provider says so; successful
synthesis is not timing/physical/signoff acceptance. No Protemu or new PT.9 scope.
