# Standard Plan frontend recovery gate

2026-11-05 — **PASS**, production terminal + native HTTP, real private recovery
project, fresh daemon state and client preferences. Physical launches and EDA
allocation: **0**. No launch command was submitted.

## Use the corrected session

The original `session-final-review-01` is preserved and was not restarted. When
ready, exit its client and stop its foreground server with Ctrl-C. Start the new
source-complete session with the rebuilt client:

```bash
# Terminal 1
cd /home/wayne/devel/jane/hardcaml_asic_example
opam exec --switch=5.2.0+ox -- python3 -B scripts/pt8_workbench_launch.py daemon \
  --session .dev/asic-pt8-workbench/session-standard-recovery-02
```

```bash
# Terminal 2
cd /home/wayne/devel/jane/hardcaml_asic_example
opam exec --switch=5.2.0+ox -- python3 -B scripts/pt8_workbench_launch.py client \
  --session .dev/asic-pt8-workbench/session-standard-recovery-02
```

Choose **Plan ASIC standard / balanced**. Its endpoint input should contain
`synthesis`; Enter should stage the intent, and **Launch and view planned run in
captured context — synthesis** should be available. No physical launch was made
by these recovery checks; pressing that launch command is the user's own run.
The new session has independent state/history, so an empty Runs view is expected
until a run is launched. PT.8 Testing remains available independently of ASIC Runs.

Coordinator read the corrected setup/launcher/shim and private-source evidence.
The source root is a copied, hash-inventoried build closure, not the owner's
writable checkout; source-build activation uses the exact reused immutable provider
and writes only to the new session's build/preparation/results directories. A real
private Exact FS2 replay also passes after the source-root change; its retained
result survives transport-directory relocation and public reinspection.
Evidence: `session-standard-recovery-02/exact-fs2-verification-71641bf9eb1545e2b3c662519f26999f/assertions.json`.
The original source-only failure reproduction and early failed recovery attempts
remain recorded in the example's `docs/pt8_standard_plan_recovery.md`.

## Correction and source recovery review

The frontend endpoint regression was independent of the example's incomplete
source root:

- Plan and Preparation forms previously read only a matching remembered selection,
  leaving a new client's endpoint blank despite discovered fresh-prefix endpoints.
- Both forms now share `Launch_preferences.endpoint_query`, also sharing the
  preparation view's existing initial-choice policy. Prefer `synthesis` only when
  advertised; otherwise use the first advertised endpoint, or blank when none is
  advertised. A matching remembered endpoint and assignments remain exact.
- The compact planned-run view retains the model's failure diagnostic.
- The catalog declares the default flow/profile pair, not a default endpoint.

Read-only inspection covered the example's `docs/pt8_standard_plan_recovery.md`
and `scripts/pt8_workbench_setup.py`, `pt8_workbench_launch.py`,
`pt8_workbench_dune.py`, `pt8_standard_recovery.py`, and
`pt8_standard_acceptance.py`. The new setup copies a source closure into a private
project, inventories it, builds with explicit `--root`, captures independent
programs/configs, and activates the exact reused ASIC generation for nested
processes. The source recovery's retained receipt reports 14 public Plans and
successful source-only build/emission. This frontend gate independently exercises
the recovered project through the actual terminal; it does not repeat emission.

Real project:

```text
/home/wayne/devel/jane/hardcaml_asic_example/.dev/asic-pt8-workbench/session-standard-recovery-02/project
```

The main investigation owns the broader source-snapshot isolation review. No
example script defect blocked this bounded frontend gate, and none was edited.

## Reproduction and evidence

From the Workbench root:

```sh
python3 -B terminal/test_standard_plan_recovery.py \
  --real-session /home/wayne/devel/jane/hardcaml_asic_example/.dev/asic-pt8-workbench/session-standard-recovery-02
```

Passing evidence root:
`/tmp/opencode/standard-plan-recovery-pty-zzx8sguy/`.
`result.json` records 20 passing assertions, binary hashes, plan identities,
preservation checks, and zero allocation. The script reuses the native HTTP/PTY
helpers, starts its own traced daemon on an ephemeral port, uses independent
`/tmp/opencode` state/preferences, and reproduces the launcher's generation/shim
environment. It connects to the actual recovery project's configs and driver.

| Gate | Actual evidence |
| --- | --- |
| Client starts without launch preferences; real catalog default is standard/balanced | `result.json`, `discovery.json` |
| Open command palette → Plan ASIC standard / balanced → endpoint form visibly contains `> synthesis` | `02-balanced-form.txt` and `.ansi` |
| Press Enter without editing; exact standard/balanced/synthesis intent is staged | `fresh-balanced.json`, `03-balanced-ready.txt` |
| Preparation capability reports `Available` | `preparation.json` |
| Search Launch and view; actual selected command is `Launch and view planned run in captured context — synthesis`, with no disabled-reason suffix | `04-balanced-launch-enabled.txt` and `.ansi` |
| Real public Plan succeeds against the private source root | `public-plan-balanced.json`, `native-http.jsonl`, `process.strace` |
| Preparation inputs: standard / synth_delay defaults to synthesis; append valid `SYNTH_ABC_BUFFERING=true`; accept; reopen Plan for that profile | `05-delay-preparation-default.txt`, `06-delay-preparation-edit.txt`, `07-delay-plan-retained.txt` |
| Enter stages the exact profile/override; Launch and view is enabled again | `fresh-synth_delay.json`, `08-delay-ready.txt`, `09-delay-launch-enabled.txt` |
| Actual public Plan accepts synth_delay plus the override | `public-plan-synth_delay-override.json` |
| No workflow, launch submission, or run allocation | `final-asic.json` |
| Source/config/captured-program/manifest/generation-receipt hashes unchanged | `preservation-before.json`, `preservation-after.json` |
| No physical provider admission or EDA process | `process.strace`, `result.json` |

