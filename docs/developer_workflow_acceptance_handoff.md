# Developer workflow acceptance implementation handoff

**Superseded status, 2026-11-10:** see the
[refactored-example closeout](developer_workflow_refactored_closeout.md) for actual
synthesis/collection, inspection and restart acceptance. This page preserves the
old paused attempt and its interfaces. Its pre-crash temporary store/receipts are
gone; do not execute its historical resume command. Current receipts explicitly
join successful producers with separately passing read-only inspection/restart.

2026-11-10. **Phase 1 passed; paused before EDA activation.** Implements the
acceptance-owner slice in [the written plan](developer_workflow_acceptance_plan.md).
The coordinator has not activated the six-worker allocation. No fresh synthesis,
P&R, Protemu, acceptance replay or signoff has been launched by this work.

## Deliverable and current boundary

New reusable entrypoint: `scripts/test-developer-workflow.py`. It imports the
unchanged `scripts/test-development-session.py` production-launcher Session and
PTY helpers and runs that harness's actual LaunchForms. It adds:

- `--phase simulations`: optional new-store prepare, native FIFO/PT.8 acceptance,
  actual detail/provenance/report-export navigation, actual source Plan endpoint
  form and staged Launch-and-view availability, and private source build prewarm.
- `--phase synthesis`: passing same-store simulation receipt plus BOTH
  `--allow-synthesis` and a live, explicit coordinator/runtime allocation required
  before starting its pair. Uses **actual production TUI** Plan → synthesis form
  → fresh staging → Launch-and-view. There is no RPC Run/Launch_fresh fallback.
  Current-source build/emission jobs still execute through the stock workflow.
- `--phase restart`: opens its own new pair on the **same pinned store**, consumes
  the synthesis receipt's exact workflow/run/report/simulation identities, and
  performs read-only inspection/reopening without implementation submission.

The latter two positive routes are implemented but **not yet exercised**. Their
production report, check and restart assertions must be validated against the
new synthesis; they are not covered by phase-1 success or historical runs.
The synthesis route includes production **Finalize (collect)**, without
acceptance collateral, to expose the supported terminal report catalog. This is
an explicit report-collection producer operation, not just an evidence read and
not a second implementation flow. It must retain `not_evaluated` acceptance.

Each invocation creates a new evidence directory and exclusive-write receipt;
existing evidence directories are refused. A per-store acceptance lock serializes
phases. Owned foreground pairs are stopped at phase exit; their store/history/
preferences remain. SIGTERM raises an exception through cleanup/failed-receipt
writing. Functional FIFO/PT.8 producers run sequentially. No user daemon is
adopted, launched, signalled or restarted.

## Exact pinned handoff

| Identity | Value |
| --- | --- |
| Test store | `/tmp/opencode/developer-workflow-store-01` |
| Editable root | `/tmp/opencode/developer-workflow-store-01/project` |
| Private generation | `9d79963b4cd94c6190e9907a56683c9f` |
| Manifest SHA256 | `f1525b9945638cfa2c58bea363065bc86523b6abbbe7868102d98d4c38f3a8fb` |
| Owner stable capture, read-only | `a3553c69bfb940a4bedadeb345415b01` |
| Immutable ASIC | `ee3af8de9f83418b9afed9c67e473e3c` |
| SDK source | Owner capture `a3553c69bfb940a4bedadeb345415b01/sdk`, copied into the new capture |
| Captured daemon SHA256 | `ec0108fd3ae65ac8bc8113462bfc1eb4dcdcbecf6410c144fbc982113f495a38` |
| Captured client SHA256 | `896cee9b6546be5c5d7fcd132306a55cf33cbc43d1c25edbd7cea9c467bd7a42` |
| Unchanged historical harness SHA256 | `a12f2bb7dabaaf07fac4677f59a8befc29464075f03b42187da230e3286f679c` |
| New harness at handoff SHA256 | `253a40976ca417f6da2b462413cf67d519369ee40e60c2b60c6bbdb10da40fe4` |

