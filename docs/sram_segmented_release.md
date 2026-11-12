# SRAM segmented tooling — release evidence, 2026-11-12

## Complete bounded scope

Workbench admits the provider's supported single stock256×16 R0 SRAM workflow
through Timing, previews and submits the exact named plan, and observes/reopens
its results. The [provider contract and qualification](../../hardcaml_asic/docs/guides/segmented-sram.md)
defines the physical/profile/checkpoint limits.

This is tooling qualification, independent of Protemu design acceptance. Macro
Signoff/finalization, PT.7 linked exceptions, arbitrary macros and relocation remain
unsupported. No segmented-to-coarse fallback was added.

## Admission and failure behavior

`Asic_public` checks macro declarations in both emitted manifest and configuration.
Macro plans require `sram_segmented1=true` and the compatible structured scope,
schema-2 Hardening, one stock R0 instance, and a fresh endpoint through Timing.
Capability checks occur before publishing a preview, after emission, and again
before physical allocation using fresh metadata. Legacy macro-free plans remain
usable without the new capability. Missing, withdrawn or incompatible support fails
closed; unsupported selections are not silently changed.

Controlled tests cover unsupported preview, malformed scope, checkpoint mismatch,
capability withdrawal, no submission/restart resubmission, and completed Timing
with a failed timing goal retaining validated evidence. A design failure can be a
passing truthful-reporting tool test. No new general arbitrary-path failed-artifact
browser or coarse-run-to-segmented adapter was added.

The whole-prefix deadline now covers separate execution and checkpoint-validation
calls, runtime probes and bounded overhead rather than a fixed 30 minutes:

```text
stage_count × (2 × configured_stage_timeout + 180) + 900 + 90 seconds
```

Per-stage timeout is restricted to 1–86400 seconds. This is a practical deadline,
not a strict analytical upper bound on filesystem copying/hashing. Tests cover
every endpoint at minimum/default/maximum settings and invalid values.

## Installed consumer and actual production journey

All local evidence is under:

```text
hardcaml_asic_example/.dev/sram-segmented-20261112T080824Z/
```

The isolated generation `6aad7c011d6c49dbae5c2838beb69f9c` passed provider checkpoint
and real six-stage qualification. The independent program-memory consumer now
implements public `flow list/describe/plan/emit`, preparation and legacy export
commands. Production Workbench readers accepted six real plans and preparation
receipts; Signoff and capability revocation negatives rejected. Owner main FIFO
configuration and previous installed generations were preserved.

Actual Workbench proof:

```text
workbench-proof/timing-20261112-01/verification.json
```

| Identity | Value |
| --- | --- |
| Run | `0aa3c20073bf4659ba5c672a3a06b653` |
| Plan | `cf5989798ed09867b1a6517f015ff7b3cd56dcc37d57299fef0af2b00957f259` |
| Bundle | `b3c81715ae6e52eb60cf3841d6c51d867abebb3c9f97e43527b7072ee811be58` |

The production client received real PTY keyboard input, selected the enabled
launch command, and submitted one fresh source build/emission/execution. Raw
keystrokes, ANSI and screen captures are retained. Supporting RPC assertions are
identified separately and are not presented as TUI input.

All six stages completed, with six schema-3 checkpoints and a validated 22-record
observation journal. Timing goal passed; Signoff was not requested and no finalization
or coarse fallback occurred. Restart reopened the exact durable workflow/allocation,
selection and Timing target. Cached evidence began `Cached_unverified`; explicit
refresh returned `Validated`. Reusing the original submission key did not rerun
anything. Original journal bytes remained unchanged.

The original harness receipt failed because it compared ephemeral build/emission
job handles across daemon instances. That failure remains intact. A corrected
independent verification checked every durable field against the same retained run,
including actual TUI reopen, without another EDA run. The captured header still
shows `controlled_fifo_specimen`; this was an inherited fixture label, not a wrong
flow/run identity. Future reusable runs set an explicit generic project name.

The original driver took about 240s and corrected reopen verification 50s. Source
builds used2 jobs; provider containers6 CPUs and STA1. All test-owned daemons,
clients and containers stopped.

## Reproducible testing

Controlled checks:

```sh
opam exec --switch=5.2.0+ox -- dune build -j10 \
  @backend/test/asic/runtest @test/integration/pyramid/runtest
```

These passed, including 60 pyramid regression tests and 15 runner self-tests.
They do not launch real EDA.

The existing fresh-prefix runner now supports an optional same-store reopen check
and private project name. `test/integration/pyramid/configure_private.py --help`
creates an explicit config from an existing installed provider and complete private
consumer source; it performs no installations or tool launches. Use the source
target `asics/program_memory/verif/segmented_consumer.exe`, flow `stock256-r0`,
profile `qualification`, matching captured prefix library path and a new evidence
directory. The setup validates the captured exporter; execution builds/emits from
the complete staged source rather than reusing its original bundle.

After preparing that config, the explicit physical journey is:

```sh
python3 -B test/integration/pyramid/runner.py \
  --endpoint timing --config /absolute/private-config.json \
  --daemon "$PWD/_build/default/daemon/main.exe" \
  --client "$PWD/_build/default/terminal/main.exe"
```

Use `--preflight-only` instead of `--endpoint timing` for read-only setup checks.
Reopen verification supports one physical endpoint, not Elaboration or the full
pyramid. Newly integrated reusable harness changes passed controlled tests and
real-path preflight; the retained actual journey above is the physical evidence.

Default automatic example discovery still follows the owner's selected main
installation (FIFO on this machine). It was not silently changed to this private
SRAM consumer. The provider's immutable prequalification metadata says
`physical_qualification=not_run`; later receipts, not a rewritten binary, record
the successful qualification.

## Independent review

Read-only review verified 59 representative checkpoint file records, original
producer linkage and copied evidence, 16 Workbench evidence hashes and 12 transport
hashes, actual retained screens/restart results and installed helper identities.
No critical admission/mutation/publication blocker was found in this bounded scope.
The timeout-budget concern it identified was corrected and focused gates rerun.
No Git staging, commit, push or authorship changes were performed.
