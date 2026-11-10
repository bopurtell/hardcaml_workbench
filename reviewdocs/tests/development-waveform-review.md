# C independent adversarial waveform review

**Final disposition: PASS,86/86 independent controls; both findings corrected and
independently retested.** Current receipts, final source/app hashes and complete
no-xfail native acceptance are in `development-session-final-c.md`. The original
findings and failed/blocked reproductions below are preserved as historical review.

2026-11-05. Review after A's initial passing suites. **One reproducible medium
finding; 85 of 86 adversarial checks pass. No production edits by C.**

## Finding: short retained trace falsely labelled eight cycles

`Waveform_view.default_extent` caps the requested span to retained duration but
unconditionally formats the basis as `8 cycles`. A clock with rising edges at
5/15/25/35/45 ps, period10ps, and retained bounds0..50ps qualifies for inference.
The actual painted default view says:

```text
Cursor 0 ticks × 1 ps · window 0..50
8 cycles · inferred clk period 10 ps (view heuristic) · extent 50 ps
```

The graph correctly shows five periods. This is a false cycle-count label, not
tick loss or incorrect cursor arithmetic. Reproduction and original native ANSI:
`/tmp/opencode/development-c-waveform-deep-02/clock-short-default-waves.{txt,ansi}`.
The probe's `clock-short.vcd` and stdout preserve exact inputs/results. Fix belongs
to A; C suggests qualifying the target when clamped rather than reporting an
achieved count of eight. No fix has been applied by C.

## Probe and evidence

Own new files: `reviewdocs/tests/development_waveform_probe.ml`, `dune`, and
`development-waveform-review.py`. The OCaml executable links production
`terminal_presentation` and calls original VCD parsing, actual `Waveform_view.input`,
cache remember/receive, `render_waves`, and `render_signals`. Python reconstructs the
painted ANSI cells and asserts graph glyphs/rows and visible exact values, rather
than trusting projection metadata alone. Synthetic controls are explicitly not
new FIFO/PT8 simulation evidence.

Final receipt: `/tmp/opencode/development-c-waveform-deep-03/receipt.json`.
Deep-02's84-check result is preserved; deep-03 adds actual native timestamp-editor
input at >2^53 and Int64.max_value, rather than only initializing cursor fields.
Build: switch5.2.0+ox, explicit Workbench root, `_build_pt8_workbench`, shared
`workbench-pt8-build.lock`, Dune `-j2`. No EDA, simulation or daemon in these probes.

Verified on actual render:

- Pulses straddling rendered inclusive cells0..9 and10..19 mark both edges;
  same-timestamp high/low glitch at cell start marks `#` despite exact final0.
  Same-timestamp pulse at inclusive last tick1030 marks the final plotted column.
  Cropping start to10 still compares the real prior state at9 and marks the edge.
- Hidden X then Z between sample endpoints marks its own whole lane unavailable.
  An adjacent known16-bit bus keeps its actual `000C` hex graph and row alignment.
- Native timestamp-editor entry9007199254740993, h/l to adjacent original ticks, and displayed
  binary1010/1011 remain exact in real Signals rendering. Int64.max_value is
  included and maps to the actual last plotted column. Full max-int64 Fit retains
  requested endpoints through180→32→180 rendered widths and cache reload; cells
  partition the full inclusive retained interval without a gap or overflow. Exact
  editor entryInt64.max_value renders a one-point endpoint window with1111; Fit
  then recovers the complete0..Int64.max_value retained range.
- Missing, irregular and ambiguous clocks fall back to whole-trace Fit with
  `no reliable clock inferred`; no synthetic cycle0 labels appear. Normal10ps
  clock defaults to80ps. Default restores inferred/fallback extent after manual
  pan and reload. Fit resize and cache restore preserve start/stop/span/cursor/basis.
- Four4096-bit aliases share a single1000-assignment history and actually render
  all four original rows within budget. Four unique such histories exceed the
  aggregate16MiB projection budget and paint `Graph unavailable`, including when
  all lanes are unknown. Failure preserves requested0..999 bounds.

