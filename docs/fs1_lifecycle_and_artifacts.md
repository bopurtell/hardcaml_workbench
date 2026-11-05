# FS1 lifecycle finalization and artifacts

Recorded 2026-10-15 against the current implementation and retained lifecycle
evidence. This records the implemented producer lifecycle, bounded terminal-result
artifact browser, and explicit external text export. It supplements
[FS1 acceptance](fs1_acceptance.md): that earlier record's statements that a
finalization producer and artifact viewer are absent predate this slice.
The subsequent [rich investigation delivery](fs1_investigation.md) completes the
adopted-evidence FS1 scope, including timing paths, measured clock reports,
physical/routing tables and exact binary handoff. This record preserves the
lifecycle and text-viewer evidence from the earlier slice.

## Finalize from the command palette

For an ASIC run with an execution reference, the palette provides:

- **Finalize (collect) asic/RUN**: collect terminal reports without requesting
  external acceptance. A successful collection has acceptance `not_evaluated`.
- **Finalize and accept asic/RUN**: open the explicit collateral form; Enter
  submits it, and Esc closes it. All five fields are required strings in an
  OCaml record S-expression:

  ```sexp
  ((support_tools "/absolute/support-tools")
   (precheck_python "/absolute/bin/python3")
   (testbench "/absolute/testbench with spaces.sv")
   (testbench_top "tb_top")
   (replay_trace "/absolute/exported-trace.json"))
  ```

  The form is limited to 4096 UTF-8 bytes. Quote paths containing spaces; there
  is no shell expansion or implicit collateral discovery. The four path fields
  must be absolute; `testbench_top` must be nonblank. The parser is
  `Asic.Acceptance.t_of_sexp`, not a shell command parser.
- **Reconnect finalization KEY (read-only)**: observe the retained exact
  allocation through `Observe_finalization KEY`.
- **Inspect finalization for asic/RUN (enter exact attempt)**: adopt an existing
  public finalization reference through `Inspect_finalization`; this does not
  start a producer.
- **Browse reports/artifacts asic/RUN**: list files from the adopted terminal
  result and open the bounded reader.

Palette dispatch captures its target context. The acceptance form retains the
run, exact `execution_file`, and submission key while being edited; a changed
command target is rejected rather than silently retargeted. Submission uses
`Finalize { key; run; execution_file; acceptance }`, where collect has `None`
and acceptance has `Some` of the five-field record.

### Exact inputs, persistent keys, and ownership

The daemon reserves the key and complete inputs persistently **before** scheduling
the producer. Reusing a key with the same run, execution filename, and acceptance
record is a no-op, both in flight and after completion or restart. Different
inputs under the same key are rejected. A fresh palette invocation is a new
submission; an idempotent retry must reuse the original key.

Eligibility validates the exact registered, canonical execution path, provider
report, and completed fresh six-stage execution: synthesis, floorplan, placement,
CTS, routing, and signoff. All six selected publications must match. The daemon
captures the execution SHA-256 before launching and checks it against the receipt
and again before terminal import. This does not resume physical implementation.

The sole owned producer streams an early allocation event. The daemon persists
the returned `attempt` and operation identity, then polls that exact reference
for phase/status and imports validated terminal results automatically. It never
finds an operation by newest directory, inferred run ID, or recovered PID.
Client detach leaves daemon-owned work running.

The adapter invokes the existing adopted provider with argument vectors:

```text
finalize EXECUTION --operation-store RESULTS_ROOT/finalizations --json
finalize EXECUTION --operation-store RESULTS_ROOT/finalizations --json --accept --support-tools SUPPORT_TOOLS --precheck-python PYTHON --testbench TESTBENCH --testbench-top TOP --replay-trace TRACE
```

Storage is the configured `results_root/finalizations`; operation receipts and
normalized results live in the returned attempt. The Workbench registry retains
reservations, captured inputs/hash, and references separately from provider
storage. This uses the existing adopted provider without an upgrade, install,
download, or provider rewrite.

