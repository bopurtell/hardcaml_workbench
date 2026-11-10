# Independent endpoint/default/diagnostic review (C)

2026-11-05. Review only: no frontend production edits. Main reviews setup separately.

## Finding: remembered multiword assignments do not round-trip (P2)

`terminal/launch_preferences.ml:41–51` preserves a same-flow/profile remembered
selection as prompt text, including its assignments. `terminal/workspace_host.ml:4931–4936`
then splits that text on every space when accepting either Plan or Preparation.
For the actual standard-flow enum assignment `SYNTH_STRATEGY=DELAY 1`, Enter changes
the single assignment into `SYNTH_STRATEGY=DELAY` and bare `1`. This changes exact
remembered inputs and yields an invalid provider override rather than retaining
the user's selection.

Reproducer uses the actual helper and `Workspace_host.input Enter`:

```text
remembered assignments: ["SYNTH_STRATEGY=DELAY 1"; "SYNTH_ABC_BUFFERING=false"]
captured assignments:  ["SYNTH_STRATEGY=DELAY"; "1"; "SYNTH_ABC_BUFFERING=false"]
```

This serialization/parser weakness **predates A's change**; it is not a new
default-helper regression. It remains relevant to the requested remembered exact
assignment-capture behavior. No production fix is made in this review slice.
The separate `--spaced-assignment` adversarial executable deliberately exits2 on
this semantic mismatch; its failure is retained, not counted as a passing check.

## Passing scope

`review_pt8_endpoint_defaults/review.ml` runs **2841** independent checks against
the real production helper, preparation selection, palette Enter handler and
diagnostic-row producers:

- All128 subsets of seven advertised endpoints, in forward and reverse order,
  with another flow advertising synthesis as a decoy. Defaults must belong to the
  chosen flow; synthesis is preferred only when advertised; otherwise provider
  list order is preserved; an empty endpoint list yields no implicit endpoint.
  The literal synthesis preference is a UI initial-choice policy, not an asserted
  provider-declared default or an unconditional synthesis fallback.
- Known/unknown flow and profile, changed catalogs, empty/absent catalogs and
  missing catalog defaults. No implicit flow/profile/default endpoint is invented.
- Same-flow/profile remembered selections retain endpoint, override order and
  duplicate tokens, even if no catalog is available or that endpoint disappeared.
  This is explicit-input preservation; authoritative source/provider validation
  still happens downstream. Other flows/profiles do not inherit those overrides;
  they get their own advertised initial choice or an empty prompt.
- Actual Enter dispatch for Plan and Preparation captures exact simple-token
  selections; an empty missing-catalog prompt does not dispatch.
- Fresh-stage and provider-Plan failure diagnostics retain their exact source
  diagnostic with Error role in both compact and detail row projections. The
  additional compact error row also explains the changed launch-indicator row
  index in `host_view.ml`.

Review of the call sites confirms both `Edit_plan` and `Edit_preparation` capture
their requested flow/profile in the prompt argument and use this same helper.

## Exact commands/evidence

From the Workbench checkout:

```sh
python3 -B review_pt8_endpoint_defaults/run.py
```

The runner retains commands/stdout/stderr and before/after production source hashes
at **`/tmp/opencode/pt8-endpoint-independent-_8_cuy35/receipt.json`**:

1. `opam exec --switch=5.2.0+ox -- flock /tmp/opencode/workbench-pt8-build.lock dune build -j2 --root /home/wayne/devel/jane/hardcaml_workbench --build-dir _build_pt8_workbench review_pt8_endpoint_defaults/review.exe` — exit0.
2. `_build_pt8_workbench/default/review_pt8_endpoint_defaults/review.exe` — exit0,
   2841 checks.
3. Same executable with `--spaced-assignment` — exit2, retained finding above.

Initial2072-check run is also retained in
`/tmp/opencode/pt8-endpoint-independent-axai83ug/`; the final matrix adds explicit
remembered-input tests against different valid advertised flows/profiles.
Production source hashes match before/after both runs. Final `git diff --check`
passes. Builds were sequential, explicit two jobs under the shared WB lock; the
later direct-FS2 simulation was sequential and did not overlap this review build.

## Review limits / unchanged known state

This is an independent helper/palette/model-row test, not a second native PTY
review. It does not claim live terminal layout, keyboard-to-RPC dispatch, long-line
clipping or full Fresh/physical execution acceptance. A's own native test is
inspected but not rerun here. No daemon was started/stopped by these helper tests.
Frontend production files, root configs, providers and old sessions were not edited.
Only the new review test directory and this review document were added in WB.

