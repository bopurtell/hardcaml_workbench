# FS2 simulation v1 — frozen initial interface

Published 2026-10-16. Provider-visible types now live in `provider/wire.ml`,
re-exported by `protocol/simulation.ml`; application RPC/history types remain there.
The daemon endpoint, supervisor integration, terminal experience and real Cyclesim
provider are implemented and verified; see [controls and acceptance](fs2_acceptance.md).

## Terminology and workload composition

A **suite** groups declared **cases**. A case is a runnable configured test/scenario;
an **attempt** is one actual execution with captured selection/seed/parameters.
A project may implement its case using one or more workloads. A **workload** is a
scenario contract: stimulus is one component, alongside execution assumptions/rules,
completion, expected observations/checking requirements and measurement rules.
Reusable drivers, scoreboards/assertions and monitors implement those requirements;
the contract does not require a single workload class or ownership of the whole
verification environment. In UVM terms, sequences/items cover the traffic portion.

FS2v1 exposes suites/cases and execution events, **not** an arbitrary workload graph
or N-workload selection API. PT.8's project-owned cases execute one fixed memory
workload each through this same runner and publish a separately verified result
contract. See [workload terminology](../../hardcaml_asic/docs/guides/variant-comparison.md#terminology-stimulus-workload-test-and-suite).
This clarification changes no frozen wire schema or execution behavior.

## Configuration and process invocation

**Native OCaml adapter support delivered 2026-10-18:** the separately packaged
`hardcaml_workbench_provider` library exposes `Wire`, `Validation` and synchronous
`Runner` helpers. It is recommended for OCaml adapters, not required by this
language-neutral contract. Only the project-owned `test_provider.exe` links it;
standalone test executables, arguments, reports and checkers remain project-owned.
The daemon consumes the same wire types and pure validators. Frozen sexp/bin_io
conformance tests guard the extraction; the FS2v1 interface is unchanged.
See [public API](../provider/README.md) and [migration evidence](native_provider_plan.md).

For a native adapter, `provider_executable` names its absolute installed executable
and `provider_args` may be empty. The Python configuration below remains valid.

Opt-in root file `hardcaml-workbench-simulation.sexp`, independent of the generic
manifest and ASIC config. All five fields are required; unknown fields are errors:

```sexp
((schema_version 1)
 (provider_executable /absolute/path/to/python3)
 (provider_args (/absolute/path/to/provider.py))
 (discovery_timeout_seconds 10)
 (run_timeout_seconds 300))
```

The executable is absolute; prefix arguments may be empty. No shell parsing,
interpolation, PATH guessing, Dune build, or implicit provider build occurs. Run from
the canonical current project root with the project's selected environment using
the existing Dune adapter command prefix (including explicit opam switch if selected).
The provider agent must supply setup/build instructions for its executable.

Exact argv after that environment prefix:

```
EXEC [provider_args...] discover --protocol-version 1
EXEC [provider_args...] run --protocol-version 1 --request ABS_REQUEST --events ABS_EVENTS --artifact-dir ABS_ARTIFACT_DIR
```

Discovery: stdout contains exactly one `Simulation.Discovery.t` S-expression and
whitespace, at most 1 MiB, exit 0 required. Stderr is human diagnostics. Empty suite
list means configured but no suites; every declared suite has at least one case.
Discovery runs as a supervisor job with configured timeout, not on the RPC thread.
No incremental discovery; partial/invalid output never replaces a previous catalog.
Discovery digest is lowercase SHA256 of `Sexp.to_string_mach (Discovery.sexp_of_t d)`.
The public cached catalog remains visible on refresh failure, with `discovery_error`.
Launch is rejected while the latest discovery is failed or in flight.

Run: daemon writes and closes a private request file before spawning. Its type is
`Simulation.Provider.Request.t`; example:

```sexp
((protocol_version 1)
 (attempt_id sim-example)
 (selection
  ((suite counter)
   (cases (increments wraps))
   (seed 42)
   (parameters ((cycles 100)))
   (asic_inputs ()))))
```

Daemon creates an empty private events file and an empty private artifact directory.
Provider opens events for append, writes each complete event plus LF, and flushes it
immediately. Do not truncate/replace this file, write human output into it, fork a
background producer, or keep writing after the foreground provider exits. Stdout and
stderr are exclusively supervisor human logs, read through the existing `Read_log` RPC.
No line is interpreted as a test result from either log stream. Stdin is unused.
The daemon tails the events file live while the supervisor owns the process. Cancellation
uses existing supervisor process-group termination/escalation. Timeout is an incomplete
failed execution, not semantic test failure. No new scheduler is introduced.

## Portable S-expression encoding

Use the exact ppx sexp representation in `Simulation`: records are lists of
`(field value)` pairs, string lists are lists, pairs are two-element lists, `None`
is `()`, `Some x` is `(x)`. Nullary variants are atoms. Provider event constructors
with a named record payload use `(Constructor ((field value) ...))` (Progress,
Case_finished, Artifact); RPC operation inline-record constructors use
`(Constructor (field value) ...)`. Strings with whitespace/delimiters must be
quoted, with OCaml sexp escapes. Python fixtures can emit all string values as quoted
ASCII using JSON string escaping with `ensure_ascii=True` **only for ASCII input**;
non-ASCII JSON `\u` escapes are not sexp escapes. Emit UTF-8 directly or OCaml byte
escapes for non-ASCII. No JSON parser/dependency is required. OCaml providers can use
`Simulation.Provider.Event.sexp_of_t |> Sexp.to_string_mach` plus LF and flush.

Discovery example (one case, one free-string parameter):

```sexp
((protocol_version 1)
 (suites
  (((id counter) (label Counter)
    (cases (((id increments) (label Increments))))
    (parameters (((key cycles) (label Cycles) (default 100) (choices ()))))
    (default_seed 42)))))
```

Suites/cases/parameter keys are project-owned, stable across discovery calls and
scoped to that project (case IDs scoped to suite); use
`[A-Za-z0-9][A-Za-z0-9._-]*`, max 128 bytes. Labels are display only. Seeds are
canonical unsigned 64-bit decimal strings `0..18446744073709551615`; never floats
or signed machine ints. Every launch explicitly supplies a nonempty unique case
list and exactly every declared parameter, including defaults. Empty `choices`
means arbitrary string; otherwise value must equal a choice. Provider validates
domain-specific free-string values and reports execution diagnostics on invalid values.
The backend normalizes cases to discovery order and parameters to key order before
capturing/idempotency comparison. Multiple seeds require separate submissions.

## Live event framing and state machine

One machine-format S-expression per LF-terminated line. No blank lines, comments,
multiline records, CRLF, or extra trailing data. Example complete successful run:

```sexp
((protocol_version 1)(attempt_id sim-example)(sequence 0)(payload Started))
((protocol_version 1)(attempt_id sim-example)(sequence 1)(payload (Case_started increments)))
((protocol_version 1)(attempt_id sim-example)(sequence 2)(payload (Progress ((case_id (increments))(completed 10)(total (100))(unit_ cycles)))))
((protocol_version 1)(attempt_id sim-example)(sequence 3)(payload (Artifact ((id wave)(case_id (increments))(label Waveform)(kind waveform)(media_type application/vnd.gtkwave.vcd)(path trace.vcd)))))
((protocol_version 1)(attempt_id sim-example)(sequence 4)(payload (Case_finished ((case_id increments)(status Passed)(message ())))))
((protocol_version 1)(attempt_id sim-example)(sequence 5)(payload (Finished Passed)))
```

- Version and attempt ID must match request. Sequence starts at zero and increases
  by exactly one. First event is exactly one `Started`; last is exactly one `Finished`.
- Each selected case starts exactly once and finishes exactly once after starting.
  Interleaved active cases are allowed. Unselected/unknown case events are errors.
  A skipped case still needs `Case_started`, then `Case_finished ... Skipped`.
- `Case_finished` admits only `Passed`, `Failed`, `Skipped`. `message` is bounded
  failure/skip detail (not a log). Full reports should be declared artifacts.
- `Progress` may be attempt-wide (`case_id ()`) or for an active case. Completed
  is nonnegative and monotone per scope; unit must remain constant. Total `()` is
  unknown: show a count/indeterminate state, never invented percentage. A known
  total is nonnegative, >= completed, immutable thereafter; unknown may become known.
  Progress is observational and does not prove case completion.
- Artifact IDs are unique within attempt. Case owner, if present, must be selected
  and already started (may already be finished). Attempt artifacts need no case.
- `Finished Passed` requires every selected case terminal, no failed case (skips
  allowed). `Finished Failed` requires every selected case terminal and at least one
  failed case. A suite-level infrastructure failure uses nonzero exit/incomplete
  stream, not an invented case failure. No event is allowed after Finished.
- Process exit and semantic outcome are distinct. Final Passed/Failed is committed
  only after valid Finished, all events drained and exit 0. Exit 0 with failed
  cases is a semantic Failed attempt and successful process execution. Nonzero exit,
  signal, timeout, missing Finished, unterminated last line, malformed event, duplicate,
  gap, wrong identity, limit violation, illegal transition, or post-Finished event
  makes overall outcome `Incomplete`, even if an earlier Finished claimed success.
- On first stream error, preserve accepted case results/artifacts, stop trusting
  further events, record diagnostic and cancel the supervisor producer. Unfinished
  cases become Incomplete at termination. Already completed cases retain their
  observed status; they do not imply whole-attempt success. Cancellation yields
  lifecycle Cancelled and outcome Incomplete, even after a provisional Finished.
  Restart converts Queued/Running records to Interrupted/Incomplete without replay.
- In-flight outcome is Unknown; `next_sequence` is the next expected sequence;
  `recent_events` contains the last 256 **accepted** events only. Clients render
  normalized cases and never need the full stream to reconstruct truth.

## Bounds, artifact ownership and history

Hard limits are constants in `Simulation.Limits`; exceeding input bounds is an
error, never silent truncation. Catalog: 64 suites, 1024 cases **across all suites**,
32 parameters/suite, 64 choices/parameter. Strings <=4096 bytes, no NUL; config
<=16 KiB, <=32 prefix args each <=4096 bytes. Timeouts: discovery 1..60 seconds,
run 1..86400 seconds. Events <=16384 bytes **including LF**, <=100000 events and
<=16 MiB stream total. Partial pending line is bounded by the same per-line limit.
Read capped chunks; do not read an entire oversized file into memory. Log retention
and paging retain existing supervisor behavior, independent of normalized history.

Artifact `path` is normalized relative to ABS_ARTIFACT_DIR, no empty, `.`, `..`,
absolute or NUL components. Only regular files with no symlink in any component
are admitted. Provider closes a file before announcing it and never mutates it
afterwards. Daemon copies it into attempt-owned storage, hashes actual bytes with
SHA256, assigns opaque public ID (not provider-local ID), and publishes only after
copy completes. `size`/`sha256` are options: absent if capture failed before these
were known, retained if a previously captured file later goes missing/changes.
Attempt/case ownership is independent of ASIC identities. Up to
128 artifacts/attempt, <=64 MiB/file and <=256 MiB/attempt. Rejected/missing copies
publish explicit `Rejected`/`Missing` availability and diagnostics; they do not
change observed test status. Provider artifacts are not required for a test pass.
No client-supplied filesystem path is ever read. Artifact kind/media type are bounded
display strings; `waveform`, `failure-report`, `report` are recommended kinds.

Up to 16 explicitly supplied `Asic_input` references; each contains full Run_ref,
exact ASIC attempt, catalog artifact ID and lowercase SHA256. Backend verifies
the exact currently readable evidence before submission; no implicit selection,
no ASIC acceptance contribution. Provider gets these references as provenance, not
automatic copied files. Providers needing actual collateral must support resolving
these exact references themselves; v1 makes no file-staging promise. Empty list is
the normal PDK-free path. Rerun revalidates these references and fails if unavailable.

Per canonical project-root durable history: max 100 attempts, 16 MiB normalized
records total, 512 MiB artifact copies total. Oldest finished attempts evicted
first, with their artifacts; active attempts are never evicted. If no space can
be reclaimed, reject new submissions (Conflict) or mark new artifacts Rejected.
Persist reservations/captured inputs before launching, and persist accepted state
updates atomically. Store bounded recent events, not unbounded raw event streams.
History is Workbench-owned under daemon state directory, root-keyed (not ephemeral
Project_id), record schema version 1. Corrupt/oversized records are skipped with
`history_error`, not interpreted or executed. IDs are opaque and globally unique
across daemon restarts; old job IDs are paired with persistent attempt IDs and never
treated as active jobs in a new daemon. Artifact reads revalidate size/hash; Missing
and Changed are explicit, never an empty successful trace. Logs are not promised
durable across restart; historical case details/reports/traces remain inspectable.

## Standalone RPC and terminal handoff

Implemented `POST /api/v1/simulation`, same v1 header/content-type/sexp codec and instance
fence as `/api/v1/asic`. Hello capability `simulation`. Delivered native client method:
`simulation : t -> Simulation.Request.t -> Simulation.Response.t Or_error.t Deferred.t`
(outer result is HTTP/transport failure, inner result is the typed RPC response).
Backend service method: `simulation : Service.t -> Simulation.Request.t ->
Simulation.Response.t Deferred.t`. No additions to the frozen V1 event union;
terminal polls this RPC while normal jobs/logs continue through existing transport.

Every response is `(Snapshot.t, V1.Error.t) Result.t`. Snapshot always includes
configuration/catalog/error state and one bounded history page; detail/byte_page
are per-response values, not shared current selection or accumulated caches.
Terminal fences responses by daemon instance, project, selected attempt and request.

| Operation | Result and effects |
|---|---|
| `Get` | Latest cached catalog and newest <=25 summaries. No tools. |
| `Discover` | Coalesces active discovery for project; schedules supervisor job; returns `discovery_job` promptly. Poll Get. Completed refresh requires another Discover. |
| `Launch {submission_key; discovery_digest; selection}` | Validate current successful catalog/config, digest fence, explicit inputs; reserve supervisor job and durable attempt. Returns `detail` with captured inputs and queued/running state. |
| `Rerun {submission_key; attempt_id; cases}` | Nonempty subset of original selected cases; capture same seed, parameter values and ASIC refs, validate against **current** discovery/config/environment; new attempt/job with `parent` containing immediate original attempt ID and job. No archived-build promise. Returns new detail. |
| `Observe attempt_id` | Read durable normalized detail and live state; never starts a process. |
| `History {before; limit}` | Newest first, limit 1..25. `before` is an opaque `next_before` cursor scoped to project. Page strictly older than cursor, so new inserts do not duplicate older pages. Invalid cursor is Invalid_request. |
| `Cancel attempt_id` | Existing supervisor cancellation, returns detail. Idempotent for terminal records. Does not cancel other attempts or tile selections. |
| `Read_artifact_bytes {attempt_id; artifact_id; sha256; offset; limit}` | Read only owned catalog artifact, expected digest required; offset 0..size, limit 1..65536 decoded bytes. Returns detail plus byte_page, no tools. Lowercase hex preserves arbitrary bytes. next_offset=offset+decoded length; total_size immutable; eof iff next_offset=size; offset=size returns empty EOF. |

Submission keys are valid key strings (<=128 bytes), project-root scoped and shared
with the supervisor's submission registry. Retrying same operation and normalized
payload returns the same attempt/job even if it finished. Reusing key with different
payload is Conflict; rerun needs a fresh key to create a distinct attempt. Persist
key/payload mapping with retained attempt; once evicted, no cross-retention dedup
guarantee. Rerun retries must check reservation before re-reading mutable source state.
Latest current discovery is required for rerun; it never auto-refreshes or executes
discovery on behalf of Observe/Get/History. Config is re-read at submission;
discovery validity is tied to config identity so changed config requires Discover.

Not configured: Get/History/Observe/artifact reads still work; Discover/Launch/Rerun
return Unsupported_operation. Missing attempt/artifact: Not_found. Invalid schema,
selection, bounds: Invalid_request. Stale discovery/digest/ASIC evidence, changed
artifact, key conflict: Conflict. Missing artifact bytes: Not_found. Filesystem/store
failure: Internal_failure. Discovery/provider runtime failures appear in snapshot
diagnostics/detail, not as a manufactured test failure. Instance_changed retains
existing semantics. No JSON-wrapped raw bytes or UTF-8 decoding in artifact export.

## Implementation status

Implemented: portable wire/provider types, config parser/validator, bounded discovery,
selection normalization and event-line validation, exact process argv adapter, daemon
endpoint/capability and native client, Service-supervised discovery/run jobs, live
event reduction, durable reservations/history, attempt-owned artifact capture and
hash-fenced raw-byte reads. Simulation tasks use the existing root queue, logs,
process-group cancellation and escalation; there is no simulation scheduler.

`backend/simulation_task.ml` is the supervisor callback boundary;
`simulation_reducer.ml` owns semantic state; `simulation_files.ml` owns bounded
descriptor-verified reads and atomic fsync/rename writes; `simulation_service.ml`
owns root-keyed durable history and RPC projection. Reservations are persisted before
execution and checked before mutable catalog/config validation on retries. Active
reservations also enter Service's submission registry and are released on completion;
retained durable records provide subsequent deduplication.

Backend verification uses `/tmp/opencode/fs2-build-backend`, serial commands with
`-j 8`: targeted backend/protocol/config/adapter/daemon tests, daemon/backend/native
client compilation, owned-library lint and owned-file format checks. Backend tests
exercise real foreground fixture processes, concurrency/conflicts, current-project
rerun capture, binary byte pages, malformed/truncated/duplicate/gapped streams,
oversized lines/streams, timeout/cancellation/root queueing, stale discovery/config,
symlink/changed/missing artifacts, durable restart without replay, corrupt history,
pagination and active-preserving history eviction. Final combined format/lint/full
tests/build passed at `-j 20`; real Cyclesim and native HTTP/PTY acceptance passed.
See [FS2 acceptance](fs2_acceptance.md) for the final reviewed evidence and limits.