### State is not a verdict

`Asic.Finalization` exposes independent facts:

| Field | Meaning |
| --- | --- |
| `state` | Workbench lifecycle state, such as pending, executing, unknown, completed, failed, or interrupted. |
| `phase` | Provider-supplied progress, e.g. collection, external_postcheck, or acceptance. |
| `owned` | Whether this daemon owns the producer lifecycle; not whether acceptance passed. |
| `operation_status` | Receipt status: running, completed, failed, or interrupted. |
| `acceptance` | Separate verdict: not_evaluated, pass, or fail. |
| `error` | Producer/observation failure information, independent of the receipt facts. |

The pending task (`finalize:KEY`) has its own `state` and `error`. An accepted RPC
does not imply a successful task, completed collection does not imply acceptance,
and a nonzero producer outcome can still publish inspectable receipt/results.
Terminal summaries also retain physical completion and timing-goal facts
separately from operation and acceptance outcomes.

`Cancel KEY` targets the daemon's task and its owned producer, stops automatic
observation, and reaps the process. Finalization uses a **15-second producer
stop grace** before escalation, plus a **1800-second overall lifecycle deadline**
and a 1800-second process bound. The grace is cleanup time, not an acceptance
timeout or a pass criterion. Cancellation can leave an interrupted receipt and
a failed pending task; these are deliberately distinct.

On daemon restart, retained finalizations always have `owned = false`; pending
or executing records become `unknown`. Startup and same-key retries never replay
the producer. Explicit `Observe_finalization` performs exact-reference read-only
inspection and can refresh/import evidence, but never reacquires process
ownership. Without a retained allocation it reports an error rather than
relaunching. A restarted observer cannot cancel another owner's producer.

## Artifact catalog and bounded text reads

`List_artifacts RUN` requires an adopted validated terminal summary. The catalog
is derived from that selected terminal result, not an arbitrary filesystem walk:
normalized results, declared acceptance/postcheck files, raw mapped artifacts,
metric/check sources, and selected checkpoint evidence are validated against
the operation/results context and hashes. Sources without provider-declared
hashes are explicitly labeled **observed SHA-256; not provider-declared**.

Limits and identities:

- At most **32 catalog entries per run**; each file is bounded to **16 MiB**.
- `Read_artifact { run; artifact_id; offset; limit }` accepts nonnegative raw-byte
  offsets and limits **1..65536 bytes (64 KiB)**. The UI requests **4096 bytes
  (4 KiB)** at a time.
- References carry `id`, `run`, `terminal_attempt`, `label`, daemon-host `path`,
  `sha256`, `size`, and `kind`. Pages carry `artifact_id`, `run`,
  `terminal_attempt`, `sha256`, `offset`, `limit`, `next_offset`, `eof`, `text`,
  and `error`.
- Full page identity is **run + artifact ID + terminal attempt + hash + offset
  + limit**. Backend, plain RPC waits, and UI share the scheduling key
  `artifact-read:RUN_ID:ARTIFACT_ID:OFFSET:LIMIT`; attempt/hash are additionally
  validated against the current reference. Different offsets or limits cannot
  coalesce as the same page request.
- The snapshot retains **eight pages shared across readers**, not eight pages
  per viewer. Relisting clears that run's pages. The UI rejects stale response
  tickets by daemon instance, project, viewer generation, and captured request.
- Artifact filesystem work shares the four-job read-query budget with provider
  queries; cancellation is checked after dequeueing and before file reads.

Files are read on the **daemon host**. Canonical paths, regular-file descriptors,
size/stability, and SHA-256 are checked; each read revalidates the listed bytes.
The client cannot supply an arbitrary daemon path to read. Binary/invalid-UTF-8
or NUL-containing files remain catalog metadata; a text read returns an error
and empty text, not decoded binary data.

Text pages end on UTF-8 scalar boundaries. Control characters and directional
override/isolate controls are removed, preserving tabs/newlines. Offsets and
`next_offset` count **original raw bytes**, not sanitized text characters or
display rows; even a page containing only removed controls must advance.

