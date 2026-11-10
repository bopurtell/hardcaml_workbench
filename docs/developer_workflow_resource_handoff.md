# Section 1 resource/runtime verification handoff

2026-11-10. Implements the verification-only runtime slice of
[the acceptance plan](developer_workflow_acceptance_plan.md). EDA is **not activated**
by this handoff. No flow, owner pair, provider, bridge, configuration or retained
provider output was modified. The acceptance owner retains exclusive TUI launch and
workflow cancellation responsibility.

## Exact runtime metadata (executed outside EDA)

`/tmp/opencode/developer-workflow-runtime-metadata-03/` records the exact command,
image inspection, native help/version output and imported implementation source.
The container used `--cpus=2`, explicit two-thread OMP/OpenROAD/OpenLane/BLAS/MKL
environment, no network, no project mounts and a read-only root. It did not construct
or start a flow. ABC `-h` exits 1 while returning usage; that is retained, not hidden.

| Identity | Observed |
| --- | --- |
| Provider | immutable `ee3af8de9f83418b9afed9c67e473e3c` |
| Image | `sha256:d109140b8f17fc54f4fca998beb8124f4949404ec52e339eebd2250854a18b5a` |
| Image tag (informational) | `ghcr.io/librelane/librelane:3.1.0.dev3` |
| LibreLane | `3.1.0.dev3` |
| Yosys | `0.66`, git `86f2ddebce7e98ce7cacc27e8a5c14cb53b51b51` |
| ABC | `1.01`, compiled `Jan 1 1980 00:00:00` |
| OpenSTA | `2.7.0`; help explicitly supports `-threads count|max` |

The image's declared Classic prefix has SIX steps:
`Verilator.Lint`, `Checker.LintTimingConstructs`, `Checker.LintErrors`,
`Checker.LintWarnings`, `Yosys.JsonHeader`, `Yosys.Synthesis`.
Gating can skip step bodies. Six declared steps is not six native workers.
There is no STA step before this endpoint. With no timing-intent producer in the
fresh emitted manifest, expect **zero STA invocations**. Do not add STA or physical
work to make a more populated report.

Imported `PyosysStep.get_command` invokes Yosys with `-y <script> -- --config-in …`;
its `run` delegates one blocking subprocess. Ordinary synthesis uses ABC within
Yosys. Expected normal native concurrency is one Yosys process, sometimes with an
ABC child while Yosys waits; an optional lint phase is separate. This is an expected
shape to check against actual commands, not an asserted universal native-thread
guarantee. No expected cell count is fabricated for a fresh run.

## Configured ceiling versus observation

The immutable bridge creates an official LibreLane executor with maximum6 and
resolves `OPENROAD_THREADS=6`, `STA_THREADS=1` (parallel corners), and KLayout
threads6. The named stage service and metadata probe request6. Transport records
explicit Docker CPU quota6 and `_OPENLANE_MAX_CORES`, `OPENROAD_THREADS`,
`OMP_NUM_THREADS` all6. Provider timing evidence readers also expect these exact
six-worker records. No two-CPU rewriting is used for the synthesis run.

Yosys/ABC help does **not** expose a general supported native thread-cap flag.
Absence of that flag is not proof of single-threaded execution. Ordinary OpenSTA's
base command lacks `-threads`, although the separately bound timing-intent route
adds an explicit limit. If STA appears unexpectedly without an explicit supported
bound, the observer rejects it. Native thread expansion or an unknown native tool
also blocks. Do not set `runtime_ceiling_established:true` merely because Docker
quota is6 or because the Python pool is6; the runtime owner/coordinator must resolve
any concrete native-bound gap before approving that assertion.

The observer distinguishes:

- Configured executor capacity6, including idle threads.
- Per-process OS thread count, including sleeping/controller threads.
- Runnable threads at an instant.
- Threads with CPU tick progress between samples. Several such threads need not
  have executed simultaneously.

It records observed peaks, not exhaustive scheduler-wide maximum proof: processes
or threads shorter than the sampling interval can be missed. Native OS-thread sum
above6 is conservatively rejected even if some are sleeping; Python controller/
executor OS threads are recorded separately. CPU quota remains an independent CPU
time ceiling, not a substitute for native worker/thread evidence.

## Observer CLI and same-store handshake

`scripts/developer-workflow-resources.py` has three modes:

```bash
python3 -B scripts/developer-workflow-resources.py audit \
  --evidence /tmp/opencode/NEW-resource-admission
python3 -B scripts/developer-workflow-resources.py metadata \
  --evidence /tmp/opencode/NEW-resource-metadata
python3 -B scripts/developer-workflow-resources.py watch \
  --store /tmp/opencode/EXACT-test-store \
  --activation /tmp/opencode/EXACT-coordinator-activation.json \
  --finish /tmp/opencode/EXACT-monitor-finish \
  --evidence /tmp/opencode/NEW-resource-watch \
  --interval 0.25 --timeout 1800
```