App files are `STORE/generations/GENERATION/apps/{daemon,client}.exe`. The full
immutable ASIC path is recorded in the private manifest and command receipts;
it is the exact installed path under the example's
`.dev/asic-pt8-workbench/session-final-review-01/asic/generations/`, never `current`.
Captured source-file hashes, Workbench source hashes, actual setup/launcher path,
Git dispatcher configuration, provider commands, SDK paths and binary hashes are
recorded, rather than inferred from Git HEAD. The copied example includes the
user's current working/staged source files. No Git mutation was performed.

Owner manifest, root configuration bytes and daemon discovery bytes compare
unchanged before/after all completed invocations. The final phase-1 receipt also
checks private source, configuration and captured files unchanged. This is not a
claim that every changing owner state/log file was byte-snapshotted; the harness
never connects to the owner's endpoint or writes its store. Existing owner
discovery metadata (PID575404 / instance575404-1793925193906188456-330f524d)
remained byte-identical; this does not assert that metadata's process is live.
No pair for the new private
store remains running at handoff (`pgrep` on its exact executable prefix empty).

## Passing evidence and coverage distinctions

**Final phase-1 receipt:**
`/tmp/opencode/developer-workflow-simulations-05/receipt.json`

SHA256: `8230bf486fc4f44ec90d65f164eed967990dd1cdfff08b5e2b0a335b46fed1f6`.
It contains 30 passing additional assertions and references the unchanged passing
native simulation receipt (125 passing assertions):

`/tmp/opencode/developer-workflow-simulations-02/native-simulations/receipt.json`

Native receipt SHA256:
`17b6e5b04041836c20fc81946e34ecd4c2514a6041b89a06a0336b7ed65f8352`.
The final script's subsequent edits extend synthesis/restart and tighten resume
validation; receipts retain the exact script hash actually used for each attempt.

| Gate | Exercised path and evidence | Disposition |
| --- | --- | --- |
| Private prepare/startup | Real `workbench_dev.py --store ABS prepare --asic-generation EXACT`, recorded SDK, pinned `/usr/bin/git`; real launcher daemon/client | PASS |
| FIFO normal/mismatch | Actual Testing catalog and LaunchForms, two cases each, exact seed/parameters and explicit launch confirmation; native reports and original VCD bytes via typed API | PASS |
| FIFO reports/provenance | Production detail tile, selected seeded case, normal/mismatch exact report export; exported metadata and SHA256 checked. General FIFO reports use export, not an invented text-viewer route | PASS |
| PT.8 Flops/Exact | One actual two-case Testing form; retained JSON result references and both VCDs transported/hash-verified through API | PASS |
| Waveforms | Actual embedded graph, useful Default, full 13.07us Fit, 180×55 / 80×24 / 120×40 resize, tick2595000 binary13C6, one-original-tick step, Stacked preference; FIFO cursor40/pinned occupancy survives PT.8 | PASS |
| A/B result comparison | Actual selected-case result handoff, Capture A/B and resource_policy axis; API verifies seven provider-approved comparable zero deltas and exact original result digests | PASS |
| Simulation restart | Original harness restarts only its private pair, compares exact attempt/artifact metadata and bytes, durable workspace and navigation/pair/display preferences, reopens actual PT.8 waveform and targeted mismatch rerun | PASS |
| Source Plan readiness | Actual Plan ASIC standard / balanced endpoint form defaults to synthesis; Enter stages exact unmodified fresh source intent; actual Launch-and-view shown enabled without Enter; supporting preparation availability/API zero-workflow assertions | PASS, readiness only |
| Source compile readiness | Dune shim builds actual private editable root `bin/project.exe` before EDA; no build/emission workflow is relabelled synthesis | PASS, direct setup command |
| Fresh synthesis, reports/checks, post-synthesis restart | Implemented phased positive routes | NOT EVALUATED pending allocation |
| Resource ceiling/raw process proof | External runtime owner admission and monitoring required; no synthetic runtime proof substituted | NOT EVALUATED |
| Independent review | Separate later coordinator/reviewer slice | PENDING |

Exact accepted simulation IDs:

```text
normal:   sim-e6e5ca65937f49a060b7a9484165cd13a4cc2bcd963e7cf8986ba81f5b3ce56d
mismatch: sim-ba5d8ab6a77a3fc7c328fc4f66e6f563f8dd1d11e37dfaaccb2dfdcf7b8a3c78
PT.8:     sim-e0bbab588dfb4e0dd09d220ea07e0a7b9aad6295adbf49df1a06ded0660eb7ca
```

