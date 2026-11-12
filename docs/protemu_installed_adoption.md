# Protemu installed adoption — bounded acceptance

The [Protemu normal workflow and full evidence record](../../hardcaml_protemu/docs/adoption-release.md)
is the operational entry point. This page records Workbench's release-facing scope,
not another implementation queue or a claim that Protemu meets timing.

## Complete scope

- Checked local ASIC/Workbench installation and normal project activation, with
  explicit dirty-source capture and no shared-switch mutation.
- Project-owned named `flops` and `stock_sram` flows, current preparation and exact
  resource inspection, supported stock SRAM through ordinary extracted Timing.
- Seven qualified Testing cases, real VCD artifacts, generic verified Protemu event
  results and comparison, installed UI waveform navigation, and live owned-child
  cancellation for serial and nested event producers.
- Actual Protemu TUI launch through Timing, retained run reopening, and Resources
  presentation. The opt-in timing-repair profile preserves hardware/48 MHz SDC.
- Explicit bounded reinspection of the retained large timing report with public
  provider lineage and digest-fenced typed path details.

The real design missed setup. Tooling successfully reports that negative outcome.

## Timing reinspection contract

The original execution `b591d335b32a49b8a019739ef7044e4e` completed its six stages,
but the old timing collector exceeded its line-count bound and stored an unavailable
analysis/unknown goal. The fixed ASIC reader streams source hashes/metrics and
offers negotiated `timing_reinspection1` via:

```sh
hardcaml-asic-flow inspect "$EXECUTION" \
  --domain timing --stage timing --refresh-timing --json
```

Workbench's explicit `Inspect_analysis { refresh = true }` validates original
observation path/hash/digest, execution and transport linkage, preserved source
hashes and recomputed metric/goal consistency. New details repeat the reinspection
mode and pin the refreshed source digest. Old providers retain pinned historical
inspection behavior; no binary wire record fields were added.

The UI labels **original unavailable/unknown; recomputed completed/fail**. Actual
installed verification produced 193 rows and a −3.099803 ns path detail. The index
is explicitly truncated to bounded sampled paths, not exhaustive timing coverage.
Original observation/execution/journal bytes are unchanged. This is read-only
interpretation of retained producer evidence, not a rerun or historical success rewrite.

## Accepted installation and evidence

Protemu-local tools generation: `f88b8d44e7524aa3862fc163d2e2baec`.
Simulation generation: `64971bc2ad2945ecbd1994ccb955d41f`.

```text
hardcaml_protemu/_flow_results/workbench/releases/
  714edccf3d934c1b99ce50c6930c7948/closeout.json
```

That release retains frozen sources, installed-provider/service proof and actual
production daemon/client PTY evidence. Independent read-only review verified 846
ASIC and 759 Workbench source files against the captured inputs, all seven qualified
case events, negative-path detail queries, 28 unchanged protected history files,
and absence of captured cancellation children and acceptance daemons.

Installed simulation execution used public RPC; PTY evidence proves navigation and
waveform viewing. Physical timing launch used actual PTY input. Keep those evidence
types distinct. The successful serial/event results do not establish full-package
performance comparisons: the event workload's boundary is core+Program_memory.

## Remaining boundaries

Protemu slow setup is −3.0998 ns with 444 violations after the one repair candidate.
Full physical acceptance and package performance selection remain open. The separate
Magic control/recheck passes without changing the original failed run. PT.7 linked
exceptions, macro Signoff/finalization, historical failed-coarse resource attribution,
P6 compiled-source stamping and broader-platform qualification are not completed by
this work. They must not be inferred from successful installation or read-only
inspection.

All owned processes are stopped. No Git attribution mutations occurred. Source
publication and release revision selection remain explicit owner actions.
