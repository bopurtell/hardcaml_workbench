# PT.8 producer corrections — independent verification disposition

2026-11-05. **F1 and F2 from `pt8_waveform_producer_review.md` are verified
corrected in current source. No remaining blocker found in this bounded recheck.**
Original review script/document/evidence and session02 provider were preserved.
This disposition does not relabel the old provider or its executions as corrected.

## Original probe rerun, unchanged

```sh
python3 -B scripts/review-pt8-waveform-producer.py
```

Actual result: exit1 at the original source-identity assertion:

```text
AssertionError: pt8_workloads.py: current equals immutable session02 capture
```

Initial rerun directory: `/tmp/opencode/pt8-producer-review-pb2aymhn/`. The original
probe deliberately requires current sources to equal the old immutable session02
capture; that assertion precedes its contract probes. It is now false because C
corrected current sources and left the old provider immutable. This is not a new
validator failure and is not recorded as a passing run of the original harness.

The separate corrected recheck also invokes that **same unchanged script** and
retains its exact argv, exit code, stdout and traceback in the final evidence
directory below (`original-probe.stdout`, `original-probe.stderr`, `report.json`).
Original script SHA256:
`25b8f43efdd4bc0547e09f501386adc70baf97f9d81c24e65d5d8b407ca77605`.

## Corrected current-source independent probe

New review-only file:

```sh
python3 -B scripts/review-pt8-waveform-producer-corrections.py
```

Final evidence: **`/tmp/opencode/pt8-producer-correction-review-xzuyuni5/`**.
Result: **exit0;150 checks passed; zero findings;252 protected files hash-unchanged**.
Earlier passing149-check run before adding the captured original-probe invocation:
`/tmp/opencode/pt8-producer-correction-review-u8_o6nfv/`.

The new probe imports validator/publication functions directly from the **current
example source tree**, checks their module paths and that the provider calls that
same validator, and verifies current production hashes equal the new immutable
`session-waveforms-final-01` provider capture. Its real fixture inputs remain the
unchanged session02 direct Flops/Exact VCDs and raw stdout. No old provider is
substituted for current code, and no old execution is labelled corrected-provider
execution.

## F1 corrected: malformed admission and complete-stream parsing

The four original fixture files from
`/tmp/opencode/pt8-producer-review-y6yxh4gt/fixtures/` are reproduced **byte-for-byte**
and independently tested against current `validate_waveform`:

| Original mutation | Current validator rejection | Native parser still rejects |
| --- | --- | --- |
| `reg`→`real` for clk | unsupported interface variable kind/width | yes |
| Remove first upscope | waveform scope must be top-level tb only | yes |
| `bx &`→`x&` for q | scalar waveform assignment to a bus | yes |
| `[7:0]`→`[999:0]` | interface range disagrees with declared width | yes |

Each malformed fixture is also passed through the **current actual provider**
publication branch, with Runner output injected and its descriptor source hash/
size rebound to the changed bytes. All four:

- Emit no VCD Artifact and create no copied waveform file.
- Retain the independent JSON reference Artifact/file.
- Finish Failed with the exact syntax rejection message, demonstrating rejection
  is not merely stale-digest detection.

The strict parser was checked for hidden ignored input with **34 malformed stream
variants total**, including those four originals:

- Unsupported/plain header text, malformed extra declaration, duplicate code/name,
  wrong/nested/unbalanced scope, duplicate/wrong timescale.
- Unterminated/nested dump blocks, unexpected `$end`, timestamp inside a dump,
  unknown body directive and metadata directive in the body.
- Stray plain text at body start/middle/end; junk after a valid assignment or final
  timestamp; unterminated header/body comments.
- Negative/malformed time, undeclared code, overwidth vector, vector missing its
  identifier, NUL, and vertical-tab-separated input.

