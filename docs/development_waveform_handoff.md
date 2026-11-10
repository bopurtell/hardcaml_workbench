# Development waveform API handoff (A)

2026-11-05 — initial implementation complete and focused verification PASS.
Ready for C's independent integration checks/review.

Ownership: A owns waveform_time/data/view/probe and minimal main palette hooks.
C owns integrated acceptance scripts. No example or provider edits by A.

Implemented public APIs (all in `terminal_presentation`):

- `Waveform_time.create_window ~columns ~start ~stop`: exact inclusive requested
  bounds, independent of width. Existing `create ~code` remains available.
- `cell_bounds`, `cursor`, `start`, `stop` describe that same mapping.
  `scale` returns `Window_cells { compressed : bool }` for this API; do not
  interpret variable cell intervals as a uniform legacy integer raster.
- `Waveform_data.project_window ~signals ~cells`: bounded projection over an array
  of inclusive original-tick cell bounds; returned lanes have exact samples and
  original-event transition summaries. Unknown excursions mark their entire lane.
- `Waveform_data.signal_samples t ~signals ~times`: exact original values,
  returned in signal order, then timestamp order; bounded independently. This is
  intended for C's same-execution sample checks, not graph interpolation.
- Existing `value_at` and `to_waveterm` retain their exact semantics.

`projected_lane = { signal; samples : string option array;
transitions : int array; reason : string option }`. Transition counts saturate at2:
0 stable,1 edge,2 dense. Samples are exact values at each cell's first timestamp;
they are NOT the original-event summary. Graph uses `|`/`#` original-event marks
instead of pretending sampled endpoints prove stability. Known stable buses retain
hex labels where room permits. No two-state conversion of marked lanes.

Projection bounds:16 selected declarations,4096 cells,100000 inspected history
assignments including initial values,16MiB combined inspected/projected payload.
Aliases share both storage and budget. Original window events, including overwritten
same-timestamp assignments, count. Initial dumpvars before the first actual assignment
does not create a fictitious unknown excursion; final state at inclusive start is
always inspected. A genuine X/Z excursion after initialization still marks its lane.

`signal_samples` signature:
`t -> signals:signal list -> times:int64 array ->
 (signal * string option array) list Or_error.t`.
Limits64 declarations,100000 returned signal/time pairs,16MiB payload. Batch larger
independent checks explicitly. None is uninitialized; values retain original binary/X/Z.

UI: `f` / Waveform: Fit full trace; `d` / Waveform: Default extent. Default uses
eight validated inferred clock periods, otherwise full-trace Fit. h/l and colon
remain original VCD ticks. Resize preserves requested bounds.

Probe CLI compatibility remains `waveform_probe FILE START STOP [QUERY_TICK ...]`.
Existing `signals/.../values` are exact original samples (not sampled graph values).
Top-level `projection` exposes80-cell original-event saturated transition arrays and
lane reasons (or an explicit error). `WB028_VIEW=1` adds frames named `default`,
`fit`, `fit-narrow`, plus previous cursor/zoom cases. Each has `start`, `stop`,
`physical_extent`, `extent_basis`, `cell_bounds`, exact cursor location/values and
ANSI hex. `mapping` is `inclusive-original-ticks`; obsolete `raster_code` is removed.
Probe exact `conversion_error` on long windows is EXPECTED: exact conversion API's
million-tick limit is unchanged, while independent graph projection supports Fit.
No C code should depend on renderer sample indices as physical clock cycles.

Final evidence (each is a private retained-byte replay, zero simulations):

- PT8: `/tmp/opencode/development-waveform-a-8nco80aj/receipt.json`:11 checks,
  80ns default,13.07us Fit, exact2595000/2595001 and13C6 binary response,
  quick/dedicated palette actions, genuine120→230-column resize and byte/hash
  preservation. Default graph has visible clock edges; Fit has dense cells and
  q's unknown marker remains local to its row.
- FIFO: `/tmp/opencode/development-waveform-a-vkifuy22/receipt.json`:9 checks.
  This retained real directed trace is1ns/period10ticks, not assumed2ticks:
  default80ns, Fit73295ticks. `-clock` is the installed Cyclesim clock name.
- Prior mixed-row regression: `/tmp/opencode/pt8-mixed-rows-pty-xxr7vp3j/checks.json`:
  9 checks pass, exact initial X sidebar and later defined response, quick/dedicated
  known clock graph and q row alignment. Only stroke/clock-label oracle was updated.
- The inherited PTY helper hardcodes120x40. A's harness overrides decoding to match
  actual dimensions; its final resize test genuinely changes120→230 columns.

Earlier failed harness attempts remain intact: `development-waveform-a-re6y2iyz`
selected the clock's inference-description row instead of its graph row;
`pt8-mixed-rows-pty-qo0xi3io` had the same obsolete row oracle. Fixed the harnesses,
not the retained evidence or production outputs. Earlier pre-resize-oracle receipts
are preserved and superseded by the final receipts above.

## Verification and binary handoff

All commands used switch `5.2.0+ox`; all Dune calls explicit `-j2`, root
`/home/wayne/devel/jane/hardcaml_workbench`, build dir `_build_pt8_workbench`, and
`flock /tmp/opencode/workbench-pt8-build.lock`.

