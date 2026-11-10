# PT.8 waveform producer — independent frontend-owner review

2026-11-05. **Two contract blockers reproduced. Real retained Flops/Exact captures
pass the independent same-execution check.** C's production code, tests and
original evidence were not edited. No new hardware simulation was needed.

Reviewed the producer handoff in this checkout and the example's
`scripts/pt8_workloads.py`, `pt8_workbench_runner.py`,
`pt8_workbench_provider.py`, owner tests, direct receipt and native receipt.
Example paths below are relative to
`/home/wayne/devel/jane/hardcaml_asic_example`.

## Reproduction

New independent probe, in **Workbench**:

```sh
python3 -B scripts/review-pt8-waveform-producer.py
```

Optional arguments: `--example PATH`, `--session session-waveforms-02`,
`--probe PATH_TO_PREBUILT_WAVEFORM_PROBE`.

Final run: `/tmp/opencode/pt8-producer-review-y6yxh4gt/`.
**2681 control checks passed; five finding instances, grouped into the two
blockers below. Exit status 1 intentionally reports findings.**
`report.json` contains exact errors, source hashes, declarations, observations and
published artifact records. The `.native.sexp` files are outputs of the production
`waveform_probe.exe`, not another VCD parser. Private provider probes inject only
the Runner result and explicitly identified mutation boundaries; actual provider
descriptor validation, copying, digest checks and event generation execute.

The probe invokes no Dune, simulator, emitter, inspector, daemon or EDA tool. The
existing prebuilt `_build_pt8_workbench/default/terminal/waveform_probe.exe` parses
retained originals and private mutated copies. No original acceptance script was
rerun. Protected source/config/history/session/evidence files: **1059 hash-checked
unchanged** before/after. User pair and old session configs were not changed.

## Blocker F1 — Medium: producer admission can publish VCDs the embedded parser rejects

Locations: `scripts/pt8_workloads.py:167–210`, especially the header regex at
174–181 and body admission at194–200;
`scripts/pt8_workbench_provider.py:70–84` uses that validator twice.

The validator checks extracted widths/names and the presence/count of scope and
timescale strings. It does not parse balanced scopes, restrict variable kinds,
validate ranges against widths, or require scalar changes to target scalar
declarations. Four **separate single-edit** mutations of the actual retained
Flops VCD are admitted:

| Mutation of the real file | Production parser failure |
| --- | --- |
| `$var reg 1 ! clk` → `$var real 1 ! clk` | `Unsupported VCD: variable kind real` |
| Remove the first `$upscope $end` | `Unclosed scope` |
| Initial `bx &` → `x&` for16-bit `q` | `Scalar assignment to a bus` |
| First `[7:0]` → `[999:0]` | `Signal range disagrees with declared width` |

For **each** fixture the independent probe computes its new descriptor through
the real producer validator, then passes that private output to the real provider
publication branch. Both descriptor equality and validated-copy checks pass;
`flops256-waveform`, kind `trace`, media `text/vcd` is emitted and the run finishes
Passed. Native parsing of those exact bytes fails as shown above.

Repro files in the final evidence directory:

- `fixtures/{unsupported-real-type,missing-upscope,scalar-bus,bad-range}.vcd`
- Corresponding `*.native.sexp` outputs.
- `publish-TYPE/events.sexp` and `publish-TYPE/artifacts/flops256-waveform.vcd`.

**Impact:** producer's “validated supported six-signal capture” guarantee is
weaker than the frontend contract. Size/hash correctness does not imply VCD
admission. These are controlled malformed-input cases; no malformed file was
observed in the actual Icarus captures.

**Required correction:** validate the complete bounded syntax used by this
instrumentation (including balanced scopes, supported types, exact width/range
agreement and assignment forms), or use a compatible strict parser at admission.
Add these four negatives to the owner's controls. Preserve actual Icarus metadata,
empty `$dumpall`, comments, unknown values, and existing resource budgets.

## Blocker F2 — Medium: functional failure still publishes the waveform

Location: `scripts/pt8_workbench_provider.py:60–85`.

The provider receives `(output, reference, passed)` but does not consult `passed`
until **after** copying/announcing both artifacts. A Runner result with
`passed=False` and an otherwise valid retained VCD/descriptor produces:

