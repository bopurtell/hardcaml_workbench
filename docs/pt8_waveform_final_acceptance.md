# PT.8 final waveform acceptance

2026-11-05. **Final corrected producer + final frontend accepted; no remaining
contract blocker.** New immutable source-complete example session:
`.dev/asic-pt8-workbench/session-waveforms-final-01`.

## Independent frontend disposition

Original reviewer probe sources were rerun unchanged against final sources:
**76 passes / zero findings**. Metadata-drift restore no longer substitutes a
sibling; explicit palette actions reject uncaptured cases. See
[independent disposition](pt8_waveform_frontend_review_disposition.md) and
`review_pt8_waveform_frontend/evidence-237cbf389c6e45b48ae4e99ed51503b5/` for
commands, full source inventories and receipts. Prior findings/probes remain intact.

Verified final client SHA256:
`2c301d20dd744e46942e4a4604a7bde475c67f126a8e86c157c9518fe05da698`.
Daemon SHA256:
`ec0108fd3ae65ac8bc8113462bfc1eb4dcdcbecf6410c144fbc982113f495a38`.

## Actual fresh direct Flops + Exact

Session-relative receipt:
`final-direct-89494cd497184b6c80686d771a1f6569/assertions.json`.

Actual direct request ID: `final-direct-32cfc976084c43169f7e3e735bec8cb2`.
The immutable corrected provider ran both cases sequentially once. Both pass
public functional inspection and have unchanged counters:1307 cycles,525 reads,
262 writes,787 operations,2083 defined observations, latency1.

- Actual VCDs:64,078 bytes each, six declarations,6028 changes, scale1ps,
  final time13,070,000ps. Descriptor and published copy bytes agree.
- Production parser sampled every signal at `cycle*10000+4000` and `+9000` ps:
  **15,684 signal samples per case,31,368 total**, all equal to that execution's
  raw `vvp` stdout and declared stimulus. Each case retains519 unknown-q samples.
- Parsed raw trace agrees with each retained `trace.json` and historical
  `simulation-04` outputs. No memory initialization or sanitization.
- Distinct result/source identities and private simulator commands retained.
  Both direct VCD byte hashes happen to match because the identical logical
  interface traces were executed within the same Icarus metadata timestamp:
  `7a43b9da01c6769f205c7756df3bfb99418dbbf8dd4c9ae961e7ef6b7ac80317`.
  Equal waveform bytes do not equate the two simulation/bundle identities.
- Exact stock models remain hash-identical. vvp cwd and compiled simulator both
  belong to the case's private directory.

### Standard Plan / source closure

The public captured `project.exe flow plan --flow standard --profile balanced
--endpoint synthesis --source-root PRIVATE_PROJECT --json` passes source-only.
Plan identity:
`744f43a3ffe46550b97b84055079e46446c0e588cf564b07a35322eb8cd3c87f`.

`standard-source-only-plan/command.json`, stdout/stderr, `standard-plan.json` and
`plan.process.strace` retain the exact command/result. Every source-snapshot file
hash remains unchanged before/after. No source build, emit, synthesis or physical
stage was needed for this Plan check. This confirms the final private source
closure retains the recovery session's normal public Plan capability.

## Actual production Testing → JSON cursor → waveform

Actual UI evidence:
`final-native-4534033748874e5aa7fd66f5f3ee29a3/`.

Final audited receipt:
`final-audit-native-85f4860aa6f5477b85ce76ba7b91c96f/assertions.json`.

Fresh production Testing cases→seed→confirmation form submitted Exact:
`sim-c24b8e60485c687ee0827b3410cb493b83fbe17fe4be4b8b534c0e2a75fd6e1e`.
This additional actual Exact execution is specifically the final UI integration
acceptance, following the single direct pair. **Three real case executions total;
audits replay no simulator.**

- `json-cursor.txt`: Artifacts cursor visibly selects the result reference; Detail
  shows `Kind: json; media type: application/json`, correct attempt/case and digest.
  Pressing production `w` opens its Exact VCD sibling.
- `delayed-byte-proxy.json`: actual client waveform-byte requests target only
  `ATTEMPT-exact256-waveform`, never JSON; correct attempt and digest on both quick
  and dedicated loads. This is recorded production HTTP, not a renderer mock.
- `mixed-X-ready-at-zero.txt`: six matching/enabled signals, known control graphs
  rendered, `q` shows X in signal values and **“X/Z in window; no graph”** only in
  its own lane. No whole-view `Graph unavailable` failure; no fabricated values.
- `read-response-2595000.txt`: actual time cursor2595000ps, response **13C6**.
  `cursor-2595001.txt`: `l` advances to2595001ps.
