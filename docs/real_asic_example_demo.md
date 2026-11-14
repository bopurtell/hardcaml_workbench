# Real ASIC example demo and black-theme polish

**Native simulation provider, 2026-10-18:** the actual example now names a persistent
OCaml `test_provider.exe` that launches the existing standalone FIFO simulator.
The ASIC provider and physical results are unchanged. Provider adoption does not
require a daemon restart; explicitly discover again in Catalog before launching
with the changed configuration. Saved simulation attempts remain inspectable.
See [WB-066 implementation/evidence](native_provider_plan.md).

**Latest binary refresh, 2026-10-18:** default-layout restoration, cooperative
Testing/catalog, integrated FS3 and native activity/icon daemon/client/exporter
copies are prepared. Receipt:
`receipts/refresh-binaries-573452bea4d94baeb0635f81832ce473/`.
Once active jobs finish, restart the matching daemon/client pair to adopt them;
existing processes and state were preserved. Daemon/client alone reopen saved
state—do not repeat `seed` for this upgrade. See [FS3 integration](fs3_adoption.md)
for persistent appearance/header controls and template semantics. The historical
real-evidence measurements below are unchanged; this refresh did not rerun EDA.
Use **Appearance: Icons Unicode / ASCII / Off** for the new indicators; see
[native activity controls and evidence](terminal_indicators_plan.md).
For accidental extra/hidden tiles or changed sizes, use the new
[Restore default layout](default_layout_restore.md) palette command after upgrading
the pair. It hides extras rather than deleting them and preserves run/pin state.

**Real FIFO testing is now available:** a genuine project-owned Cyclesim provider
is installed separately from the ASIC provider. Use **Create Testing workspace**,
focus Catalog, press **d**, then choose cases and explicitly confirm a launch.
The new panes coordinate attempts/cases/detail/artifacts/logs without borrowing
ASIC-run provenance. See [full controls and real proof](testing_workspace.md).
No synthetic tests were injected into this root and no physical flow was rerun.

Implemented and verified 2026-10-16. The next demo opens the actual
`/home/wayne/devel/jane/hardcaml_asic_example` project using retained genuine named
signoff evidence. It is separate from the synthetic UI fixture. No new synthesis,
physical implementation or acceptance execution was needed.

**2026-10-17 layout follow-on:** Timing/Testing Session regions are now roomier and
the persistent demo binaries were refreshed and reverified. Final refresh receipt:
`receipts/refresh-binaries-ba3b02607ee446e88a67058d0d746203/`; actual HTTP/PTY
acceptance: `receipts/acceptance-f3248de97eac43cfb4cc65862aebb98e/`, both under the
demo base below. Seed now prints progress. For side-by-side hand-validation with
the populated synthetic Testing workspace, see [both launch pairs](synthetic_testing.md).

## Start the prepared real demo

Preparation, provider installation and binary validation have already completed on
this machine. From the Workbench checkout:

**Terminal 1:**

```sh
cd /home/wayne/devel/jane/silver
python3 -B scripts/real-asic-example-demo.py daemon
```

**Terminal 2:**

```sh
cd /home/wayne/devel/jane/silver
python3 -B scripts/real-asic-example-demo.py seed
python3 -B scripts/real-asic-example-demo.py client
```

The daemon chooses its own port. The helper discovers that exact endpoint and opens
the actual example root with the selected opam environment. Start at 120×40 or larger.
The state is isolated and persistent under:

```text
/home/wayne/devel/jane/hardcaml_asic_example/.dev/workbench-real-demo/
  bin/           pinned Workbench daemon/client/preset exporter
  state/         demo workspace and evidence cache
  discovery/     exact daemon endpoint
  client-state/  isolated client preferences
  receipts/      preparation, refresh, adoption and acceptance records
  results/       durable destination for any future explicitly launched work
```

`seed` validates and registers the original returned observation/finalization
references through normal public APIs. It uses the daemon-returned Run_ref, imports
the retained finalization and loads the four inspection domains. It also adds
missing preset tiles and selects the reference in Overview/Timing; run it
deliberately if you have customized their selected contexts.