1. JSON `Artifact`.
2. VCD `Artifact` (`flops256-waveform`, `trace`, `text/vcd`).
3. `Case_finished Failed`.
4. `Finished Failed`.

Repro: `functional-failure/events.sexp` in the final evidence directory. The probe
injects the documented Runner return value; it does not assert that the retained
passing real captures failed. `Runner.run:109–116` explicitly supports that return
path after public functional inspection. Existing tests inject an execution
exception and cancellation, but not a successful execution/failed inspection
return value.

**Impact:** violates handoff's “same successful execution, functional inspection,
then waveform publication” rule. The frontend admits available VCDs independently
of attempt outcome, so the Artifact event is meaningful, not just a leftover file.
The preceding Flops capture in a later Exact-failure attempt is a different case:
retaining the already successful Flops artifact is correct.

**Required correction:** gate waveform publication on successful functional
inspection before the copy/Artifact branch. Keep the JSON result available for
diagnosis according to the existing result-reference policy; preserve per-case
failure reporting and preceding successful case artifacts.

## Positive independent acceptance of the real captures

Original direct receipt:
`.dev/asic-pt8-workbench/session-waveforms-02/waveform-direct-84166e76c12147508792f756556fea1c/assertions.json`.

For **both** real Flops and Exact:

- Recomputed the descriptor and compared it with `waveform.json`, the receipt,
  and the FS2-published copy.64,078 bytes;6028 value changes; six declarations;
  1ps scale; time0..13,070,000ps;1307 cycles.
- Production parser reads exactly `tb.clk`, `tb.ena`, `tb.rst_n`,
  `tb.ui_in[7:0]`, `tb.uio_in[7:0]`, `tb.q[15:0]`, widths1/1/1/8/8/16.
  Expanded production history value bytes:26,595, well below64MiB. Events are
  below500,000; byte size below8MiB; declarations/widths below viewer limits.
- Queried **every cycle** at `cycle*10000+4000` and `+9000` ps through the
  production parser. Compared clk/ena/rst_n/address/data to that run's workload,
  and full16-bit four-state `q` to that **same vvp execution's raw `TRACE` stdout**.
  **15,684 signal samples per case,31,368 total**, all equal. Each case has519
  unknown-response phase samples; unknowns are neither zeroed nor ignored.
  `rst_n` is the inverted write command, not a memory initialization reset.
- Reparsed the raw driver output and compared it with both retained `trace.json`
  and original `acceptance/pt8-workloads/simulation-04/POLICY/trace.json`.
  Directed operations and counters remain unchanged:1307 cycles /525 reads /
  262 writes /787 operations /2083 defined observations /latency1.
- Read actual execution commands: vvp runs with cwd equal to the case's private
  directory and the compiled simulator comes from that directory. The waveform
  is from that execution; no replay-derived waveform is used for this check.

Actual direct VCD SHA256:

- Flops: `e246f49adc4d92f9c3c05c8844ca42ff3c3a175e251863ddf2933fd6c15b8f50`.
- Exact: `2facecda062b5e92ed1ac0a870dffa484db61a12615221bf2e72bd15016c2c63`.

Historical default bench: compiled only the **pure historical `bench` function**
from `session-final-review-01/provider/scripts/pt8_workloads.py`; both normal and
ignored-workload defaults match current default bytes exactly and contain no dump
statement. Removing precisely the two opted-in dump statements from the enabled
bench yields those same defaults. No historical bench was regenerated on disk or
simulated.

Read original real failure/cancellation evidence independently:

- Missing Exact model: terminal Failed; only preceding successful Flops JSON/VCD
  Artifact events are present.
- Actual cancellation: terminal Incomplete, exit130, no Artifact events or files.
  Original command receipt records the child PID reaped by C's test. This review
  verifies that retained receipt; it does not reenact or claim to observe reaping.

Read native receipt
`session-waveforms-02/waveform-native-16c4bda78c4042ab95e82c12879da2b3/assertions.json`;
independently hashed its `transport.vcd` (64,078 bytes,
`a595541dca4ca76fda94c2b0c0fb7bfca57c4ca82f50fe31d752ea9cc30069a8`) and parsed it with
the current production parser at0/2595000/2595001. The original native PTY receipt
remains C's evidence, not a new UI execution by this review.

