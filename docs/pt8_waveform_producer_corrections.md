# PT.8 producer corrections — ready final capture

2026-11-05. Both blockers in
[A's independent review](pt8_waveform_producer_review.md) are corrected in the
example-owned producer. Original review probes/receipts and session02 were not
edited. **Final corrected provider capture is ready; final fresh native execution
is pending A's final frontend binaries.**

## F1: strict bounded supported-format admission

`hardcaml_asic_example/scripts/pt8_workloads.py:validate_waveform` now consumes
the complete token stream for the instrumentation's six-signal Icarus protocol,
rather than extracting a permissive subset of header fields.

- Header accepts date/version/comments, one1ps scale, only balanced top-level
  module `tb` scopes, six uniquely named/identified interface declarations of
  expected widths and `wire`/`reg` kinds. Other kinds (including `real`) reject.
- Scalar declarations have no range; buses must have this instrumentation's
  exact descending zero-based range (`[7:0]` or `[15:0]`). This also enforces
  consistency with declared width. Nested/vendor/storage declarations reject.
- Body retains actual Icarus comments, empty `$dumpall`, `$dumpvars`, timestamps
  and four-state values. Dump blocks must be balanced/non-nested. Timestamp and
  assignment forms are consumed explicitly; scalar writes to bus codes reject.
- Existing byte/event/expanded-value budgets, required six observed codes and
  final1307-cycle timestamp remain enforced. Token/directive lengths are bounded.

This is deliberately a strict validator for the emitted interface protocol, not
a universal VCD parser. The default bench and opted-in dump statements are unchanged.

## F2: functional inspection gates VCD publication

`hardcaml_asic_example/scripts/pt8_workbench_provider.py` now enters descriptor
validation/copy/Artifact publication **only when `passed` is true**. On an otherwise
valid Runner return with `passed=False`, JSON remains readable, case and attempt
finish Failed, and no VCD file or waveform Artifact is published. A preceding
successful case remains independent.

## Durable regressions and retained-data recheck

`scripts/test_pt8_waveforms.py` now has six passing tests. New controls cover all
four independent malformed fixtures, scope/dump balance, duplicate codes and
unknown header directives. The provider controls rebind mutated byte hashes and
sizes, ensuring rejection is due to unsupported syntax rather than stale digest
alone. Failed inspected return explicitly verifies JSON-only publication, no
waveform file, Failed case/attempt and the diagnostic message.

Command in the example checkout:

```bash
python3 -B scripts/pt8_waveform_correction_check.py
```

Retained correction receipt:

```text
.dev/asic-pt8-workbench/waveform-correction-fa4eba12e17540deb8557689b3bc3d2c/
  assertions.json
  tests.command.json / tests.stdout / tests.stderr
  sources.json
  preservation-before.json / preservation-after.json
  flops256.native.sexp / exact256.native.sexp
  {unsupported-real-type,missing-upscope,scalar-bus,bad-range}.vcd
  corresponding *.native.sexp
```

Both original real session02 captures still produce their exact stored descriptors
under the corrected validator and parse successfully in the production viewer.
All four malformed mutations now reject in both producer and production viewer.
These are retained original actual VCDs/private malformed fixtures, not new
simulations. Their same-execution trace semantics are independently established
by A's original review:31,368 signal samples match actual vvp stdout, including
unknown responses. No bench/stimulus/model change requires replaying that pair.

The unit syntax fixture runs Icarus against a clearly labelled stub; **zero new
real Flops/Exact simulations** were started.1034 preservation entries across
protected roots, session02 (excluding build caches), and original review sources/
receipts are hash-unchanged. The correction harness was subsequently extended
only with a `--verify-session` mode; the earlier executed harness hash remains
recorded accurately in `sources.json`.

## New immutable source-complete final capture

Example session: `.dev/asic-pt8-workbench/session-waveforms-final-01`.

```bash
opam exec --switch=5.2.0+ox -- python3 -B scripts/pt8_workbench_setup.py --session session-waveforms-final-01 --reuse-provider-session .dev/asic-pt8-workbench/session-final-review-01
python3 -B scripts/pt8_waveform_correction_check.py --verify-session .dev/asic-pt8-workbench/session-waveforms-final-01 --baseline .dev/asic-pt8-workbench/waveform-correction-fa4eba12e17540deb8557689b3bc3d2c
```

`final-capture-ready.json` confirms production capture/source hashes, tests equal
the source snapshot, private source root, unchanged old evidence, and unchanged
pinned ASIC generation `ee3af8de9f83418b9afed9c67e473e3c`. Setup's sole build was
the isolated example under shared `/tmp/opencode/example-pt7-build.lock`, switch
`5.2.0+ox`, `dune build -j 2 --build-dir _build_pt8_workbench`. No ASIC rebuild/EDA.

| Source | SHA256 |
| --- | --- |
| `scripts/pt8_workloads.py` | `329c1ff215ad2001f52e5d1a751838292b249308de7ecc96c0f1cf44bab3b811` |
| `scripts/pt8_workbench_provider.py` | `e70ab0990df43419993906c7c67506455651ea83157bbb8d232a1192c21259a4` |
| `scripts/pt8_workbench_runner.py` (unchanged) | `01e19a51ab7559af449eed1d28bec231e53c20ecd09ec905e4aaa86940eb1292` |
| `scripts/test_pt8_waveforms.py` | `4d9e1b9ff4f0d8c80856b84ba9fff6af335751cfd64833b56ccdf6257af9149e` |

Final source-snapshot JSON SHA256:
`9a3ff132252d21fbf900e69c4dc1fe86aac2645ecbda6ce71d7061d12bdc171d`.

## Next integration gate

Wait for A's guard corrections and final initial-X display decision/binary hashes.
Then use **this final session**, a new private runtime directory and the final
production native client to launch the fresh public workload pair once, open its
case-bound waveforms, verify signals/cursor/display, and record exact final source/
binary/attempt/artifact identity. Prior session02 native acceptance remains its own
historical receipt; it is not relabelled as corrected-provider/final-frontend work.

No user pair, old session, original review evidence, root configuration, pinned
provider generation or live process was modified/restarted. A's frontend code/tests
were not edited by this correction.