In **REPORTS / ARTIFACTS**, Up/Down selects a catalog entry; Enter reads it.
In the reader, `n` follows `next_offset`, `p` uses the prior offset history,
Up/Down scrolls, and Esc returns to the catalog; another Esc closes it. If a
completed read's page has already been evicted from the shared snapshot, the UI
shows **Page expired; read again (Enter)**. Enter reissues that exact page.
A missing artifact or changed attempt/hash requires returning to the catalog
and listing the current evidence.

Catalog and page operations validate/read existing files without calling the
provider or launching EDA. They are separate from Finalize's producer and its
explicit acceptance work. Selection, layout, browsing, and paging are not
implicit EDA actions.

## Optional terminal-host external text export

External viewing is disabled by default. Configure the **client**, for example:

```sh
_build/default/terminal/main.exe --artifact-viewer /absolute/path/to/text-viewer
```

`--artifact-viewer` takes one absolute executable filename, not a shell command
or an executable plus embedded arguments. In the artifact catalog or reader,
explicit `x` exports a selected eligible text file. Binary/non-text entries have
no external text export.

The client fetches the **complete sanitized text**, starting at offset zero via
64-KiB pages, rather than exporting only the visible 4-KiB page. Every page is
checked against the captured reference, hash, attempt, offset, limit, progress,
and EOF; a changed or incomplete reference fails the export. Export is bounded
to 16 MiB, 4096 pages, and 120 seconds.

The publisher creates a private terminal-host temporary directory (0700), with
`artifact.txt` and `metadata.sexp` (both 0600). Metadata preserves the original
reference/raw SHA-256 and exported-text SHA-256, explicitly declaring
**Sanitized UTF-8 text; not byte-identical provider raw bytes**. The executable
is launched directly with just the new local `.txt` path as its argument: no
shell and no direct daemon-host path opening. Files are retained for the
viewer/user, including on spawn failure. The UI does not wait for GUI exit or
forward viewer output into the terminal.

## Retained acceptance evidence

The real harness is `scripts/test-fs1-lifecycle.py`. The following existing
`/tmp/opencode/workbench-fs1-lifecycle-SUFFIX/result.json` files were inspected;
these are recorded runs, not new executions for this documentation update.

| Suffix / mode | `status` | `finalization.state` / `operation_status` | `phase` | `acceptance` | `producer_count` |
| --- | --- | --- | --- | --- | --- |
| `q8iah0t2` / collect | passed | completed / completed | collection | not_evaluated | 1 |
| `qkm54grn` / collect, latest including external fixture | passed | completed / completed | collection | not_evaluated | 1 |
| `2p10_520` / --accept | passed | completed / completed | acceptance | pass | 1 |
| `wtprmfgc` / --cancel | passed | interrupted / interrupted | external_postcheck | not_evaluated | 1 |

All four have `input_files_unchanged: true` and final `owned: "false"`.
The result JSON serializes typed S-expression records: optional fields such as
`phase`, `operation_status`, and `acceptance` are singleton arrays, and typed
booleans within `finalization` are strings. Top-level `status`, `mode`,
`producer_count`, and `input_files_unchanged` are harness JSON fields.
`operation-outcome.json` records `finalization`, `pending`, and `receipt`
separately: collect/accept pending states are `completed` with receipt exit 0;
cancel pending is `failed`, while its receipt is `interrupted`, exit 143.
That cancelled harness run passed its cancellation assertions; acceptance did
not pass.

Each directory retains the exact `key` and `attempt`, provider call log,
operation outcome, PTY captures, descendants/survivors and container inventories,
and `files-before.json` / `files-after.json`. Checks cover exact original
allocation/execution, one producer, detach, same-key retries and mismatch
rejection, restart without replay, and explicit read-only observation. Original
evidence/config/provider/collateral inventories were unchanged. No owned live
descendants or new transport containers remained at completion.