For later sessions, daemon and client alone reopen retained state. Cached evidence
can be labeled unverified after restart; seed performs explicit read-only adoption
again. These commands do not start EDA. Palette Launch/Finalize actions remain
explicit operations which can start real work.

## What the real demo shows

- **673** mapped synthesis cells, evidence validated.
- Retained setup slack **11.6755 ns**, hold slack **0.125029 ns**.
- Physical completion **full**, separate finalization acceptance **pass**.
- Retained reported DRC/LVS/antenna passes.
- **Inspect timing paths** opens the composed Timing investigation workspace.
  The index contains **1,020 timing paths plus one input-reference row**.
- Rich clocks: 82 rows; physical: 99 rows; routing: 83 rows, including their reference,
  diagnostic and measurement categories. Exact row/digest detail reads are exercised.

These are measurements/verdicts from the historical producer records, not newly
evaluated results. The helper does not replace the actual project with a copied
metadata-only or synthetic project.

### Honest availability limits

The installed provider does not emit the optional Workbench `stage_plan` envelope.
Workbench now also normalizes its existing public schema3 recipe and exact stage
occurrences. After read-only Refresh, the checklist shows recorded completed stages
and not-requested stages rather than requiring that optional envelope. This does
not infer stage success from aggregate completion. Checklist r now uses the real
project's explicit fresh-prefix catalog declaration when no direct stage action is
present, discovering it on demand as part of that command. See
[launch/checklist consistency](launch_stage_consistency.md) and
[the restored r → Plan → Launch workflow](checklist_launch_workflow.md).

The current Timing UI counter says `1021 paths`, but it counts all index rows;
the precise evidence is 1,020 `timing_path` rows and one `input_references` row.
Original provider diagnostics, including repeated native metric keys and a missing
retained antenna-repair metrics file, remain visible. They are not converted into
invented zeros, unsupported passes or source mappings.

## UI changes in this pass

- Overview's left stack is **session → runs → stage checklist → planned-run**.
  Checklist and plan share the remaining sidebar height approximately equally;
  actual 120×40 capture gives each 12 framed rows. Six domain panels remain stacked
  at full width on the right. Timing topology stays unchanged.
- `Evidence:` and other field labels use neutral text. Only `validated` or other
  semantic values receive the state color; selection backgrounds remain coherent.
- Run-selector `completed`, `failed`, `running`, pending/cancelled and other known
  lifecycle values have field-specific colors. IDs remain distinct from status;
  unknown values stay neutral and process completion is not acceptance.
- Session Run uses available display cells, retaining a meaningful prefix and final
  hash characters when shortening. Human labels are preferred when usable; blank
  labels fall back to the actual ID. Opaque IDs keep an identifying head/suffix.
  Full references remain available through Session inspection and unchanged actions.
- **Carbon is the default**, with black ground and bright white headers. Focused
  borders, semantic statuses and metric colors remain distinct. Slate/Crimson/Neon
  remain available through **Color scheme: ...**. FS3 now retains scheme choices
  across restart in project/environment-scoped client preferences.

Source layout policy is in `terminal/workspaces/overview.ml`: checklist and planned
run have separate named 10-row minima and equal weights. Token styling/labels are
in `overview_tiles.ml` and `host_view.ml`; scheme default is in `appearance.ml`.

## Durable provider and exact evidence

The old example configuration pointed at deleted `/tmp` provider/results paths.
It now pins this persistent immutable provider generation:

```text
/home/wayne/devel/jane/hardcaml_asic_example/.dev/asic-workbench/generations/bd70b370807044e6b43bfab9aae3a4c6/bin/hardcaml-asic-flow
```

The prior `.dev/asic/current` selection and tested project executable are preserved.
Provider package 0.1.0, CLI4 and namedflow1 support were verified, including rich
`inspect`. Provider SHA256:

```text
51f9d4cd50f4bb4744224e9562f02a6a20b0b7c2f5f7f482fa0872f5f60fea3f
```

The source-capture receipt identifies snapshot
`0423a76848cdc41f79ec5fd67502445b08b783050d8eba9de83991e8550cda09`
and revision `ba399b4f81950c17a00da878bbee1165e86a8b77`. This is a local capture
receipt, not a source/artifact-attestation claim. Builds/install/consumer probe were
bounded to 2 jobs. A small backward-compatible `refresh --jobs` option was added to
the example's dependency helper, with resource-propagation tests.

