# PT.8 Workloads frontend — implementation and controls

2026-11-05. Frontend slice A, ready for independent integration review. The
[integration plan](pt8_workloads_plan.md) owns scope and the
[B handoff](pt8_workloads_handoff.md) owns protocol. This guide does not change
the construction queue or configure/start the user's application.

Final integration accepted after independent corrections and real UI execution;
see [session launch and closeout](pt8_workloads.md). Initial receipts below remain
historical and are not reattributed to corrected binaries.

## Open and inspect

Use `Space c c` to open the command palette:

1. **Open Workloads workspace** creates the shipped Workloads workspace only when
   needed, or navigates to the existing workspace. Existing layouts, hidden/zoomed
   tiles, pins and custom definitions named `workloads` are preserved. A hidden
   Workloads tile needs explicit restoration through the normal tile commands.
2. **Workloads: Import exact retained result.json** prompts for an absolute file
   path. This is a retained read, not a run allocation. The daemon resolves paths;
   the terminal does not read arbitrary evidence files locally.
3. The result detail shows concise recorded execution status, functional outcome
   and performance availability, followed immediately by provider metrics. Full
   bundle/hardware/workload/simulation identities, metric definitions/scope and
   retained outcome details are available with `d` (provenance).
   Undefined/unavailable values remain unavailable.
4. `Esc` returns to the retained results list; `j/k` selects rows, `Enter` opens a
   result, `/` filters and `Ctrl-U` clears the filter. The selected identity does not
   follow Main's physical run selection.
5. `d` opens controls, bindings, provenance/source references and full diagnostics;
   `j/k` scrolls, `[`/`]` scrolls eight lines. `r` explicitly refreshes the selected
   exact source or pair. Palette commands expose the same operations.

Numeric tokens use `Yojson.Raw`: integer and decimal tokens never pass through
OCaml floats. Numerator/denominator and provider rational deltas remain visible.
The UI neither recomputes eligibility/deltas nor treats command completion as
functional success. Physical qualifications are visible independently of cycle
metrics: functional clock period, implementation constraints and host elapsed time
are not measured Fmax; this memory workload has no firmware/fetch evidence.

## Capture and compare an explicit pair

After opening the selected result's validated detail, use **Workloads: Capture A
left result** or **Workloads: Capture B right result**. When the public inspection
contains its verified absolute `binding.bundle` locator, capture is immediate with
no path-entry form. Each capture retains the result path,
public `source_digest`, bundle path and inspection-reader identity. Changing source
does not retarget either capture. A result change while the bundle form is open
rejects that form's capture.

Older inspection projections without `binding.bundle` retain an explicit absolute
bundle-directory prompt. The UI never guesses it from a directory, identity,
latest pointer or unrelated execution. A supplied bundle cannot override a
verified locator. Capture is unavailable from the list or an unloaded/mismatched
selection, so highlighting B cannot capture A's old document.

Choose **Workloads: Axis resource_policy**, `hardware`, `flow_configuration` or
`descriptive`, then **Workloads: Compare captured A / B (c)**. Axis commands with
both captures present immediately query the new explicit axis. **Swap A / B and
query provider** invalidates the old view and sends the newly ordered pair; no
local delta negation is used. Stable command IDs include `workloads.capture-a`,
`workloads.capture-b`, `workloads.axis.resource_policy`, `workloads.compare`,
`workloads.swap` and `workloads.refresh`.

After a verified comparison, Refresh pins both returned combined side
`source_digest` values independently of the standalone workload digests. Swap
exchanges those side pins with their sources; changing axis clears the combined
comparison-generation pins and reacquires them under the new axis, while preserving
each captured workload digest. Explicit recapture clears the old pair generation.

Comparison shows provider outcomes, eligibility/reasons, exact signed deltas and
comparison digest. Its comparator companion has its own identity, distinct from
the workload-inspection companion captured on each side. Neither identity is
silently relabelled as the original simulation producer.

### Existing positive example

Relative to `/home/wayne/devel/jane/hardcaml_asic_example`, import:

| Slot | Result | Exact bundle under `.dev/asic-pt8-workloads/bundles/` |
| --- | --- | --- |
| A | `acceptance/pt8-workloads/simulation-04/flops/result.json` | `4475418b7acca27b4ce3258e8097efc2b738544d9bc90d571a3489bb27b42761` |
| B | `acceptance/pt8-workloads/simulation-04/exact/result.json` | `c535d00cc950de9ebd438c78cdd99fe33f75bfd4cad1a20d7559fc1ff6f98fda` |

Enter absolute paths in the UI and select `resource_policy`. The established public
pair has seven zero workload deltas (1307 cycles, 525 reads, 262 writes, 787 accepted
operations, 2083 defined observations, one-edge read latency, 787/1307 operations per
cycle). This guide records the existing example evidence; A's native test below
uses a labelled synthetic reader. C/coordinator own actual installed-provider and
fresh-simulation acceptance. Historical physical SRAM is qualified feasibility
context, not a matched physical Flops/Exact area/speed comparison.

## Fresh launch and result handoff

**Workloads: Launch fresh PT.8 workload… (Testing)** opens/creates Testing and
explicitly requests suite discovery. It then uses the existing catalog subset
selection and launch form. Select C's `pt8-memory-workloads` suite and positive
`flops256` and/or `exact256` cases. Supported seed is `34097`, no parameters or
ASIC inputs. The provider enforces these fixed options; changing a view never
launches the workload. The existing form's final `launch` confirmation submits it.

Status, logs, cancellation, rerun, durable history and submission retry remain
FS2-owned. After completion select the intended case in Testing and invoke
**Inspect workload result (selected Testing case)**. It resolves that case's exact
available `flops256-result-reference` or `exact256-result-reference` artifact,
reads at most16KiB through the existing artifact RPC, validates byte span/hash and
the strict reference schema, then imports the supplied absolute path with its
expected public digest. Another attempt/case cannot supply that selection. Missing,
changed, oversized and stale references produce a visible reason.

Those are provider declaration IDs. The public FS2 artifact ID is exactly
`ATTEMPT-flops256-result-reference` or `ATTEMPT-exact256-result-reference`; handoff
requires that exact selected-attempt namespace and its matching case attachment,
not an arbitrary suffix. Both paths are tested with actual backend artifact capture
and byte reads.

Artifact transport, PT.8 simulation attempt, hardware/bundle identity and any ASIC
physical execution remain separate. The result closure stays in C's durable
retention directory; copying a reference does not copy/reinterpret the workload.
Root FIFO/ASIC configurations are unchanged. Use C's isolated session setup for
fresh PT.8 execution.

## Async, cache and restoration

Rendering/filtering/geometry/provenance/palette navigation consume published state.
Read intents alone call `Asic.Operation.Workloads (Load ...)`. The transport owner
uses existing daemon/client/project fences, tile lifetime and view generation,
plus admission/receipt revision floors for reused operation keys. Queries include
ordered targets, axis and both captured workload digests. Changing source/axis,
closing/retyping a tile or reconnecting fences obsolete receipts. The Testing
reference handoff also fences its original session/workspace/artifact/navigation.

Warm workspace reopening requests an existing cached query only when its digest
descriptor is present. A restored response is labelled `CACHED UNVERIFIED`; a cold
or evicted document stays explicitly unloaded until requested. Refresh failures
keep retained facts and diagnostics visible. Parsed documents are reused while
their descriptor digest/provider identity is unchanged. B bounds cache entries,
raw bytes, source validation and provider execution. No provider is called by
the renderer.

Client navigation saves source, A/B captures, axis and query with exact tile and
session membership. New optional schema1 preference fields preserve old sidecars.
Restoration grants no validation status and does not rewrite layout/context state.
Esc/Enter and cached/palette reopening preserve the selected inspection's full
`expected_digest`. Per-path query memory survives comparison and restoration; for
otherwise ambiguous cache inventory, pinned queries sort before unpinned queries
with a stable key tie-breaker. Explicit Import remains the route to capture a new
current source intentionally.

## Initial checks

All Dune commands use the shared lock, isolated build, switch5.2.0+ox and six jobs:

```sh
flock /tmp/opencode/workbench-pt8-build.lock opam exec --switch=5.2.0+ox -- \
  dune build -j6 --build-dir _build_pt8_workbench terminal/main.exe daemon/main.exe
flock /tmp/opencode/workbench-pt8-build.lock opam exec --switch=5.2.0+ox -- \
  dune runtest -j6 --build-dir _build_pt8_workbench terminal
python3 -B terminal/test_workloads_native.py
```