The latest collect directory `qkm54grn` additionally has
`artifact-export-result.json` and `result.json.artifact_export` with
`status: "passed"`, `invocations: 1`, `provider_calls_unchanged: true`,
`producer_count: 1`, and `binary_export_unavailable: true`. The fixture observed
the complete 10606-byte sanitized `results.json`, exact local-path-only argv,
metadata, and private permissions (JSON decimal modes 384 = 0600 and 448 = 0700).
Its viewer is a **fake local observer executable**, not a real GUI application;
this establishes export/launch behavior, not real GUI rendering coverage.

### Parent-run commands

Use existing binaries and retained physical/acceptance inputs. Run modes
**serially**, with a bounded invocation for each; the wrapper enforces an
inclusive budget of at most 1800 seconds and reserves cleanup time internally.
A shell timeout can allow a small outer cleanup margin:

```sh
./scripts/with-switch.sh timeout --signal=TERM --kill-after=15s 1850s python3 -B scripts/test-fs1-lifecycle.py --budget 1800
./scripts/with-switch.sh timeout --signal=TERM --kill-after=15s 1850s python3 -B scripts/test-fs1-lifecycle.py --budget 1800 --accept
./scripts/with-switch.sh timeout --signal=TERM --kill-after=15s 1850s python3 -B scripts/test-fs1-lifecycle.py --budget 1800 --cancel
```

When invoked through a tool, set its timeout to accommodate that outer bound.
The harness uses a private project/state/results tree and an allowlisting relay
to the exact adopted provider, permits one finalization producer, and rejects
physical/project execution. Acceptance uses retained explicit collateral and
the inspected cached Nix wrapper that forbids builds/downloads.

Parent verification passed serially: `dune build -j20 @fmt @lint`, full
`dune build -j20`, and full `dune runtest -j20`, through `scripts/with-switch.sh`.
Installed native lifecycle/discovery/RTL/hierarchy/resize checks also passed.
The full suite's existing Git provenance fixture was inspected and isolated in
its temporary project with inherited Git selectors cleared; no live-checkout
Git mutations were performed. The five-mode actual Ctrl-C PTY matrix passed at
`/tmp/opencode/workbench-terminal-interrupt-oepfu0em`.

Additional fixture coverage includes concurrent different-offset/different-limit
page requests, shared-page eviction/retry, stale transport errors across reopened
viewers, and successful observation recovery without erasing genuine producer
failures. These are deterministic fixture cases, distinct from the real-tool
collect/accept/cancel specimens above.

## Implementation map and remaining scope

The subsequent [WB-065 bounded lifecycle matrix](asic_lifecycle_matrix.md) adds
deterministic allocation/cancellation, late-response, HTTP detach/concurrent-reader
and reconnect ownership evidence, with verification and explicit remaining gaps.

- `protocol/asic.ml`, `protocol/asic_artifact.ml`: operations, lifecycle facts,
  collateral record, references/pages, and shared read key.
- `adapters/asic_adapter.ml`: exact provider argument vectors and operation store.
- `backend/asic_service.ml`, `backend/asic_process.ml`: persistent reservation,
  ownership, eligibility/hash checks, polling, cancellation, restart, and pages.
- `backend/asic_artifacts.ml`: selected terminal-result catalog, filesystem/hash
  validation, binary classification, raw-byte paging, and text sanitization.
- `terminal/main.ml`, `terminal/workspace_host.ml`, `terminal/host_view.ml`:
  palette commands, captured input, and presentation.
- `terminal/artifact_view.ml`, `terminal/artifact_export.ml`: bounded reader,
  stale/expired-page recovery, complete sanitized export, and direct launch.

The later investigation slice adds timing-path exploration, measured clocks,
physical/routing/congestion tables and byte-preserving external handoff. General
artifact provenance beyond the selected adopted terminal result and embedded
graphical editing remain later work; the bounded catalog is not a claim of
complete provenance across all tool outputs.
