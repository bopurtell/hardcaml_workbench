# PT.8 frontend corrections and mixed known/X/Z rendering — A final milestone

2026-11-05. Addresses R1/R2 in
`docs/pt8_waveform_frontend_independent_review.md` and the real PT8 initial-X
usability issue. Original independent review sources, tests, receipts and documents
were left intact. C's producer changes are separate.

## R1: preserve restored semantic intent

- Testing now retains original artifact metadata alongside the existing legacy
  ID/SHA/size identity. Restored artifact admission compares original attempt,
  case, kind, MIME, SHA and size against the observed artifact. Changed/missing case
  or changed MIME cannot turn that saved cursor into permission to open a sibling.
- Navigation schema1 has an additive, default-empty `testing_artifacts` map keyed
  by workspace. Existing files still decode. New saves retain the original metadata
  even while the artifact is unavailable, rather than overwriting it with a changed
  observation. Legacy three-field identities remain supported.
- Legacy waveform restoration also refuses sibling fallback when its saved artifact
  is no longer an admitted same-case VCD. The typed PT8 JSON result-reference path
  remains eligible for its intentional same-case waveform handoff; a restored
  arbitrary non-VCD cursor cannot authorize a waveform replacement.
- The unavailable intent remains selected and visible. An explicit artifact
  selection clears restoration constraints and can select a replacement. The
  general JSON cursor, Workloads inspection and general export remain separate.

Files: `terminal/testing_workspace.{ml,mli}`,
`terminal/navigation_preferences.{ml,mli}`, `terminal/workspace_host.ml`.

## R2: one complete eligibility predicate for waveform commands

`Testing_workspace.waveform_eligible` is shared by the default waveform selector
and host explicit action generation. It requires the exact selected attempt,
selected case present in **both captured selection and observed rows**, available
supported bounded VCD metadata, exact observed artifact, and valid restored intent.

Multiple eligible VCDs within that case still get separate embedded/dedicated
palette commands. The palette is not reduced to the current cursor. General
artifact export commands remain independent.

Main's actual quick-open and dedicated-pin entry points now recheck current
Testing eligibility or an exact frozen quick/dedicated investigation identity.
Stale arbitrary artifact actions do not create a viewer/pin. Dedicated picker
metadata observation also rejects a case absent from captured selection or
observed rows; picker retargeting retains the pinned optional case. Frozen pin
reloads preserve their exact identity rather than following current Testing rows.
Existing project/client/daemon/request/epoch and digest fences remain in place.

## Default rendering: known controls remain visible with q=X

**Implemented a bounded row-preserving fallback.**

- The ordinary all-known waveform renderer is unchanged.
- `Waveform_data.classify_window` classifies each selected lane over the exact
  inclusive window without converting unknown values to Bits. It enforces the
  existing aggregate conversion budgets, including affected lanes and identifier
  aliases; fallback does not reset budgets per signal.
- Known signals are still converted/rendered together by the installed renderer.
  Their existing two-row scalar / three-row bus lane glyphs are inserted back into
  the original selected ordering. Unknown/uninitialized lanes occupy exactly the
  same lane height, with their original adjacent label.
- An affected row says **`X/Z in window; no graph`** or
  **`Uninitialized in window; no graph`**. It does not display a fabricated binary
  graph. Exact four-state cursor values remain in Signals/the value footer.
- No temporal four-state plotting was added: an affected lane is marked for the
  whole current window. Moving to a window with fully defined values restores its
  ordinary graph automatically, without deselecting/reselecting it.
- Resource/unsupported rendering failures can still show an honest global failure;
  a normal X/Z lane alone no longer does so. The general `to_waveterm` API still
  rejects X/Z conversion, preserving its two-state contract.

**Actual real PT8 default at time0:** quick and dedicated views show the known
clk/ena/write/address/data lanes, with `q` aligned to its X/Z marker. The selected
q value remains sixteen X bits. The initial 1ps-tick window is shorter than the
first clock transition, so the known controls correctly appear as constant rails
and bus values in this default window. No initial output is initialized/sanitized.
At2595000ps, q is defined and its ordinary graph returns. Returning to0 restores
only the q marker; known controls stay graphed. No initial generic
`Graph unavailable` screen is needed for this trace.

Files: `terminal/waveform_data.{ml,mli}`, `terminal/waveform_view.ml`.

## Tests and final commands

All Dune operations used switch5.2.0+ox, explicit `-j2`, the shared lock and the
designated build directory. Final build / complete terminal checks passed:

