# PT.8 waveform producer handoff

**Final acceptance complete:** corrected `session-waveforms-final-01` and final
client `2c301d20…` pass the fresh direct pair, source-only standard Plan, and actual
Testing JSON-cursor→same-case VCD native flow, including honest initial-X lanes.
See [final commands, receipts and hashes](pt8_waveform_final_acceptance.md).

**Correction milestone:** producer admission and failed-inspection publication
blockers are fixed. Corrected capture: `session-waveforms-final-01`. See
[producer corrections and source/test hashes](pt8_waveform_producer_corrections.md).
The session02 results below remain historical evidence of that earlier capture.

2026-11-05. Producer implemented; real direct and native acceptance pass.
Frontend owner may use this exact contract and retained evidence.

- FS2 event: `Artifact`, ID `flops256-waveform` / `exact256-waveform`,
  `case_id` the corresponding selected case, kind `trace`, media `text/vcd`,
  path `CASE-waveform.vcd` relative to FS2's supplied artifact directory.
  FS2 owns attempt-prefixing, copying into retained storage and transport hashes.
- The independent `CASE-result-reference` JSON artifact and schema stay unchanged.
  It is authoritative for Workloads and is not a waveform.
- Actual Icarus VCD from the same successful `vvp` execution, six explicit
  interface declarations: `tb.clk`, `tb.ena`, `tb.rst_n` (active-low **write
  command**, not memory reset), `tb.ui_in[7:0]` (address), `tb.uio_in[7:0]`
  (data low byte), `tb.q[15:0]` (response). Write data is address concatenated
  with the data byte. Unknown outputs remain unknown. No hierarchy dump.
- Producer seam: `bench(..., capture_waveform=False)` and
  `simulate(..., capture_waveform=False)`. WB Runner explicitly opts in.
  Dump path `waveform.vcd` is resolved in that case's private simulation cwd.
- Retained beside `result.json`: `waveform.vcd`, `waveform.json` descriptor
  (path, byte count, SHA256, signals, event count, scale, final time, cycles).
  Producer admits only complete six-signal captures, <=8MiB, <=500,000 changes,
  <=64MiB expanded value bytes; viewer limits inspected in
  `terminal/waveform_data.ml` (4096 declarations / width4096).
- Publication follows successful execution, functional inspection, descriptor
  validation and validated copy. Failed/cancelled/missing/oversize captures do
  not announce a waveform. Existing session captures are never rewritten.

## Initial real results / ready for frontend acceptance

Ready session: example `.dev/asic-pt8-workbench/session-waveforms-02`.
It is source-complete, private, and reuses the pinned generation
`ee3af8de9f83418b9afed9c67e473e3c` from `session-final-review-01`.
No ASIC build was performed. Setup's only Dune was `build -j 2` with
`_build_pt8_workbench` under the shared example lock, switch `5.2.0+ox`.

Real direct receipt:
`session-waveforms-02/waveform-direct-84166e76c12147508792f756556fea1c/assertions.json`.
Both Flops and Exact pass functional inspection, counters1307 cycles /525 reads /
262 writes /787 operations /2083 defined observations /latency1. Parsed raw trace
rows, including undefined outputs, equal the original `simulation-04` traces.
Each VCD is **64,078 bytes, six declarations,6028 changes**, scale1ps,
time0..13,070,000ps. Copied artifact bytes equal the retained actual simulator VCD.

Direct Flops SHA256: `e246f49adc4d92f9c3c05c8844ca42ff3c3a175e251863ddf2933fd6c15b8f50`.
Direct Exact SHA256: `2facecda062b5e92ed1ac0a870dffa484db61a12615221bf2e72bd15016c2c63`.
These include Icarus's real execution date metadata; fresh runs get fresh hashes.

Missing Exact model retains successful Flops's two artifacts and no Exact
artifact. Actual SIGTERM cancellation reaps the child, finishes Incomplete and
announces no artifacts. Root configs/selected executables, root modifications,
old provider captures/configs and original simulation evidence:140 files hash-
checked unchanged against `/tmp/opencode/pt8-waveform-preservation-01.json`.
New immutable provider matches every captured hash.