- `dedicated-ready.txt`: dedicated Waveforms Ready at0, six signals, correct
  waveform pin/picker, known graphs and honest X lane. No JSON pin.
- Saved `waveforms-*.sexp` parsed structurally: full artifact equals the fresh
  observed VCD, and the pinned log job equals the same attempt's job, bound to
  its daemon instance. Logs correctly say **“Pinned attempt output”**, not case-only.
- Transport64,078 bytes; SHA256
  `9658925f6e687cafe1d39eae9f651ab02b259228d73db92dffff7847b44f24d9`.
  Actual byte transport matches the retained execution VCD. The independently
  HTTP-fetched JSON reference agrees with the authoritative retained reference.
- This UI Exact run also passes all15,684 same-execution signal samples,519
  unknown response samples, unchanged counters and historical trace equality.

### Harness bring-up receipts preserved

The native run completed the requested UI/transport/sample checks but its last
receipt assertion used `waveform-*.sexp`; the real sidecar is `waveforms-*.sexp`.
That original `pass:false` receipt remains unchanged. Corrected only the new
acceptance harness and audited the retained actual execution/screens/transport/
sidecar into a **new** passing receipt, without another simulation or relabelling
the failed receipt.

The first audit, `final-audit-native-eec72eb4406748d0bfb843d9eb071cc7`, also remains:
its overly broad no-Dune assertion encountered normal automatic `--version` and
`describe workspace` metadata discovery. Corrected the harness to distinguish
metadata from build/EDA. Process trace shows the real describe call uses switch
5.2.0+ox, `-j2`, private build-root arguments and the existing example-lock shim.
The unchanged captured shim uses private `_build` for metadata probes; no Dune
build occurred in the actual acceptance. Reviewer build commands used the shared
Workbench lock, explicit `-j2` and `_build_pt8_workbench`.

The final audit validates actual retained evidence rather than merely trusting
the failed harness's earlier assertions, and inventories its file hashes in
`retained-ui-evidence-hashes.json`.

## Exact final commands

Workbench cwd:

```bash
python3 -B review_pt8_waveform_frontend/run.py
```

Example cwd:

```bash
opam exec --switch=5.2.0+ox -- python3 -B scripts/pt8_waveform_final_acceptance.py direct --session .dev/asic-pt8-workbench/session-waveforms-final-01
opam exec --switch=5.2.0+ox -- python3 -B scripts/pt8_waveform_final_acceptance.py native --session .dev/asic-pt8-workbench/session-waveforms-final-01 --direct-receipt .dev/asic-pt8-workbench/session-waveforms-final-01/final-direct-89494cd497184b6c80686d771a1f6569
opam exec --switch=5.2.0+ox -- python3 -B scripts/pt8_waveform_final_acceptance.py audit-native --session .dev/asic-pt8-workbench/session-waveforms-final-01 --direct-receipt .dev/asic-pt8-workbench/session-waveforms-final-01/final-direct-89494cd497184b6c80686d771a1f6569 --native-evidence .dev/asic-pt8-workbench/session-waveforms-final-01/final-native-4534033748874e5aa7fd66f5f3ee29a3
```

Each invocation allocates a fresh receipt directory. Native creates/stops only its
own private daemon/client runtime. Do not rerun these to inspect the evidence;
read the retained receipts/screens instead.

## Identity and preservation

Corrected immutable producer hashes remain:

| Source | SHA256 |
| --- | --- |
| `scripts/pt8_workloads.py` | `329c1ff215ad2001f52e5d1a751838292b249308de7ecc96c0f1cf44bab3b811` |
| `scripts/pt8_workbench_provider.py` | `e70ab0990df43419993906c7c67506455651ea83157bbb8d232a1192c21259a4` |
| `scripts/pt8_workbench_runner.py` | `01e19a51ab7559af449eed1d28bec231e53c20ecd09ec905e4aaa86940eb1292` |

Full producer/provider/test/acceptance/binary hashes are in each invocation receipt;
the final source snapshot/provider manifest is unchanged. The new acceptance
harness lives in the example checkout and was not retroactively inserted into
the immutable capture. ASIC generation remains
`ee3af8de9f83418b9afed9c67e473e3c`.

All preserved root/provider/session02/original review evidence and private source
hash checks pass after direct, native and audit phases. Root configs, user pair,
old sessions and provider captures were not changed/restarted. All writes and
runtime state are private. No EDA was launched; traces retain the exact child
process record. Both independent frontend findings and both producer blockers
are resolved, with final actual integration evidence above.