```sh
flock /tmp/opencode/workbench-pt8-build.lock opam exec --switch=5.2.0+ox -- dune build -j2 --build-dir=_build_pt8_workbench terminal/main.exe terminal/waveform_probe.exe terminal/workloads_handoff_probe.exe daemon/main.exe review_pt8_waveform_frontend/review.exe review_pt8_waveform_frontend/async_review.exe @terminal/runtest
_build_pt8_workbench/default/review_pt8_waveform_frontend/review.exe
_build_pt8_workbench/default/review_pt8_waveform_frontend/async_review.exe
```

- Original independent C probes: **72 observations, zero findings**, including
  all three R1 drift variants and R2. All four async export checks pass.
- Extended actual-FS2 capture/handoff probe covers both legacy and metadata-bound
  restores with same-ID/hash/size case removal/change and MIME→JSON, preserving
  selected intent with a valid sibling present. Explicit replacement succeeds.
- Host/navigation encode→decode→restore test proves new semantic metadata survives
  persistence and blocks MIME drift after hydration; original metadata survives
  another save projection. Restored legitimate JSON still opens same-case VCD.
- Palette controls verify four actions for two valid same-case VCDs, and zero
  waveform actions when either captured case membership or observed row is absent.
- Mixed renderer source test includes known scalar/bus lanes before/after an X bus,
  Z scalar and uninitialized bus. It checks exact lane row positions, equal native
  known-lane glyphs,80/120-column geometry, preserved four-state values, recovery
  after the unknown interval, and aggregate budget rejection across marked lanes.
- Existing parser, renderer geometry/cursor, export digest, navigation, Workloads
  correction, endpoint and prompt tests pass.

Final production PTY runs:

```sh
python3 -B terminal/test_waveform_handoff_pty.py --daemon _build_pt8_workbench/default/daemon/main.exe --client _build_pt8_workbench/default/terminal/main.exe
python3 -B terminal/test_waveform_mixed_rows_pty.py --daemon _build_pt8_workbench/default/daemon/main.exe --client _build_pt8_workbench/default/terminal/main.exe --vcd /home/wayne/devel/jane/hardcaml_asic_example/.dev/asic-pt8-workbench/session-waveforms-02/waveform-direct-84166e76c12147508792f756556fea1c/positive-both/artifacts/flops256-waveform.vcd
```

- `/tmp/opencode/pt8-waveform-pty-4vmu99cq/`: **7 passes**, JSON-only/no fetch,
  mixed exact-case VCD, delayed old reply fence, picker exclusion, no JSON requests.
- `/tmp/opencode/pt8-mixed-rows-pty-qm0sd74o/`: **9 passes**, actual retained real
  PT8 bytes copied through a private FS2 fixture/production daemon. Quick and
  dedicated default q labels align with the X marker; known clock rails remain
  visible; exact sixteen-X value retained; defined-response window restores q;
  dedicated view is Ready1ps with correct pin. Original real VCD hash unchanged.
  Raw terminal captures and binary/fixture identities are retained there.

The second PTY run **replays retained actual VCD bytes through artifact transport**;
it does not claim a fresh hardware simulation or a new C producer acceptance run.
Only private test daemons/clients were started/stopped.

## Retained bring-up failures

- Initial compile used boxed tuple syntax for installed Core's unboxed
  `List.split_n`; replaced with `List.take`/`List.drop`.
- The prior X-failure unit expectation was updated to the new explicit lane marker;
  subsequent complete terminal test runs passed.
- Initial mixed PTY evidence `/tmp/opencode/pt8-mixed-rows-pty-ajwniiem/` expected a
  low scalar rail on its label row. The renderer correctly puts that rail on the
  scalar lane's second row. Its capture already shows known controls and the
  aligned q marker. Corrected only the new harness's two-row lane assertion;
  `tjo_ghjc` then passed, followed by final rebuilt-binary `qm0sd74o` above.
- Earlier passing ordinary PTY after the initial guard change: `6tlc9n2m`.

## Final binaries

Paths relative to this Workbench checkout:

| File | SHA256 |
| --- | --- |
| `_build_pt8_workbench/default/terminal/main.exe` | `2c301d20dd744e46942e4a4604a7bde475c67f126a8e86c157c9518fe05da698` |
| `_build_pt8_workbench/default/terminal/waveform_probe.exe` | `390772188022803976fbe31a8b7571dec2007fbd8c03488e5c4df34bff07aa46` |
| `_build_pt8_workbench/default/terminal/workloads_handoff_probe.exe` | `ab51eb97b696d3b6ff3dc59c740deeab0db67ccc828584da8546fac33df458c6` |
| `_build_pt8_workbench/default/daemon/main.exe` | `ec0108fd3ae65ac8bc8113462bfc1eb4dcdcbecf6410c144fbc982113f495a38` |

No backend/example production source, C test, independent original review/evidence,
historical provider/session, root config, or user live process was edited or
restarted. No Git, EDA or new simulator command was run for this correction.