## Other negative controls that pass

- Missing/empty/oversize/truncated capture; unknown change code; wrong final time;
  backwards timestamps; wrong declaration width are rejected.
- Exactly8MiB and exactly500,000 changes are admitted; the next byte/event is
  rejected. These are private mutated budget fixtures, not claimed simulations.
- Direct waveform symlink rejected.
- Descriptor byte count, path, SHA256, cycles or signal-width changes prevent VCD
  publication. A descriptor path `../../outside.vcd` is not used to choose a file;
  the waveform path is fixed and descriptor equality fails.
- A source-byte change before provider validation and a mutation immediately
  after source validation/before copying both prevent waveform publication.
- Runner execution exception and Runner cancellation publish no VCD.
- Path-like case IDs `../flops256` and `/flops256` are rejected.

## Bounded mutation/root observations — not additional current-session blockers

These were tested rather than inferred as arbitrary filesystem threats:

1. **After-final-check mutation:** a deterministic hook computes the real final
   destination SHA, then changes that private destination to `not a VCD\n` before
   returning the captured hash. The provider announces the waveform. This proves
   no atomic validation/publication snapshot against a concurrent writer, but the
   probe injects that writer; it does not establish a normal-run writer or a
   production backend race. Earlier mutation gates above do reject changes.
   Evidence: `late-copy-mutation/`. Do not interpret the double validation as a
   guarantee against writes after its final check. Publication immutability relies
   on the private-directory/single-writer assumption.
2. **Parent symlink:** replacing only a private fixture's `output/flops` parent
   with a symlink to a sibling fixture directory still permits publication. A
   pre-existing symlink at a private Runner root's
   `.dev/asic-pt8-workbench/workloads` also directs allocation into the sibling
   store. No arbitrary external directory is touched. Final-file symlink rejection
   is not an ancestor/root-confinement guarantee. Normal session02 setup was not
   found to install such links.
3. **Multi-Runner root mutation:** `Runner.__init__:25–27` mutates module globals
   `ROOT`/`STORE`; `Runner.run:78` and default `command` cwd read those globals.
   Construct A(rootA), construct B(rootB), then run A: A writes its request under
   B's store while retaining A's emitter/generation. Probe stops at the first
   emitter command, before any executable/hardware work. Current provider creates
   and runs each Runner sequentially, so this is a reusable/multiple-instance
   limitation, not a reproduced root switch in the real session. Instance-local
   roots would remove it if concurrent/reused instances are supported later.

## Source identity / scope

Current C production sources equal session02's immutable provider copies:

| Example source | SHA256 |
| --- | --- |
| `scripts/pt8_workloads.py` | `4889f9470cfc4e02d9c10696e16917d4116cfe286b2498f632465e5b8ab9c40c` |
| `scripts/pt8_workbench_runner.py` | `01e19a51ab7559af449eed1d28bec231e53c20ecd09ec905e4aaa86940eb1292` |
| `scripts/pt8_workbench_provider.py` | `273a6166445147a7f8e58182bb463d79aef0273be653f4e43647b6692b77f68f` |

Owner test source currently has SHA256
`efe2ff2d964eb18a9c4581aa28ee3a80f01a0a26ccb1d0b1a05d3080ee03bffd`, while the
session manifest records `77f415f27ef9c51be86b60eb3f77ed4eb10d754c5ed0ecd5a2d8e35251db6857`.
The present source includes the historical-default comparison. This difference
is recorded, not overwritten; review did not run or modify either owner test copy.

Independent harness bring-up failures remain under `/tmp/opencode/`:
`pt8-producer-review-by6umhe_` assumed tests were in the provider subset;
`kvhxeigr` incorrectly required later owner tests to equal the session manifest;
`0repihz3` initially omitted VCD ranges in expected production signal names.
Corrected only the new review harness. Earlier completed finding run:
`pt8-producer-review-3gu9o1or/`; final expanded run is `y6yxh4gt` above.

Only the new Workbench independent probe and this review document were added for
this review. No C source/test, original evidence, provider capture, root config,
old session, or user process was modified. No Git command was used.