Canonical evidence root:

```text
/home/wayne/devel/jane/hardcaml_asic_example/_flow_results/reorg-ad290d8-20261015
```

Original observation: `observations/20261015T083637970284Z_344ac175`, stream
`344ac175531e46fcbd021a1d4c79c361`.
Original finalization: `finalizations/20261015T090320118823Z_a22d3963`.
Their identities come from retained `client/run.stdout.jsonl` and
`client/finalize.stdout.jsonl`, not directory ordering. Execution, methodology and
selected checkpoint identities were cross-checked, along with 20 referenced hashes.

Preparation backup and checksums are retained under the demo base:
`receipts/prepare-a6caccf545c64ae88529d278c64daf2d/`.
The example's pre-existing `docs/headless_flow.md` edit was left alone. Provider
source checkout `hardcaml_asic` remains clean; canonical results were not modified.

## Refresh the demo after future Workbench builds

The launcher intentionally uses verified persistent copies, not whichever `_build`
executable happens to change. After rebuilding, explicitly refresh those copies:

```sh
scripts/with-switch.sh dune build -j 2 \
  daemon/main.exe terminal/main.exe terminal/workspaces/export_presets.exe
python3 -B scripts/real-asic-example-demo.py refresh-binaries
```

Then restart the demo daemon/client. Refresh performs no build or EDA itself. It
stages/checksums all three binaries, publishes the manifest last, retains old
binaries/receipts and rolls back pre-manifest publication failures. Existing running
processes are not restarted or signaled by this command. `--daemon`, `--client` and
`--preset-export` are prepare/refresh source options, not launch-time overrides.

Final refreshed copies match the normal build byte-for-byte. Refresh receipt:
`receipts/refresh-binaries-4a34eb5eb05f413e8acd7a8d8e09e6cd/result.json`.

## Verification: real evidence versus synthetic UI proof

Final normal Workbench format/lint, full tests and full build passed serially at
`-j 2`. Matching persistent copies passed actual-example HTTP/PTY acceptance:

```text
/home/wayne/devel/jane/hardcaml_asic_example/.dev/workbench-real-demo/receipts/acceptance-b72a4a8afe9441e698eda6a6da24e7a5/result.json
```

This includes actual Overview/Timing/rich-detail screens and before/after hashes:
**2,235 canonical input/provider files unchanged**. Earlier real acceptance
`acceptance-17b55c9b4eb240a4a5b2880bcdfcaa81` predates final binary refresh and is
superseded. Initial harness timeout/expectation corrections were not EDA failures.

Separate synthetic UI/regression evidence under `/tmp/opencode`:

| Suite | Result / root |
| --- | --- |
| Status/layout/black polish plus sidebar |196 checks, `real-example-polish-synthetic-5126599a8d7c` |
| Refinement |98 checks, `frontend-refinement-947bd5dccd4a` |
| Two-run capacity |12 checks, `frontend-refinement-947bd5dccd4a-two-runs` |
| Composition |46 checks, `frontend-composition-4af1425af411` |
| FS2 native Cyclesim |45 checks, `fs2-native-r_50_c9d` |
| Ctrl-C matrix |5/5, `workbench-terminal-interrupt-ukr9mg2q` |
| Synthetic launch/cancel |5 passed receipts, `synthetic-flow-26v5myxe` |

The polish fixture verifies exact ANSI value/label/status/header attributes and
long labels at 120×40. Its literal `running` paint uses a static token fixture;
ordinary synthetic live observation reports `observing`. It is not actual ASIC
producer evidence. Three binary-refresh tests cover success receipts, missing input
refusal and rollback on a forced second-file publication failure.

Re-run real read-only adoption acceptance:

```sh
python3 -B scripts/test-real-asic-example.py
python3 -B scripts/test-real-asic-binary-refresh.py
```

These use private receipt subdirectories and stop only their own processes. No Git
staging, commits, pushes or real implementation/acceptance execution was performed.