Availability is checked from the rendered **command result row**, distinct from
the similarly worded query row. The production palette renderer adds a bracketed
reason for unavailable commands. The complete selected title fits in the palette
and has no such suffix. The gate then presses **Escape**, never Enter on launch.

### Fresh intent and plan identity semantics

Both actual fresh intents have `elaboration_only=false` and
`expected_plan_identity=None`. This is the terminal's intended current-source
contract: Plan stages inputs for a later source build/emission, rather than
pinning an earlier configured-executable preview. The parsed intent scope contains
the exact recovery project root, `bin/project.exe` preparation target, private
preparation results directory, ASIC config, and provider stamp. The public Plan
responses independently establish the real methodology identities:

- balanced/synthesis:
  `744f43a3ffe46550b97b84055079e46446c0e588cf564b07a35322eb8cd3c87f`
- synth_delay/synthesis with `SYNTH_ABC_BUFFERING=true`:
  `50b02ca638bec4daf8e754dad4fd3debce9ce7813baecff312d0da0d5a2c398c`

The staged intent does not claim either identity as an expected-plan fence.

## Preservation and retained harness failure

The test stopped/reaped only its own process group. Read-only `ps` afterwards
confirmed the user's original daemon **345934** and client **345968** still run
against `session-final-review-01`. No request was sent to that pair. Acceptance
state and screenshots are under the evidence root; example source/config/provider
files were read-only inputs. Startup's Dune workspace probe uses the captured
two-job shim and private project build directory. No Workbench build was needed
for this additional gate.

The first attempt is retained at
`/tmp/opencode/standard-plan-recovery-pty-kop_q6e6/`: source staging and availability
were correct, but the assertion counted both the palette query and result row.
Its screenshot already shows the enabled command. The matcher was corrected to
require the result's endpoint suffix; the passing run above uses a new daemon and
new preferences. Both attempts preserve watched inputs and have no EDA process.

The earlier frontend tests also passed: `endpoint_prompt_test`, terminal
`dune runtest`, and the isolated real-catalog fixture PTY regression. All earlier
Workbench Dune invocations used switch `5.2.0+ox`, `-j2`,
`_build_pt8_workbench`, and `/tmp/opencode/workbench-pt8-build.lock`.

**Blockers for this frontend staging/availability gate: none.** Actual physical
launch execution has not been reviewed by this gate.

## Supplemental P2 correction: exact multiword prompt tokens

2026-11-05. C's original review and repro in
`docs/pt8_endpoint_independent_review.md` and `review_pt8_endpoint_defaults/`
remain unchanged. The pre-existing space-split bug is now corrected in the shared
`Launch_preferences.Prompt` encoder/parser and the Plan/Preparation Enter handler.
For example, remembered inputs are rendered as:

```text
synthesis "SYNTH_STRATEGY=DELAY 1" SYNTH_ABC_BUFFERING=false
```

The parser is a data-only quoted-token grammar, never a shell:

- Spaces separate tokens; repeated spaces are ignored between tokens.
- Single- and double-quoted spans can join bare spans within a token.
- Inside double quotes, only double quote and backslash may be backslash-escaped.
  In bare or single-quoted spans, backslashes remain literal.
- `$`, command-like text, semicolons, and other punctuation remain data. There is
  no variable expansion, command substitution, shell execution, or shell escape
  interpretation. For example, a backslash followed by `n` does not become a newline.
- Actual control characters (including newline, CR, tab, NUL, DEL) are rejected.
  Unclosed quotes, unsupported quoted escapes, and an empty endpoint produce an
  actionable notice and keep the form/query open without dispatching.
- Encoding quotes tokens containing spaces, quotes, or backslashes. Token order,
  duplicate assignments, literal quotes/backslashes, and empty assignment tokens
  survive the round trip. Ordinary simple-token input is unchanged.

The supplemental regression extends `terminal/endpoint_prompt_test.ml` with an
8×8 token-pair corpus, both real Enter action variants, hand-written single/double
quoted forms, literal command-like text, and rejected-input/no-dispatch checks.
The unchanged C executable now passes its original multiword assertions using the
encoded prompt from the production helper:

```sh
_build_pt8_workbench/default/review_pt8_endpoint_defaults/review.exe --spaced-assignment
```

Observed: **2841 checks pass**, and expected/captured selections both contain
`("SYNTH_STRATEGY=DELAY 1" SYNTH_ABC_BUFFERING=false)`; exit 0. This is supplemental
verification by the correction owner, ready for C's independent recheck.

The updated real-project PTY regression additionally enters:

```text
synthesis SYNTH_ABC_BUFFERING=true "SYNTH_STRATEGY=DELAY 1"
```

It accepts Preparation for `synth_delay`, reopens Plan with the exact encoded
prompt, accepts Enter, and verifies the actual fresh intent has exactly two
assignments. Real public Plan and enabled Launch and view checks pass again.

New passing receipt: `/tmp/opencode/standard-plan-recovery-pty-l7fvmysq/result.json`.
Its screenshots, fresh intent, public Plan, final zero-allocation snapshot,
preservation inventories, and process trace are adjacent. The override Plan
identity is `b6d2baa772ee170a120f7cdf2c9be4e1cb67e78d8b595d43dc8ded1b5680dd97`.
This receipt supplements the earlier single-override gate; both remain retained.

Focused executable, terminal `dune runtest`, production terminal build, and
`git diff --check` pass. Dune used switch `5.2.0+ox`, `-j2`, shared WB lock, and
`_build_pt8_workbench`. No example config/script, backend, or live pair was changed;
no launch was submitted and EDA allocation remains zero.
