# PT.8 waveform frontend handoff — initial passing milestone

2026-11-05. Frontend implementation and owner verification against
`pt8_waveform_recovery_plan.md`. This is the initial passing milestone, ready for
independent review and the example owner's real workload VCD acceptance.

## Actual route and correction

There is no `Simulation_view.trace_artifact` helper in this checkout.
`Simulation_view` owns attempt/detail receipt fences; `Testing_workspace` owns
case and general artifact selection. `Workspace_host.simulation_selection_commands`
previously generated embedded and dedicated waveform commands for **every**
artifact, including result-reference JSON. Its `w`/`W` shortcuts used the general
artifact cursor. `Testing_workspace.default_detail` also preferred a VCD from
another case when choosing the initial case/artifact. The dedicated picker was
attempt-scoped but not case-scoped.

Changes:

- `Simulation_export.embedded_vcd`: shared embedded admission requires Available,
  valid bounded size/lowercase SHA256, nonempty bytes declared <=8MiB and an exact
  VCD media type (`text/vcd`, `application/vcd`, `application/x-vcd`). General export
  suffix inference remains separate. No artifact kind restriction: C's `trace` is
  accepted.
- `Testing_workspace.waveform_artifact`: uses only the exact selected attempt and
  case, validated against captured cases and observed case results. Prefer the
  selected artifact only if eligible; otherwise find an eligible VCD **within that
  case**. Saved missing/changed identities remain unavailable, without substitution.
  General artifact selection and JSON workload selection remain separate.
- Default selection establishes the failed/first case before considering artifacts;
  another case's VCD cannot change that case. General artifacts can still be selected
  and exported normally.
- `Workspace_host`: embedded/dedicated commands are emitted only for admitted VCDs
  in the selected attempt/case. `w` and `W` resolve through the waveform selector;
  `e`/external export keep their general artifact cursor. Both waveform shortcuts
  have visible unavailable commands. Detail/Artifacts also show the actionable
  no-VCD explanation.
- `Waveform_view.picker_candidates`: exact pinned attempt **and case**, exact VCD
  media type, bounded 128 rows. Missing observations may retain their identity marker
  for diagnosis; main marks inadmissible picker commands unavailable and refuses
  to pin them. The existing frozen identity and missing-pin rendering remain intact.
- `main`: quick-open and dedicated-pin admission reject unsupported/unavailable
  artifacts before creating a new viewer/pin. Existing page validation, digest
  verification, parser budgets, generation/project/client/daemon/workspace fences
  are preserved.

## Expected frontend actions

1. Testing: reopen the exact attempt; select `flops256` or `exact256` using the
   Cases pane or `Simulation: Select case CASE`.
2. Focus Artifacts. `w` opens the selected case's available supported VCD in quick
   inspection; `W` opens/reuses the Waveforms workspace. These work even when the
   general artifact cursor is on that case's JSON result reference.
3. Equivalent palette actions are `Simulation: Open embedded waveform LABEL` and
   `Simulation: Open Waveforms workspace LABEL`, present only for eligible artifacts
   of that exact selected attempt/case.
4. JSON-only historical attempts: `w`/`W` explain that no available supported VCD
   exists, suggest enabling capture and running again, and direct JSON users to
   `Inspect workload result (selected Testing case)`. No JSON byte fetch or new JSON
   waveform pin occurs. `e` still exports the general selected artifact.
5. Waveforms' VCD picker stays in the pinned case. To investigate another case,
   return to Testing, select that case and explicitly open its waveform.

The example-owner contract is `CASE-waveform`, case attachment, kind `trace`,
media type `text/vcd`, nonempty <=8MiB top-level interface VCD. Actual public IDs
are `ATTEMPT-CASE-waveform`, as produced by FS2 capture. Frontend does not require
a hard-coded waveform declaration ID; transport binds full public identity/digest.

## Verification and retained failures

Every Dune invocation used switch `5.2.0+ox`, explicit `-j2`, shared lock and
`_build_pt8_workbench`.

Final passing production build and terminal tests:

```sh
flock /tmp/opencode/workbench-pt8-build.lock opam exec --switch=5.2.0+ox -- dune build -j2 --build-dir=_build_pt8_workbench terminal/main.exe terminal/waveform_probe.exe daemon/main.exe terminal/workloads_handoff_probe.exe @terminal/runtest
```

- Extended `terminal/workloads_handoff_probe.ml` calls actual
  `Simulation_service.capture_artifact` and `read_artifact`, with case waveform
  declarations alongside JSON references. Both actual attempt-prefixed VCD IDs
  select, read, validate and parse successfully.
- Matrix: JSON-only; mixed JSON/VCD with JSON explicitly selected; reverse artifact
  order; other case; suite-level artifact; wrong attempt; JSON and misleading
  `application/not-vcd-json`; Missing/Changed/Rejected; absent/zero/oversize size;
  missing/uppercase hash; restored digest change; late old-attempt receipt.
- Production host catalog/shortcut checks verify only the selected case VCD gets
  waveform actions, `w` routes to VCD and `e` remains bound to the JSON cursor.
- Existing terminal inline tests cover parser/render limits, byte digest and stale
  export gates, waveform identity/navigation, unavailable pins, endpoint prompts,
  and navigation/preferences restoration. The existing independent frontend
  correction recheck passes 45 checks / zero contract failures.

Production PTY command (uses its own private daemon/project; no simulator):

```sh
python3 -B terminal/test_waveform_handoff_pty.py --daemon _build_pt8_workbench/default/daemon/main.exe --client _build_pt8_workbench/default/terminal/main.exe
```

Final evidence: `/tmp/opencode/pt8-waveform-pty-w9g3qdfe/`. Seven checks passed:
JSON-only `w` produces no artifact byte request; JSON inspection remains available;
mixed `w` fetches only the selected flops VCD; delayed exact-case reply reaches
transport; closing that viewer and opening flops with `W` fences the old reply;
the pinned picker excludes the other case; all production waveform byte requests
target waveform IDs, never result-reference JSON. Retains raw HTTP, terminal
captures, proxy/gate records, binary hashes and check results.

Initial failures retained/documented:

- First compile exposed missing declarations for the new selector in
  `testing_workspace.mli`; added the declarations.
- Initial terminal tests expected cross-case default retargeting, waveform commands
  without size/hash, and the old generic unavailable reason. Updated those tests
  to the new contract; all pass. Large-navigator test now explicitly selects its
  artifact after changing case and accounts for the new availability row.
- First PTY run `/tmp/opencode/pt8-waveform-pty-5mmezlxj/` passed the first four
  checks but expected an unclipped signal name in the compact Signals pane. Its
  captured screen showed the correct ready flops waveform and pin. Corrected the
  assertion to the fully visible pin label/picker exclusion. Subsequent passing
  run: `pt8-waveform-pty-yp7g70x6`; final rebuilt-binary run above also passes.

PTY uses small declared VCD fixture bytes through actual production FS2 capture,
HTTP, digest verification and parser. It does not claim the example owner's real
1307-cycle Flops/Exact simulator acceptance; that is the next integration milestone.

## Built artifacts

Relative to `/home/wayne/devel/jane/silver`:

| Path | SHA256 |
| --- | --- |
| `_build_pt8_workbench/default/terminal/main.exe` | `b9d8957511d66b89be9bd48bad643ac0de73c43efe8896bf0d58c735999b21c2` |
| `_build_pt8_workbench/default/daemon/main.exe` | `ec0108fd3ae65ac8bc8113462bfc1eb4dcdcbecf6410c144fbc982113f495a38` |
| `_build_pt8_workbench/default/terminal/waveform_probe.exe` | `dfa713f252f1dcef460aa69da0a2c22d006494e7fd10d09bb9894c64424d19ea` |
| `_build_pt8_workbench/default/terminal/workloads_handoff_probe.exe` | `dfa36ca0913b34c227e7003ebbda5740b3db9634de35e737ff0c5c0f9ba0d72d` |

Read workspace `../AGENTS.md` and recovery/review context. Changes are confined to
terminal frontend/tests and this review. Backend/example sources, historical pins,
provider/session records and the user's live pair were not edited/restarted.
No Git or EDA commands were run. Existing endpoint/prompt and Workloads correction
tests pass with the frontend changes.