- `dune build … terminal/main.exe terminal/waveform_probe.exe daemon/main.exe @terminal/lint`:PASS.
- `dune runtest … terminal`:PASS, including endpoint/handoff/restoration tests and
  existing45-check frontend regression. New inline tests cover [0,max_int64],
  >2^53/near-max cursor mapping, single point,1/2/5/80/4096columns, exact compact
  physical labels,16-lane/4096-cell/event/payload limits, alias storage/budget,
  same-timestamp pulses/X, unknown excursion between sample endpoints, mixed rows,
  inferred periods2/10000, Cyclesim initialization, ambiguity and Fit/resize.
- OCamlformat applied to A's OCaml files and minimal main hooks; lint passes.
- Probe replay on both actual traces: exact samples PASS; default/Fit/Fit-narrow
  requested endpoints agree. PT8 parse≈2.1ms, FIFO≈11.7ms in this one invocation
  (observations, not performance guarantees). PT8 exact conversion's long-span
  rejection remains separate from successful full-span graph projection.

Final binary SHA256:

| Binary under `_build_pt8_workbench/default/` | SHA256 |
| --- | --- |
| `terminal/main.exe` | `53d681a0baaee03a0be7ffc18ea517419cffff9f10f7f33cb0813da9a7581ebc` |
| `daemon/main.exe` | `ec0108fd3ae65ac8bc8113462bfc1eb4dcdcbecf6410c144fbc982113f495a38` |
| `terminal/waveform_probe.exe` | `2424a606b31fe393b7eb9b18b97d6e747baaba4ad24b12d0410dc08b79380dd8` |

Focused PTY entrypoint:

```sh
opam exec --switch=5.2.0+ox -- python3 -B terminal/test_development_waveform_pty.py \
  --daemon _build_pt8_workbench/default/daemon/main.exe \
  --client _build_pt8_workbench/default/terminal/main.exe \
  --vcd EXACT_RETAINED_FILE --period ORIGINAL_TICKS --last ORIGINAL_LAST_TICK
```

For PT8 add `--response 2595000 --binary-value 0001001111000110`.
This fixture provider only replays the named bytes through FS2; it is not the
combined development provider or evidence of a new FIFO/PT8 execution.

A changed waveform_time/data/view/probe, minimal main palette hooks, this handoff,
the focused PTY script and the mixed-row stroke oracle. No backend schema,
navigation persistence, provider/example/config/EDA/live-runtime/Git changes.

## C review corrections — 2026-11-05

Both findings from `reviewdocs/tests/development-waveform-review.md` corrected:

1. `default_extent` distinguishes clipping before its overflow-safe span
   calculation. Normal windows retain `8 cycles`; short windows say
   **`8-cycle target (clipped to trace)`**, alongside the actual physical extent.
   No achieved cycle count is invented. New regression paints the exact reviewed
   0..50ps/10ps clock trace, asserts50ps extent and clipped target, and rejects the
   old achieved-eight-cycle label after Fit→Default too.
2. `Simulation_export.vcd_media` now explicitly admits **`text/x-vcd`**, the real
   native FIFO MIME, alongside the three previous exact MIME aliases. Identity,
   SHA256, size, transport and parsing checks are unchanged. New regression checks
   all four aliases, MIME lookalikes/JSON/FST rejection, malformed/missing hashes,
   empty and oversize payload rejection.

Reverification PASS:

- Formatting, `@terminal/lint`, app/probe build and `dune runtest terminal`, using
  the same shared lock/switch/root/build-dir/`-j2` policy above.
- Unchanged C native probe and its original deep-03 `clock-short.vcd` fixture:
  actual rendered0..50ps window says clipped target and extent50ps, never `8 cycles`.
- FIFO retained-byte production PTY using original **text/x-vcd** metadata:
  `/tmp/opencode/development-waveform-a-m0ew2ips/receipt.json` —9 checks PASS,
  embedded and dedicated admission, default/Fit/palette/resize and byte/hash checks.
  The harness now accepts an explicit MIME and verifies returned artifact metadata
  equals it; it no longer masks FIFO admission behind a text/vcd replay descriptor.
- PT8 regression on corrected app:
  `/tmp/opencode/development-waveform-a-901h0h6h/receipt.json` —11 checks PASS,
  including80ns/13.07us,13C6 and the one-original-tick cursor step.

C runner note: its line146 currently uses the literal `8 cycles` as a proxy for
whether clock inference happened. That predicate must recognize a clipped inferred
target too; otherwise it conflicts with its own line151 short-trace check. A did
not edit C's scripts, findings, fixtures or prior receipts. Full combined native
acceptance and independent re-review remain C's responsibility.

Corrected app handoff SHA256 (supersedes the initial app hashes above):

| Binary under `_build_pt8_workbench/default/` | SHA256 |
| --- | --- |
| `terminal/main.exe` | `896cee9b6546be5c5d7fcd132306a55cf33cbc43d1c25edbd7cea9c467bd7a42` |
| `daemon/main.exe` | `ec0108fd3ae65ac8bc8113462bfc1eb4dcdcbecf6410c144fbc982113f495a38` |
| `terminal/waveform_probe.exe` | `61bf274e52ecac490d538cd9c57fb52eb38a5a99f6233ee319cf2889723e2caa` |
| `reviewdocs/tests/development_waveform_probe.exe` | `f474df00f9dd09d5b5b26636edfc8148e4db6e40d8fcbd7b6917b5e75c7e4b94` |

This correction additionally owns the minimal `simulation_export.ml` MIME alias
and its admission regression. No producer artifact metadata rewriting is needed.