Retained `raw-http.jsonl` files identify supporting API calls; `pty-keys.jsonl`,
screenshots as terminal text, ANSI captures and owned-daemon metadata identify
actual client actions. The inherited native harness's API-only source Plan probe
is labelled supporting API evidence; the added production Plan form is separate.
Byte checks and setup commands are not presented as TUI launches or unit tests.

## Reproduction commands and build policy

From the Workbench checkout, new-store preparation and the complete first phase:

```sh
opam exec --switch=5.2.0+ox -- python3 -B scripts/test-developer-workflow.py \
  --phase simulations --store /tmp/opencode/NEW-UNUSED-TEST-STORE --prepare \
  --evidence /tmp/opencode/NEW-UNUSED-SIMULATIONS-EVIDENCE
```

Actual preparation/build command vectors, stdout/stderr and exit receipts are in
`/tmp/opencode/developer-workflow-simulations-01/`. Preparation completed there;
the caller timeout interrupted the later simulation segment. App build:

```sh
flock /tmp/opencode/workbench-pt8-build.lock \
  opam exec --switch=5.2.0+ox -- dune build \
  --root /home/wayne/devel/jane/hardcaml_workbench \
  --build-dir /home/wayne/devel/jane/hardcaml_workbench/_build_pt8_workbench \
  -j2 daemon/main.exe terminal/main.exe
```

The application pair is captured together under that same shared lock. The
launcher prepare uses the example shared lock, a private captured source root,
private build directory, `-j2`, and the activated switch's Dune. No ASIC rebuild
or SDK installation/refresh was needed. Prewarm uses the captured stock shim,
which takes `/tmp/opencode/example-pt7-build.lock` and forces private `_build`/
`-j2`; its command explicitly supplies the private `--root`. These setup builds
are complete before the activation boundary. A later fresh workflow's stock
build/emission are serial predecessors of EDA, not concurrent functional jobs.

Final additional inspection/readiness command (reuses the original passing
simulation evidence; launches no additional simulation):

```sh
opam exec --switch=5.2.0+ox -- python3 -B scripts/test-developer-workflow.py \
  --phase simulations --store /tmp/opencode/developer-workflow-store-01 \
  --simulation-evidence /tmp/opencode/developer-workflow-simulations-02/native-simulations \
  --evidence /tmp/opencode/developer-workflow-simulations-05
```

Use a new evidence name on any repeat; the recorded name above intentionally
cannot be overwritten. Native producer attempts from the interrupted first
invocation and the original harness's intentional post-restart targeted rerun
remain in the store's history; the three IDs above are the exact accepted gate
attempts. No history was cleaned up to make the test look empty.

## Activation contract and exact resume command

**Do not run the positive synthesis command until the coordinator explicitly
activates the six-worker allocation and the separate runtime owner establishes
and monitors the concrete worker/thread ceiling.** The harness does not create
an activated allocation file. `--allow-synthesis` alone is insufficient.

The coordinator/runtime owner supplies a JSON lease with these fields:

```json
{
  "status": "activated",
  "workers": 6,
  "endpoint": "synthesis",
  "store": "/tmp/opencode/developer-workflow-store-01",
  "manifest_sha256": "f1525b9945638cfa2c58bea363065bc86523b6abbbe7868102d98d4c38f3a8fb",
  "asic_generation": "EXACT-ABSOLUTE-ASIC-GENERATION-FROM-MANIFEST",
  "expires_unix": 0,
  "runtime_ceiling_established": true,
  "no_competing_eda_or_builds": true,
  "runtime_receipt": "ABSOLUTE-RUNTIME-OWNER-ADMISSION-RECEIPT",
  "runtime_receipt_sha256": "EXACT-RECEIPT-HASH",
  "monitor_pid": 0,
  "monitor_start_ticks": "PROC-STAT-STARTTIME"
}
```

This is a schema example, **not a valid allocation**: the expiry, PID, paths and
hash must come from the runtime owner. `monitor_start_ticks` is field22 of the
monitor's `/proc/PID/stat` (after splitting after the final `)`, index19).
The lease is re-read before launch and while the workflow runs. Revocation,
expiry, monitor death/PID reuse or changed runtime-receipt bytes aborts the run;
the harness requests cancellation of only its exact intent-bound workflow and
waits boundedly for terminal cancellation. The runtime owner remains responsible
for actual process/container monitoring, quotas, executor/native tool limits,
competing work/global20 accounting and concrete teardown proof. Boolean lease
fields are not a substitute for that evidence. A failed teardown is retained.