All evidence directories must be new. `audit` and `metadata` do not authorize EDA.
`watch` never launches a flow and requires a coordinator-authored activation:

```json
{
  "schema_version": 1,
  "allocation": 6,
  "endpoint": "synthesis",
  "store": "/tmp/opencode/EXACT-test-store",
  "manifest_sha256": "EXACT-MANIFEST-SHA256",
  "activated": true,
  "activated_at_unix": 0
}
```

Use the actual current timestamp, at most300 seconds old at observer startup.
Do not create this file until the coordinator explicitly activates the run.
The monitor independently checks admission before publishing `ready.json`.
Its readiness means the monitor is live and admission was clear, **not** that
native ceiling/acceptance succeeded. That distinction is intentional.

The acceptance owner's separate existing `--allocation` JSON can bind:

- `runtime_receipt`: observer `ready.json`, with its exact SHA256.
- `monitor_pid`: `ready.json`'s `pid`.
- Exact same store, manifest hash, provider generation, workers6 and synthesis endpoint.
- Coordinator-approved expiry and the separately justified native-ceiling assertion.

Before sending the TUI launch key, wait for `ready.json`; check monitor still alive
and no `stop-request.json`. Throughout the workflow, the acceptance harness must
check **both** observer liveness and absence of `stop-request.json`. PID existence
alone is insufficient (including zombies/reused PIDs). On a stop request or abnormal
exit, cancel only the exact test-owned workflow through its normal public cancel
operation. The observer does not signal any daemon/process/container itself.

After terminal workflow completion and no remaining owned container, the harness
may create the agreed finish file. Wait for monitor exit0 and inspect `summary.json`.
An exit2 or missing summary blocks resource acceptance. Always retain failed
attempts. Do not reuse an old activation, observer receipt or summary.

## Ownership and stop behavior

The observer lists global running containers and known build/native executable
processes for competition detection. It samples detailed tasks only for a container
whose bind source is under the exact `/tmp/opencode` test store. That container
must also have the exact provider-owned name format, the pinned image, no external
writable mount, quota/environment6, and a matching pre-existing test-store launch
argv receipt. Unknown images, commands, ownership, budgets or overlapping containers
produce `stop-request.json` and exit2. Only fresh synthesis requests without an
initial checkpoint are admitted. No Docker exec, flow launch, provider rewriting,
quota modification, bridge replacement or output/provenance editing occurs.

Own source builds may occur before the first bridge call only, and not while a
container is running. Other detected builds/native jobs block even when they would
fit numerically in20: this is stricter than the reserved14 and meets the initial
no-competing-build admission rule. The detector matches executable names, not words
inside agents' prompt arguments. Detection is not an exhaustive classifier of all
possible workloads; unreadable processes are disclosed. Coordinator allocation
coordination remains necessary. Idle owner daemons/clients are never stopped.

The installed supervisor uses a new native process group and group-based cleanup.
The observer records PGID/session/PPID; it does not exercise native cancellation or
prove that the installed Spawn path will work for a new stage execution. A native
process-group launch failure, cleanup failure or serialization/receipt mismatch is
a blocker to diagnose, not permission to use a different execution route.

## Checks and blocker map

Executed `python3 -B scripts/test-developer-workflow-resources.py`:9 tests passed.
Negative controls reject quota2 relabelled as6, unlimited/expanded quota,
missing/duplicate/expanded environment, wrong image/name, owner/sibling mounts and
external writable mounts, expanded native worker flags and unbounded STA;
process filtering avoids treating tool names in agent
prompts as active builds. These use synthetic dictionaries only, no historical
records or actual flow/container mutation.

The initial read-only audit at
`/tmp/opencode/developer-workflow-resource-admission-01/admission.json` observed
no matching competing workers and no running containers. This is a timestamped
snapshot, not current activation. Earlier raw `ps` also showed agent/control
processes and unrelated `ches.exe` applications; these were not tool-job matches.
The subsequent `developer-workflow-resource-admission-02/admission.json` likewise
found no matching workers/containers, with no unreadable process identities after
preserving command/stat observations independently of restricted cwd access.
The monitor has not yet been attached to an actual flow; its first real attachment
must be reviewed with the acceptance run, including short-lived wrapper coverage.

| Finding | Disposition |
| --- | --- |
| Unknown/expanded quota, environment, native flag or OS-thread count | Stop request; cancel exact owned workflow; retain actual evidence |
| Unexpected STA without explicit `-threads` | Native-limit blocker; do not hide behind `STA_THREADS=1` |
| No timing intent and no STA process/report | Expected; report unavailable timing truthfully |
| Process-group launch, cleanup or serialization failure | Retain exact provider failure; no fallback/relabel |
| Missing short-lived process samples | Observation coverage limitation; use retained command/step/log evidence, do not claim exhaustive peaks |
| Functional FIFO/PT.8 phase failure | Acceptance owner stops before EDA activation |
| Synthesis process success | Still requires publication/report association and actual TUI inspection/restart acceptance |

Independent review starts only after the acceptance owner's initial passing run.
