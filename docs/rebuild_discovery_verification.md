# Rebuild diagnosis, installation refresh and auto-discovery — 2026-11-11

## Scope and source state

Starting clean heads: Workbench `16dee95`, ASIC `79c73a2`, example `c9a9a0a`.
Revalidated current source and installations rather than relying on pre-crash `/tmp`
artifacts. Builds and tests were serialized: outer Dune `-j1`, except example
preparation's inspected two-job build. No physical EDA or Git attribution mutations.

## Host resets versus test failures

Firmware BERT records in boot `-2` report fatal PCIe errors for Mellanox ConnectX-4
Lx functions `0000:41:00.0` and `.1`, plus corrected DRAM errors on DIMM `P0A0`.
Current-boot records contain another corrected error on that DIMM. Similar records
exist in older September crash evidence. Prior journals/heartbeats end abruptly.
No runtime OOM/panic/lockup report or orderly shutdown was found in the inspected
boots. Last available RAM samples were approximately 27–29 GiB; the final sampled
CPU temperatures varied (45°C, 77°C, 57°C).

These observations support host hardware/platform instability independently of
ordinary test assertion failures. They do not uniquely identify the initiating
component, prove every reset's cause, or show that lowering Dune jobs fixes it.

Three separate ASIC test defects were corrected:

- Default-journal assertions expected 20 workers rather than the implemented six.
- SRAM bridge mock lacked the newly required executor API.
- Default comparison review registered the historical gap reproduction instead of
  the existing corrected regression. Historical reproduction remains explicit.

Result-store fixture concurrency is now configurable through
`HARDCAML_ASIC_TEST_WORKERS`; two workers still perform all 16 allocation attempts.
Outer Dune jobs do not bound child fixture concurrency automatically.

## ASIC verification

With `HARDCAML_ASIC_TEST_WORKERS=2`, `OMP_NUM_THREADS=1`,
`OPENBLAS_NUM_THREADS=1`, `MKL_NUM_THREADS=1`, `NUMEXPR_NUM_THREADS=1`:

1. Forced `dune runtest . -j1 --force --display=short` completed in 2,949 seconds,
   exposing the SRAM mock and historical-review defects.
2. Forced corrected SRAM and comparison groups passed (38 comparison checks).
3. Complete `dune runtest . -j1 --display=short` passed cache-aware, reusing successful
   forced results plus corrections; this was not a second forced full execution.
4. Forced supplemental stage preparation (62), segment service (71), checkpoint
   publisher (52), and named-runtime core (7) checks passed.

Icarus bundle simulation ran. No real physical EDA ran. Minimum sampled available
RAM was 27.66 GiB, zero swap use, peak sampled Tctl 65.875°C, and no new kernel
events or monitor-triggered stops. Source-tree standard qualification passed;
the full standalone installed corpus with hardcoded nested `-j20` was not run.

Persistent diagnostic evidence:
`/home/wayne/crash-evidence/asic-task-a-20261111/` (journals, pre-rerun trace,
heartbeats, commands, outputs, resource samples and correction patch).

## Example installation refresh

The selected ASIC generation `36205ea4748c4972877ac198356d8e44` records an older
dirty base, but its source snapshot matches current clean runtime source. Installed
interfaces/runtime modules and provider SDK were rechecked; subsequent ASIC changes
are test-only. Reused that generation and SDK rather than republishing identical
runtime content. The checked-in dependency pin and other development stores are
separate selections and were not silently changed.

Rebuilt the current Workbench daemon/client at `-j1`, compiled/linked an installed
ASIC/provider-SDK API probe, verified library resolution, and rebuilt all five actual
example targets with the main prepare command at two jobs. Provider metadata sanity
passed (CLI4 and namedflow1). Main selection changed:

```text
015f895c02584f73be21d20d35afb096 -> 6704c0570bac455b9956a67c2b381f51
```

Published companions consistently; their bytes remained unchanged because dependency
paths/settings did not change. Old installs and receipts remain intact. Final status:
`simulation_ready=true`, `root_companions_match=true`, `daemon_running=false`.
No new kernel entries during refresh; available RAM remained above 27 GiB.

Evidence: `hardcaml_asic_example/.dev/task-b-refresh-20261111/`, including result,
dependency recheck, preflight, final status, command/resource receipts and backups.
One initial build exceeded the tool deadline; its remaining process was stopped
before serial continuation. No concurrent build was left running.

## Discovery verification and use

44 fixture tests plus 15 runner self-tests passed at `-j1`. Real read-only preflight
passed in Dune's sandbox with an external build directory, resolving the refreshed
installation. The environment's `DUNE_SOURCEROOT` was unset before invoking Dune,
confirming the action receives the correct source root from Dune itself. Explicit
invalid override rejects without fallback; root/common conflicts and unsafe paths
are covered. No applications or EDA were launched by preflight.

From Workbench, no config export is required:

```sh
opam exec --switch=5.2.0+ox -- dune build -j1 @test-real-preflight
# Actual fresh physical prefix, when the host is ready:
opam exec --switch=5.2.0+ox -- dune build -j1 @test-real-timing
# Eight independent fresh prefixes, serially:
opam exec --switch=5.2.0+ox -- dune build -j1 @test-real-pyramid
```

The last two commands were not executed in this update. Preflight readiness and
bounded test passes do not establish that the host hardware problem is resolved.