After that explicit activation, resume on the **same store**:

```sh
opam exec --switch=5.2.0+ox -- python3 -B scripts/test-developer-workflow.py \
  --phase synthesis --store /tmp/opencode/developer-workflow-store-01 \
  --previous /tmp/opencode/developer-workflow-simulations-05/receipt.json \
  --allow-synthesis --allocation /tmp/opencode/developer-workflow-allocation.json \
  --evidence /tmp/opencode/developer-workflow-synthesis-01
```

No daemon needs to be kept alive during the pause. This command starts a new
owned pair with the original history/preferences, opens a fresh actual Plan
form and stages a new intent before its single Launch-and-view. It refuses
preexisting implementation workflows/runs/launches to prevent a duplicate EDA
retry. A failure after allocation is diagnostic evidence, not permission to
relaunch: inspect the retained exact workflow/allocation before any coordinated
recovery. Do not delete the store or mutate history to bypass this fence.

After synthesis/report inspection passes, same-store restart/reopen:

```sh
opam exec --switch=5.2.0+ox -- python3 -B scripts/test-developer-workflow.py \
  --phase restart --store /tmp/opencode/developer-workflow-store-01 \
  --previous /tmp/opencode/developer-workflow-synthesis-01/receipt.json \
  --evidence /tmp/opencode/developer-workflow-restart-01
```

The implemented synthesis receipt binds workflow → actual source jobs → emitted
bundle/plan bytes → public allocation/run → original execution/methodology
snapshot → original report collection/catalog IDs/bytes. Cells, metric
availability, check statuses and `not_evaluated` acceptance are retained
separately. Restart saves the raw restored snapshot **before explicit Refresh**,
checks original bundle/execution/report bytes and preferences, reopens the exact
simulation reports/VCDs and A/B pair, and checks no implementation, collection or
simulation attempts were created. These are planned assertions, not passing
post-synthesis evidence yet.

## Retained failures and negative controls

- An early startup oracle expected `OPAMSWITCH`; this environment supplies
  `OPAM_SWITCH_PREFIX`. It rejected before preparing/launching anything. The
  harness now checks the actual prefix for `5.2.0+ox`.
- `developer-workflow-simulations-01`: first caller imposed120s tool timeout after
  successful prepare. Partial original evidence remains, with a new
  `interruption-recovery.json` note. The subsequent full native invocation used
  the same store and a sufficient caller timeout; no receipt was overwritten.
- `developer-workflow-simulations-02`: full inherited native acceptance plus
  actual Plan readiness passed. Its native evidence is reused by later
  inspection/readiness runs, never relabelled as a newly executed simulation.
- `developer-workflow-simulations-03/receipt.json`: added FIFO report-export
  screen oracle failed because zoomed detail does not paint the global notice.
  The actual exported file already existed. The harness now verifies the
  production export's exact metadata and bytes under its private TMPDIR; no
  production workaround was introduced.
- `developer-workflow-simulations-04/receipt.json`: corrected additional
  report/provenance/Plan/prewarm slice passed.
- `developer-workflow-simulations-05/receipt.json`: final additional slice passed,
  including per-check receipt and source/config/capture preservation.
- `developer-workflow-denied-01/receipt.json`: synthesis without explicit allow
  and allocation rejected before daemon startup.
- `developer-workflow-denied-02/receipt.json`: allow flag without allocation
  rejected before daemon startup.
- `developer-workflow-denied-03/receipt.json`: allow flag plus deliberately
  inactive/two-worker negative-control JSON rejected before daemon startup.
  All three expected-negative receipts say `failed`, preserve the exact CLI and
  error, report EDA0 and owner/private input preservation. They are not passing
  synthesis receipts.

Only the new verification script and this handoff are owned checkout changes.
Existing staged/untracked example sources, historical scripts/receipts, shared
production code and owner stable capture were preserved. Independent review and
the activated positive synthesis/report/restart run are the remaining gates.
