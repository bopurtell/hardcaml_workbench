# PT.8 waveform frontend — independent example-owner review

2026-11-05. Reviewed A's final seven-PTY milestone without editing A's production
sources or tests. **Two remaining frontend guard concerns**, reproduced by four
negative observations. Ordinary mixed-artifact selection, JSON-only handling,
byte identity/limits, pinned case picker, and late-reply fences pass.

## Findings

### R1 — restored waveform metadata drift can silently substitute a sibling (medium)

Locations: `terminal/testing_workspace.ml:68–74`, `:107–136`, `:234–240`;
`terminal/navigation_preferences.ml:9–19`.

The saved general artifact identity contains only `id`, `sha256`, and `size`.
`artifact` checks those plus availability. It does not validate the artifact's
observed case against the saved selected case, or retain its original media type.
Thus `selection_unavailable` can report no problem even though the saved waveform
is no longer eligible. `waveform_artifact` then falls back to `List.find` and opens
a different waveform generation in that case.

Independent reproduction calls the actual public production functions:

1. Restore attempt `attempt`, selected case `flops256`, selected waveform
   `attempt-flops256-waveform`, hash `aaaa…`, size100.
2. Observe that artifact with unchanged ID/hash/size/Available, but (a) case changed
   to `exact256`, (b) case missing, or (c) MIME changed to `application/json`.
3. Also observe an admitted Flops VCD `later-generation` with a different hash.
4. **Actual:** `T.waveform_artifact` returns `later-generation` in all three cases,
   rather than retaining the restored unavailable intent. No explicit selection
   of the replacement was made.

This is not cross-case byte transport: the replacement itself is a valid Flops
artifact. It is a restore-intent/provenance gap. It requires inconsistent or
changed artifact observation metadata; it was not observed in the immutable real
example capture. Missing saved ID, changed digest, changed size and unavailable
status already block substitution correctly. Dedicated Waveforms pins retain the
full artifact identity; this finding concerns Testing's restored artifact cursor.

Suggested owner correction: bind restored artifact role/case/media sufficiently
to detect semantic metadata drift, preserve unavailable saved intent, and require
explicit user selection before replacing it. Preserve the intentional behavior
where a legitimately selected/restored **JSON** reference opens its same-case VCD
sibling; simply requiring every restored cursor to be a VCD would break that.

### R2 — explicit palette actions omit captured-case membership guard (medium)

Locations: `terminal/workspace_host.ml:4259–4276` versus
`terminal/testing_workspace.ml:120–129`.

Independent reproduction:

1. Selected attempt/case are `attempt` / `flops256`; observed case results contain
   Flops and Exact and an admitted Flops VCD exists.
2. The attempt's captured selection contains **only `exact256`**.
3. **Actual:** the selector correctly returns no waveform, so `w` is unavailable;
   `Workspace_host.simulation_selection_commands` still creates embedded and
   dedicated waveform actions for the Flops VCD.

The explicit actions check current attempt equality, nonempty/equal selected case,
selection availability and embedded admission, but not membership in
`d.captured.selection.cases`. Main's open functions validate media/byte admission;
they do not repair this omitted Testing selection guard.

This is a defensive malformed-observation discrepancy, not a demonstrated normal
FS2 producer path: the real provider's captured cases and results agree. Owner
correction should share the complete eligibility predicate between selector and
explicit action generation. Preserve commands for multiple valid VCDs within the
selected case rather than reducing the palette to only the current cursor.

## Independent execution and preserved evidence

New reviewer-owned path: `review_pt8_waveform_frontend/`.

```bash
python3 -B review_pt8_waveform_frontend/run.py
```

Final receipt:
`review_pt8_waveform_frontend/evidence-a75d051156924cae8213f546f94b111b/`.