Focused controls: `python3 -B scripts/test_pt8_waveforms.py -v` (example cwd),
five tests passing including comparison with the immutable historical bench
(normal and ignored-workload defaults), plus subcases for missing/empty/oversize/truncated/
wrong-signal/wrong-time/nonmonotonic/undeclared changes, byte changes, failed
execution and cancellation; default bench bytes are unchanged after removing
only the two explicitly opted-in dump statements.

Preserved initial failure: `session-waveforms-01/waveform-direct-7c699bcd7dda48099ba4afb695589ec9/`.
The first validator rejected Icarus's empty `$dumpall` and comment block; neither
case published an artifact. Corrected code accepts these standard directives.
Session01 was not rewritten; session02 was created afresh.

## Final production native acceptance

After the frontend selection changes were present in the prebuilt production
terminal, the real HTTP/PTY harness passed in:

`session-waveforms-02/waveform-native-16c4bda78c4042ab95e82c12879da2b3/`

- `assertions.json`: pass, protected140 files unchanged, immutable provider
  unchanged, EDA0. Binary SHA256 identities and exact invocation retained.
- Actual Testing cases→seed→confirmation form launched fresh Exact attempt
  `sim-ddff7141b597564ddc8d54f8e46919578d19aaf2a22fad11eba8ffab287f80c6`.
- Actual FS2 attempt/case-bound VCD fetched in16384-byte pages;64,078 bytes,
  SHA256 `a595541dca4ca76fda94c2b0c0fb7bfca57c4ca82f50fe31d752ea9cc30069a8`.
- Production **Open embedded waveform** action parses six signals. At time0,
  `q` is correctly X. Current installed two-state renderer reports graph
  unavailable for a selected X-containing signal; binary/X cursor values remain
  available. This is an honest existing renderer limitation, not a capture failure.
- `:2595000` moves to the first defined read response (1ps ticks). Actual waves
  render `ui_in=13`, `uio_in=00`, `q=13C6` hex. `l` advances cursor to2595001.
  Retained frames `waveform-parsed.txt`, `waveform-cursor-2595000.txt`,
  `waveform-cursor-2595001.txt` and their raw ANSI prove parsing and native rendering.
- Actual **Open dedicated Waveforms workspace** displays Ready1ps, six signals,
  pinned correct VCD, Waves and matching attempt Logs (`dedicated-waveforms.txt`).
  Dedicated view initially opens at0 and therefore honestly displays the initial
  X renderer limitation. Move to2595000 or deselect `q` to view the early controls.
- Harness starts/stops only its own daemon/client under a fresh runtime directory
  inside session02. The old user session and live pair were not restarted.

Four earlier native harness failures remain in session02 (`waveform-native-*`):
stale expected project label; oversized HTTP page request (corrected to16KiB);
artifact-only contextual command attempted from Catalog (use exact-artifact
palette action); compressed signal names / genuine initial X render limitation
(corrected assertions and exercised defined read response). All receipts, PTYs,
and any actual runs remain intact.

### Exact commands (example checkout cwd)

```bash
python3 -B scripts/pt8_waveform_acceptance.py --baseline /tmp/opencode/pt8-waveform-preservation-01.json
python3 -B scripts/test_pt8_waveforms.py -v
opam exec --switch=5.2.0+ox -- python3 -B scripts/pt8_workbench_setup.py --session session-waveforms-02 --reuse-provider-session .dev/asic-pt8-workbench/session-final-review-01
opam exec --switch=5.2.0+ox -- python3 -B scripts/pt8_waveform_acceptance.py --session .dev/asic-pt8-workbench/session-waveforms-02 --preservation /tmp/opencode/pt8-waveform-preservation-01.json
opam exec --switch=5.2.0+ox -- python3 -B scripts/pt8_waveform_native_acceptance.py --session .dev/asic-pt8-workbench/session-waveforms-02 --preservation /tmp/opencode/pt8-waveform-preservation-01.json
```

Use the normal example launcher with
`--session .dev/asic-pt8-workbench/session-waveforms-02` to open this capture-enabled
session. Do not reuse another session's discovery/state. The scripts use fresh
runtime subdirectories for each test. This producer handoff does not substitute
for coordinator independent review of frontend cross-case/wrong-attempt tests.