The earlier synthetic C control receipt
`/tmp/opencode/development-c-waveform-01/receipt.json` additionally covers one-point
retention and explicit100000-event rejection. It is supplemental, not a replacement
for the new actual-render checks.

## Source and probe hashes

All hashes unchanged during the completed probe invocation. Full hashes for interfaces,
preferences, main and C scripts are in the receipt; central reviewed implementation:

| File | SHA256 |
| --- | --- |
| `terminal/waveform_time.ml` | `e44d50630c3c6840a62c3ee567cf87eaeac4b95ad0e49ac8ee9251108a725921` |
| `terminal/waveform_data.ml` | `5c580249a0e0be20ece375f0dc1a8ef647011bf1e3e1ffbbd72590ebd1eb45f6` |
| `terminal/waveform_view.ml` | `fef0af06d9966fb60f5279bbd889fbca6943bb1723f119501d36509b427d27f8` |
| C final native review probe | `2c78589a2dc4ab9cb8d46167db100ee3c3790a6d8e29904a96e91b260063b872` |

Failed harness bring-up `/tmp/opencode/development-c-waveform-deep-01` remains
untouched. Its high-cursor test used `(Reload)` instead of the OCaml sexp atom
`Reload`; the retained stderr clearly identifies C's harness syntax error. Corrected
only C's runner before completed deep-02. No production failure is inferred from it.

## Remaining scope

Reload here is the real in-memory waveform cache path, not a claim that waveform
time navigation survives process restart. Source review shows saved display prefs
hold Inline/Stacked layout; waveform cursor/window cache itself is process-local.
No production change requested solely to expand the existing preference schema.

## Actual native follow-through after regular config publication

B's regular configs passed real Discover in C's private store02. Current receipt
`/tmp/opencode/development-c-native-08/receipt.json` is explicitly **blocked**, not
passing, on a second integrated finding: real FIFO artifacts are `text/x-vcd`, but
`terminal/simulation_export.ml:49` excludes that media type. Actual selected-case
embedded-waveform palette action is absent. Source SHA256:
`dc697cfc613bd57c5aee2b0045a760f6c81e111853bad4ddc9af6ad7f7ed0bca`.
Native05 retains the original real action failure. No artifact MIME rewriting or
production admission changes were applied by C. This blocks real FIFO graph/pin
preservation acceptance; it does not block the independently rendered FIFO-shaped
synthetic controls above.

Diagnostic continuation native08 completed actual same-session FIFO normal and
mismatch plus PT8 two-case launches, real Workloads VCD/JSON handoff/seven zero
deltas, PT8 Default80ns/Fit13.07us/exact13C6 cursor, daemon history/artifact/registry
restart and **actual restarted client's Stacked display**. It verifies same-case
artifact hydration against original retained metadata rather than requiring a
byte-identical navigation sidecar before/after normal hydration. Exact original
and restored preference snapshots are retained. In-memory time navigation and
persisted display preference are tested and described separately.

Read-only raw closure/oracle audit passes:
`/tmp/opencode/development-c-native-audit-08/receipt.json`, explicitly retaining
`native_acceptance_passed=false`. Regular-config refresh controls with real retained
attempts/artifacts and both client preference files pass:
`/tmp/opencode/development-c-refresh-02/receipt.json` (72 durable state files,
two preference files preserved byte-exact across repeat/failed/successful refresh).

Native tested captured app pair is immutable generation
`/tmp/opencode/development-c-store-02/generations/913f0ce6f7984cb0b9d5d8a01d94df12`:
client `53d681a0baaee03a0be7ffc18ea517419cffff9f10f7f33cb0813da9a7581ebc`,
daemon `ec0108fd3ae65ac8bc8113462bfc1eb4dcdcbecf6410c144fbc982113f495a38`.
Manifest SHA256 `d2282b0f1be5f2e5ff9bbaa2587f7afa7b631c08f676b323a24cb0eef1409ab5`.
This matches A's final app handoff. Explicit later private refresh preserves that
old generation and every failed native receipt; it does not retroactively change
the tested app identity.