Initial native HTTP/PTY eight-check pass:
`/tmp/opencode/pt8-workloads-ui-br1u5gx5/ui-receipt.json`. It exercises large exact
tokens, explicit pair and axis/swap provider calls, cache-only filtering/reopen,
held old-source response rejection, refresh failure and private-daemon restart.
Earlier failed runs remain under the same temp prefix: one fixture initially put
evidence above the cache root; another exposed ambiguous capture labels; another
incorrectly equated inspect/comparator companion identities. The fixture/labels/UI
identity presentation were corrected before the passing run.

Nine new view tests cover numeric/rational preservation, source/reconnect receipt
fences, ordered pair/axis identities, strict reference schema, pure narrow/wide
rendering, same-key receipt floors, production host input/render/tile lifetimes,
navigation/session restoration and stale capture forms. Additional tests cover
selected-case artifact handoff and custom Workloads-name/layout coexistence. Existing
terminal suites, fresh-process navigation and presentation tests pass. Additive
`workloads=None` defaults were required in existing terminal snapshot test fixtures.

Independent review and actual fresh-provider acceptance remain coordinator/C gates;
this is A's initial frontend pass, not a claim of their completion.

## F1–F4 corrections and revised native handoff

The independent findings in `pt8_workloads_frontend_review.md` are corrected in the
production frontend. Added regressions cover actual backend-prefixed artifact
capture/read and both cases with cross-attempt/case negatives; exact inspection
reopening/cache collisions; highlighted-versus-loaded capture; verified bundle
auto-capture/legacy fallback; distinct target/workload generation domains including
Refresh, Swap, axis changes and restoration; and metric-first narrow presentation.

The full terminal suite and terminal lint/build pass. Updated synthetic native
HTTP/PTY eight-check receipt (including automatic capture without path forms):
`/tmp/opencode/pt8-workloads-ui-594ghnry/ui-receipt.json`.
Matching binaries are `_build_pt8_workbench/default/terminal/main.exe` and
`_build_pt8_workbench/default/daemon/main.exe`, ready for C's actual fresh-run rerun.

The unmodified independent suite was run. It now passes F4 and the F2 pinned-query
assertion, then its line111 fixture calls the production backend validator with
the emitted pinned-A query and a C-digest document. The validator correctly raises
`Captured workload/target digest changed` before the UI assertion. The original
reviewer file is unchanged. A second fixture calls `select_case "exact256"` on an
attempt listing only Flops; that selection is rejected and retains Flops, so it
cannot construct the intended different-case negative after F1 is fixed.

`terminal/frontend_review_recheck.py` generates a **supplemental** test module in
the isolated build directory from the original source. It changes only those two
fixture constructions: the conflicting cached document uses an unpinned query,
and the different-case negative explicitly constructs that selected-case state.
Every original assertion is retained. The generator rejects unexpected source
changes instead of silently adapting the reviewer suite. The supplemental run
passes **45 checks, zero contract failures** through `dune runtest ... terminal`;
this is distinct from claiming that the unchanged original executable completes.
Owned regressions also exercise a valid two-case actual backend capture/read and
unpinned cache collision, without weakening production selection or requests.

Final A binary identities for C's rerun:

| Isolated build path | SHA256 |
| --- | --- |
| `_build_pt8_workbench/default/terminal/main.exe` | `43740a9dcdd1a23f39ab2d4837f1cb570251c4a4910c862906dd001c462d2c46` |
| `_build_pt8_workbench/default/daemon/main.exe` | `ec0108fd3ae65ac8bc8113462bfc1eb4dcdcbecf6410c144fbc982113f495a38` |
| `_build_pt8_workbench/default/terminal/workspaces/export_presets.exe` | `1ec964a22a60121fc091f78dad5ccdb2c64ae42c1e9244a5fc505781fb350ad4` |

Original reviewer source remains unchanged at
`backend/test/frontend_review/review_frontend.ml`, SHA256
`3b759c0e5bbacaefd7fa02b6e33b95b4aff4072eefc8ac14a9514a1d4ca2d87b`.
