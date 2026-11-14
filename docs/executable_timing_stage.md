# Executable Timing stage

Timing is now a real `hardcaml_asic` stage and checkpoint. New recipes execute:

```text
Synthesis → Floorplan → Placement → CTS → Routing → Timing → Signoff
```

This extends [WB-069's original analysis-only delivery](timing_checklist_overview_plan.md).
The [follow-on plan](executable_timing_stage_plan.md) records scope and agent ownership.

## Use it from Overview

1. Focus **Stage checklist** and select **Timing** with `j` / `k`.
2. Press **`r`** to prepare a new run through the Timing endpoint.
3. Review the planned run and choose **Launch** (or Launch and view).
4. The new run stops after Timing; Signoff is not requested.

`r` prepares exactly once and does not implicitly launch. Existing flow/profile/
assignment selection rules still apply. This works when an old six-stage run is
selected too: the **current provider/catalog** supplies the fresh endpoint, while
the old run's stages and evidence remain unchanged. An incapable provider shows
an explicit unsupported-endpoint message. Preparation feedback survives periodic
registry polling rather than disappearing before it can render.

**Enter** on Timing or the Overview Timing tile opens the exact captured analysis.
**`d`** shows details; **`r` on the Timing tile** remains evidence refresh. There is
exactly one Timing checklist row, including for historical records.

## What the stage runs

| Boundary | LibreLane Classic steps |
| --- | --- |
| Routing ends | `OpenROAD.DetailedRouting` |
| Timing begins | `Odb.RemoveRoutingObstructions` |
| Timing includes | Post-route checks, fill, cell tables, parasitic extraction (RCX), post-PNR STA |
| Timing ends | `OpenROAD.STAPostPNR` |
| Signoff resumes | `OpenROAD.IRDropReport`, then remaining stream-out/verification through `Misc.ReportManufacturability` |

LibreLane still owns step ordering, gates and deferred checks. Timing is not a
shortcut that runs STA without its required physical inputs.

The provider supports compatible **Routing → Timing → Signoff** checkpoint
continuation. Signoff continuation starts after STA and does not rerun it. The
checklist's `r` workflow prepares a **new run**; it does not implicitly resume the
selected historical execution. Explicit provider continuation uses:

```sh
hardcaml-asic-flow stages --checkpoint ROUTING_CHECKPOINT --through timing ...
hardcaml-asic-flow stages --checkpoint TIMING_CHECKPOINT --through signoff ...
```

Supply the usual required runtime/bundle/toolchain arguments. Checkpoint reuse must
pass compatibility checks; old bridge checkpoints remain readable but cannot be
silently resumed through a different bridge contract.

## Status, duration and provenance

- **Stage status/time** belongs to the entire Timing segment, including extraction,
  preparation and publication.
- **STA status/runtime** belongs to the exact native STA producer. Its runtime is
  wall-clock-derived with millisecond precision.
- **Timing goal** reflects supported measurements and coverage, not execution success.
- **Current execution outcome** is separate from the immutable source's captured
  status. A frozen source captured while running can back a now-failed execution.

The tile labels stage time and STA runtime separately. A fixture demonstrates
**2.798826s stage time**, **1.575s STA runtime**, current outcome **failed**, and
captured-source status **running** without confusing these facts.

At successful Timing completion, before Signoff begins, the provider freezes an
execution prefix and publishes an exact Timing analysis. Thus timing evidence is
available while Signoff runs and survives later failure/cancellation. Failed Timing
segments can retain independently proven STA output without claiming a successful
stage/checkpoint. Missing/skipped STA never earns completed analysis.

New recipes use schema 4 and analysis schema 2, stage `timing`. Historical recipe
schemas 2/3 and analysis schema 1, stage `signoff`, retain their original meaning.
Captured targets include stage and exact source path/hash; caches, details, pins and
restart restoration preserve them. Main-execution advancement does not invalidate
an unchanged frozen source, and source replacement is rejected.

Discovery requires `timing_stage1` plus a declared fresh `timing` endpoint. The
`timing_analysis1` capability alone does not authorize execution. HTTP consumers
negotiate `X-Workbench-Asic-Timing-Analysis: 2` for new targets; old readers retain
compatible historical observations. See the sibling
[provider contract](../../hardcaml_asic/docs/development/executable-timing.md).

## Refreshed example deployment

The existing `hardcaml_asic_example` configuration and retained real-demo binaries
were refreshed. **Live daemon/client processes were left running; restart both to
use the new pair.** No reseeding or new physical flow is needed for activation.

Close the old client and stop its daemon in their owning terminals when appropriate.
Start the daemon:

```sh
python3 -B /home/wayne/devel/jane/silver/scripts/real-asic-example-demo.py daemon \
  --dir /home/wayne/devel/jane/hardcaml_asic_example/.dev/workbench-real-demo
```

Then, in another terminal:

```sh
python3 -B /home/wayne/devel/jane/silver/scripts/real-asic-example-demo.py client \
  --dir /home/wayne/devel/jane/hardcaml_asic_example/.dev/workbench-real-demo
```

The daemon reads the project's root `hardcaml-workbench-asic.sexp`. Its executable
bindings now select provider generation `a078e900a856409d86540156f2783cce` and the
new project driver in receipt
`executable-timing-deployment-20261021-db26c92ca69345568abd281d4338db76`.
All other configuration, including the 3600-second timeout, was preserved. Prior
generations, project executables and evidence remain intact. The example's standalone
endpoint whitelist and help strings now include Timing; its catalog already uses
`Flow.Stage.all` and needed only rebuilding against the new library.

Receipts are under `hardcaml_asic_example/.dev/workbench-real-demo/receipts/`:

- `executable-timing-deployment-20261021-db26c92ca69345568abd281d4338db76/`:
  previous/new configuration, hashes, verified seven-endpoint catalog and project binary;
  `named-timing-plan-verification.json` also records the actual installed driver's
  successful `flow plan --flow standard --profile balanced --endpoint timing --json`.
- `refresh-binaries-924f721de7db4f6c9d7e3397baf9835f/`:
  final Workbench daemon/client/exporter publication, old backups and manifest hashes.

Deployment used the dependency helper with `--jobs 6`, activated the fresh private
generation, and rebuilt the example project with `dune build -j6 bin/project.exe`.
The demo manifest retains its original seed metadata: **do not reseed** as part of
this restart; the seed checksum guard refers to the old configuration.

## Verification record

Implementation and automated acceptance completed on 2026-10-21. Tests used
deterministic native transport/bridge fixtures and read-only supported-image
introspection, not a newly executed physical EDA flow.

| Check | Result / evidence |
| --- | --- |
| Full Workbench build/lint | `./scripts/with-switch.sh dune build -j 20 @all @lint` passed |
| Full Workbench tests | `./scripts/with-switch.sh dune runtest -j 20` passed after final feedback fix |
| Executable Timing native HTTP/PTY | 11 checks passed; `/tmp/opencode/wb-agent-c-executable-feedback-fixed/` |
| Legacy incapable-provider native HTTP/PTY | Passed, including persistent unsupported feedback; `/tmp/opencode/wb-agent-c-unsupported-feedback-fixed/` |
| Complete checklist launch regression | Passed; `/tmp/opencode/checklist-workflow-f4de427cc490/` |
| Overview sidebar / frontend composition | Passed; `/tmp/opencode/wb-agent-c-overview-sidebar/`, `/tmp/opencode/wb-agent-c-frontend-composition-2/` |
| Actual provider-to-Workbench inspection | Cases 2–5 and legacy fixture passed backend validation; terminal cross-contract receipts at `/tmp/opencode/wb-agent-c-actual-cross-contract/` |
| Provider executable Timing lifecycle | Passed, including both continuations, stop-at-Timing, live evidence during Signoff, cancellation and failed Timing recovery |
| Provider recipes / execution plans | 46 accepted / 3210 rejected recipes; 168 accepted / 6737 rejected cross-language plans |
| Provider preparation / segment service | 62 / 70 checks passed |
| Provider protocol / observation / Runner | 54 accepted / 943 rejected protocol cases; 335 accepted / 2077 rejected observation cases; 691 Runner cases |
| Provider report, inspection, legacy analysis, CLI and finalization | Passed; 43 CLI tests; 26 finalization differential invocations and 16 finalization tests |
| Deployment | Exact configured provider advertises both Timing capabilities; rebuilt project describes seven endpoints; retained Workbench binaries match source builds |
| Installed example plan | `standard / balanced → timing` produced recipe 4 ending at Timing, no Signoff, plan identity `a0670b99b3bebb6fa2c9a70f580cdcd8723654d926bc99020832541caaceeaed`; no execution launched |

The actual provider fixture root is `/tmp/opencode/executable-timing-handoff-final/`.
It retains separate Routing/Timing/Signoff attempts, full success, failed Signoff,
failed Timing with proven STA and cancellation. It is synthetic transport evidence,
not a real-tool QoR measurement. The supported image's 80-step Classic inventory,
artifact contracts and gates were verified by bounded import-only introspection.

The final executable acceptance verifies both physical and historical selected rows:
one preparation, no implicit run, explicit seven-stage Timing prefix, unchanged
historical bytes, exact inspection from both surfaces, stage-aware HTTP targets and
cached-unverified restoration. A discovered registry-poll race in failure notices was
fixed and covered by a 30-poll unit regression and untouched-periodic-poll PTY check.
The checklist regression's expected unsupported wording was updated to the new
explicit message without loosening its no-launch checks.

Changed feature formatting and scoped Workbench formatting aliases pass. Global
`@fmt` retains pre-existing differences in unrelated Workbench waveform/hydration/
workspace code and broad provider baseline files; those were not wholesale reformatted.
`git diff --check` passes. No repository staging, commits or pushes were performed.
Three implementation agents were used; shared build concurrency stayed within 20.

Reproduce the focused executable acceptance using matching prebuilt binaries:

```sh
python3 -B scripts/test-executable-timing.py \
  --daemon _build/default/daemon/main.exe \
  --client _build/default/terminal/main.exe \
  --preset-export _build/default/terminal/workspaces/export_presets.exe \
  --timeout 300
```