- `1.stdout`:72 actual production-library observations,68 pass /4 findings
  (R1's three variants and R2).
- `2.stdout`:4 async production-export observations, all pass. A changed payload
  is rejected despite a correct claimed digest; a held byte response released
  after owner invalidation cannot publish; the next owner loads independently.
- `receipt.json`: production/tests unchanged; exact binary hashes; EDA0.
- `source-before.json`, `source-after.json`: equal SHA256 inventories of81
  terminal source/interface/build/test files, including A's original PTY script.
- Per-command argv/stdout/stderr receipts. Build only reviewer executables under
  `flock /tmp/opencode/workbench-pt8-build.lock`, switch `5.2.0+ox`, explicit
  `dune build -j2 --build-dir _build_pt8_workbench`. No production/test edits.

Earlier reviewer evidence remains:
`evidence-fddf1a776dd04093a66c64ad2a06087d` (initial52 probes),
`evidence-46d9617c1aff467eb30a81ffc5db8f51` (review harness compile failed: installed
Async requires `Ivar.fill_exn` and monadic shutdown), and
`evidence-2f37fd7a296b4385967c3a657c7c948a` (corrected async checks). Only reviewer
files were corrected. Probes deliberately report `FINDING` observations separately
from compiler/process success; an exit0 is not a clean independent-review verdict.

## Confirmed behavior and limit semantics

- A JSON general cursor with a same-case VCD sibling leaves the cursor/JSON
  Workloads artifact unchanged, while both `w` and waveform actions target the VCD.
  `e` remains bound to JSON. JSON-only has the actionable no-VCD reason, with no
  JSON viewer creation or byte request in the original native evidence.
- Wrong attempt, wrong case and missing case metadata are rejected, even with the
  **same artifact ID**, in both selector and host action probes. Switching case
  explicitly resolves the new case's eligible VCD.
- Admission requires Available, declared nonzero size **<=8MiB inclusive**, and
  exactly64 lowercase hexadecimal SHA256 characters. Missing/negative/zero/oversize
  sizes, absent/short/uppercase/nonhex digests, Missing/Changed states and FST reject.
- Supported MIME values are case-insensitive exact `text/vcd`, `application/vcd`,
  `application/x-vcd`. MIME parameters, trailing whitespace and
  `application/vnd.gtkwave.vcd` are deliberately unsupported. A filename/ID ending
  `.vcd` cannot admit JSON. The general exporter still infers suffix from a MIME
  substring; this is separate from embedded admission and does not bypass it.
- Declared8MiB admission is only the first gate. Transport validates attempt,
  artifact ID, hash, size, offset and EOF; complete bytes are SHA256-verified before
  parsing. Viewer parsing independently bounds4096 declarations,4096-bit width,
  500,000 changes and64MiB value storage. No test equates admitted metadata with a
  successfully parsed trace.
- Picker candidates match the **pinned attempt and pinned optional case**, exact
  supported MIME, first128 rows. Candidate filtering intentionally includes
  unavailable/oversize observations for diagnosis; main marks them unavailable
  and refuses opening. Changed digest or changed case does not mark the old pin.
  A missing old pin stays missing; opening another candidate is an explicit action.
- Testing late old-attempt observations are ignored. Main's quick viewer uses
  generation/visibility/client/daemon/project fences; workspace reads additionally
  bind runtime epoch, token, complete pin and project key. Async export checks
  ownership before/after fetch and before publish. Independent delayed-export
  checks and A's actual PTY replacement scenario both pass.

## Case switch, screenshot and pinned logs

Reviewed A's retained `/tmp/opencode/pt8-waveform-pty-w9g3qdfe/`:
`checks.json` has seven passes; `delayed-byte-proxy.json`, `raw-http.jsonl`,
`late-exact-fenced.txt` and raw ANSI retain the real transport/terminal evidence.
The screenshot pins **Flops**, excludes Exact from the picker, and labels Logs
**“Pinned attempt output”**. It does not claim case-only logs.

`main.ml:5156–5199` captures the job from the exact observed artifact's attempt;
`:2604–2646` fetches that pinned job. `workspaces/waveforms.ml:58–63` binds job to
daemon instance and refuses restart substitution. The same attempt can execute
Flops and Exact sequentially, so Exact text in a Flops-pinned log pane is correct
when it belongs to that same attempt/job. Explicit case switching and repinning
within one attempt appropriately keeps the same attempt-wide log source. No log
retarget bug found. A missing/expired job becomes unavailable, never the current job.

## Binary/source identity and real example acceptance scope

Current reviewed binaries match A's seven-PTY receipt exactly:

| File | SHA256 |
| --- | --- |
| `terminal/main.exe` | `b9d8957511d66b89be9bd48bad643ac0de73c43efe8896bf0d58c735999b21c2` |
| `daemon/main.exe` | `ec0108fd3ae65ac8bc8113462bfc1eb4dcdcbecf6410c144fbc982113f495a38` |

Both live under `_build_pt8_workbench/default/`. Key reviewed source hashes:

| Source | SHA256 |
| --- | --- |
| `terminal/testing_workspace.ml` | `fceb15f45ac351a778eec192c3a274ef67c4cf01271d3468259326d52ee11e6c` |
| `terminal/workspace_host.ml` | `0eaa40361b07a11ce0f97cd44da4d1d72f74d630a08ab5e62db715de99f2dea6` |
| `terminal/simulation_export.ml` | `dc697cfc613bd57c5aee2b0045a760f6c81e111853bad4ddc9af6ad7f7ed0bca` |
| `terminal/waveform_view.ml` | `5df194f6e09b0a19f2008e52bafd3a1ca21557471042fb63b2eb1402409fbc9f` |
| `terminal/main.ml` | `653542d627d110fe8dca6766fc43c4f83c3dd489794b959711b8e35f8c0fb96f` |
| `terminal/test_waveform_handoff_pty.py` | `4972bc5b28de09d371600ff6f890d1660594d1664168897679e1533cad649f5e` |

The prior real example native receipt remains valid evidence at
`hardcaml_asic_example/.dev/asic-pt8-workbench/session-waveforms-02/waveform-native-16c4bda78c4042ab95e82c12879da2b3/`.
It shows actual fresh Testing Exact launch, real64078-byte VCD, six parsed signals,
cursor0→2595000→2595001, defined read response rendering and dedicated workspace.
Its receipt records terminal binary
`01c30d2433da606961d47f3c981da51705937a43af5139fd766f264410ab1877`, **not** A's
later final `b9d895…` build. The daemon hash agrees. This review does not relabel
the earlier real-provider native execution as a run of the later binary. Current
seven-PTY evidence uses fixtures; the main/coordinator owns final same-execution
ledger acceptance. No additional real simulator/EDA/live-session work was run here.

## Verdict

Happy-path recovery and native late-reply/case pinning are substantiated. R1 and
R2 remain concrete bounded guard concerns for A to address or explicitly disposition.
No claim of a clean all-negative-metadata acceptance until those are resolved.
Existing root changes, user sessions, provider captures, immutable attempts and
original tests were preserved.