Every mutation is checked to actually change the input; every variant rejects.
Source inspection confirms header and body consume the complete token stream.
There is no regex extraction of only recognized header fragments or line-skipping
fallback. Ignoring a fully delimited date/version/comment body is explicit
permitted metadata behavior; unsupported directives/text outside those bodies
are rejected. Actual Icarus comments, its empty `$dumpall`, balanced `$dumpvars`,
and X/Z remain accepted in the retained real captures.

This is the bounded supported instrumentation format, not a claim of universal
VCD dialect acceptance or exhaustive parser fuzzing.

## F2 corrected: failed functional inspection remains distinct

Using current `pt8_workbench_provider.run` with injected Runner returns:

- `passed=False` plus a valid VCD/descriptor: JSON only, no waveform copy/event,
  Case Failed, attempt Failed.
- `passed=False` plus missing VCD/descriptor: same JSON-only Failed result.
- `passed=False` plus malformed VCD: same JSON-only Failed result.

All three retain the exact independent JSON reference bytes and the diagnostic
**`functional failure; inspect retained result`**. This proves failed inspection
is handled distinctly rather than accidentally becoming a VCD-validation error.
Exit0 remains the FS2 provider's normal protocol completion for a semantic failure.

Controls:

- `passed=True` with a valid capture still publishes the VCD and finishes Passed.
- Successful Flops followed by failed-inspection Exact retains the Flops VCD and
  both JSON references; Exact publishes no VCD; attempt finishes Failed.
- Event sequences and attempt IDs remain exact in all these provider probes.

The Runner result is deliberately injected to exercise this public branch without
new simulation. These are not labelled real failed hardware executions.

## Unchanged real captures and functional behavior

Both real session02 captures pass the corrected validator with **exactly their
original stored descriptors**:64,078 bytes;6028 changes; six signals;1ps;
time0..13,070,000ps;1307 cycles. Their previously published copies remain byte-equal.

The prebuilt production waveform parser rechecks both real files. All **31,368
six-signal before/after samples** still match those same executions' raw `TRACE`
stdout and directed controls. Each case retains519 unknown q phase samples.
Raw functional traces still equal historical `simulation-04`. The pure historical
default bench remains byte-identical for normal and ignored-workload modes.

No new simulator, emitter, inspector, daemon, Dune or EDA execution was needed.
The only external reader executable was the existing production waveform probe:

`_build_pt8_workbench/default/terminal/waveform_probe.exe`

SHA256 `390772188022803976fbe31a8b7571dec2007fbd8c03488e5c4df34bff07aa46`.

## Exact corrected source identity

Example paths relative to `/home/wayne/devel/jane/hardcaml_asic_example`:

| Source | Current / corrected-final-provider SHA256 |
| --- | --- |
| `scripts/pt8_workloads.py` | `329c1ff215ad2001f52e5d1a751838292b249308de7ecc96c0f1cf44bab3b811` |
| `scripts/pt8_workbench_provider.py` | `e70ab0990df43419993906c7c67506455651ea83157bbb8d232a1192c21259a4` |
| `scripts/pt8_workbench_runner.py` | `01e19a51ab7559af449eed1d28bec231e53c20ecd09ec905e4aaa86940eb1292` |

The first two deliberately differ from session02's old hashes
`4889f947…` / `273a6166…`. Current owner test source hash is
`4d9e1b9ff4f0d8c80856b84ba9fff6af335751cfd64833b56ccdf6257af9149e`; it was
read/hash-protected, not edited or rerun. The new independent probe SHA256 is
`a026156d098c24cc7276f21c37c8b996a6f4efde7186d22e2851eec009115cbf`.

The prior bounded after-final-check mutation, parent-symlink and multi-Runner
global-root observations are not claimed fixed by these two corrections. Their
original scope/disposition in `pt8_waveform_producer_review.md` remains unchanged;
none was a demonstrated normal immutable-session execution blocker.

Only this additional disposition and the new independent review probe were added.
No production edits, original review/evidence edits, old-provider changes, user
pair changes, or new simulated hardware. Final fresh corrected-provider/native
integration is a separate acceptance gate, not claimed by this retained-data review.