The separate C direct-FS2 follow-up passed one real Exact implementation simulation
from `session-standard-recovery-02`'s private source root, with unchanged known-state
inventories and persistent reference closure. Its command/identities are recorded
in the example's `docs/pt8_standard_plan_recovery.md`.

## Final disposition after A's P2 correction

**P2 CLOSED in the independently tested scope**, 2026-11-05. The historical finding
and its failed receipt above remain unchanged. A introduced the shared data-only
`Launch_preferences.Prompt` encoder/decoder and switched the actual palette Enter
handler to `Prompt.selection`. This reviewer made no production edits.

Corrected final receipt:
**`/tmp/opencode/pt8-endpoint-independent-jfv4b78v/receipt.json`**.
Run from Workbench with `python3 -B review_pt8_endpoint_defaults/run.py`:

| Retained command | Status |
| --- | --- |
| Explicit switch5.2.0+ox, shared WB lock, Dune build `-j2` for both review executables | exit0 |
| Original, unchanged `review.exe` catalog/remembered/error matrix | exit0;2841 checks |
| Original, unchanged `review.exe --spaced-assignment` reproducer | **exit0**, exact multiword assignment preserved |
| New independent `grammar.exe` | exit0;1018 literal/grammar/rejection/render checks |

The original spaced-assignment probe now prints identical expected and captured
selections, including the single string `SYNTH_STRATEGY=DELAY 1`. The runner was
updated to require success for this corrected disposition; the old failing stdout,
stderr and receipts at `_8_cuy35` and `axai83ug` were not rewritten.

### Quoting grammar inspection and adversarial verification

The implementation is a Buffer-based tokenizer/serializer, not a shell parser or
process launcher. Its grammar is intentionally bounded:

- ASCII spaces separate tokens. Single-/double-quoted spans concatenate with bare
  spans. Empty quoted tokens survive; a missing or empty endpoint rejects.
- Single quotes contain literal backslashes. Bare backslashes are also literal;
  they do not escape the next space. Double quotes support only escaped quote and
  escaped backslash; unsupported escapes reject with guidance rather than silently
  changing data. Trailing/unclosed quotes reject.
- Control characters0..31 and DEL reject as non-single-line input. UTF-8 examples
  round-trip unchanged.
- Dollar-variable syntax, `${...}`, `$()`, backticks, globs, redirection/pipeline
  characters and semicolons remain literal token data. There is no environment
  interpolation, expansion, substitution or command execution in this codec.

The1018 checks independently cover all95 printable ASCII characters plus mixed
quotes, trailing/doubled backslashes, empty tokens, whitespace, UTF-8, and shell-like
strings. Encoded token lists round-trip exactly. Actual Enter through **both** Plan
and Preparation captures exact assignment boundaries, including multiword values
and literal quoted/backslash content. Mixed quoted/bare spans and the documented
backslash distinctions have explicit expected-token tests, not only inverse tests.

Malformed single/double quotes, incomplete/unsupported double-quote escapes, every
forbidden control character, and empty endpoints all produce **No_effect**, retain
the editable prompt with exact input, and publish an error notice. The independent
test renders the actual palette at200×60 and verifies its rejection notice is
present in rendered text. Thus rejection is visible at the production view-model/
renderer level, rather than inferred only from an error-return helper.

### Retained follow-up harness failures and limits

`q7_4hdsy` and `zs93j8ur` retain two failed new grammar-harness attempts. In both,
the original matrix and original spaced-assignment probe already pass. The new
harness incorrectly required the generic `Invalid typed input:` prefix for blank
input; production already displayed the more specific `An explicit endpoint or
exact finalization attempt is required`. The test was corrected to accept that
specific visible blank-input rejection, while still requiring the generic prefix
for malformed quotes/escapes/controls. No production change was needed.
`hmdmqimt` retains the passing932-check grammar run before adding actual rendered
palette-notice assertions; the final1018-check receipt above supersedes only that
test coverage claim.

Tested helper SHA256:
`f4682366f71a236d23bf126687159b6621fbba069e3ecfa362a0fe3ab75826d7`.
Tested palette host SHA256:
`0027922b997078f87d7dbe541d2953f824765104ebb42896bcc85dbaab03d0cf`.
All recorded production hashes match before/after the final run. Final
`git diff --check` passes. Only review tests/runner and this appended disposition
were changed by this follow-up; no daemon, user pair, old session, provider,
configuration, example output or guide was touched.

This closes the identified prompt round-trip finding. It remains a helper plus
actual input-handler/rendered-palette review, not a native PTY/HTTP integration
rerun or an exhaustive arbitrary-byte grammar proof. Main owns guide/session
handoff and integrated user-pair review.
