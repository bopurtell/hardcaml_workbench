# PT.8 Workloads backend — independent A review

**Correction recheck, 2026-11-05: R1 and R2 are closed in the bounded reviewed
scope.** The unchanged historical probe and a separate schema-2 wrapper confirm
rejection of the original failures. See the correction recheck below for exact
sources, receipts, descriptor-leak controls and limits. Original findings and
receipts are preserved as history.

2026-11-05. Reviewed B after its initial pass. **Two reproducible admission/storage
gaps found; no B production or test files edited.** Configuration lifecycle and
failure-diagnostic durability observations are recorded separately below.

## Scope, implementation and reproduction

Independent probes live in `review_pt8_workloads_backend/{probe.ml,provider.py,dune}`.
They call the production `Asic_workloads_service` admission/cache APIs and
`Asic_service.handle` scheduler/process path. The synthetic foreground reader is
independent of B's test fixtures. It emits explicitly synthetic public envelopes;
it does not run ASIC verification, simulation or EDA. Provider/config/alias/cache
mutations occur only in new `/tmp/opencode/pt8-backend-review-*` fixtures.

Run from the Workbench root:

```sh
flock /tmp/opencode/workbench-pt8-build.lock opam exec --switch=5.2.0+ox -- \
  dune build -j6 --build-dir _build_pt8_workbench review_pt8_workloads_backend/probe.exe
_build_pt8_workbench/default/review_pt8_workloads_backend/probe.exe \
  review_pt8_workloads_backend/provider.py
```

Final receipt: **`/tmp/opencode/pt8-backend-review-.tmp.38eEgB/receipt.json`**.
It contains59 recorded observations, source SHA256 values and the probe executable
SHA256. Harness exit0 means the review/control sequence completed, **not** that
the backend has no findings. Findings are deliberately recorded as observations
rather than aborting before subsequent controls can run.

Reviewed identities:

| File | SHA256 |
| --- | --- |
| `backend/asic_workloads_service.ml` | `11e45a56ffab56ce35c99bb8f0c141ea312cb70d328df94a7bd157cfe268bf51` |
| `backend/asic_service.ml` | `c6f03b7f20fac59b1c5e48f99294044aa7730283fa4e00bac689f157fbea9c9f` |
| `backend/asic_process.ml` | `4074b3c87f7b1f18d6c55b868759eed7faefc785e1b6d43ac6e75e94f7c99045` |
| `adapters/asic_adapter.ml` | `d1e0cc2550fcf87cb8e20e30e7ea57fb1e81f3a3dc208d2e6f6dfac78b8cfb62` |
| `protocol/asic_workloads.ml` | `294d7245d844bde0fdb83200c863f51205702d73c95a487005943f39c6e8fd0d` |

## R1 — P2: state-root alias retarget bypasses cache/evidence separation

**Locations:** `backend/asic_workloads_service.ml:200–201,247–260,306–321`;
`backend/asic_service.ml:2357–2375`.

Cache/evidence separation is checked before the public read. The persisted cache
filename retains the original `state_dir` spelling. After the read, selected
evidence root aliases and provider identities are checked again, but the cache
root alias is not. `publish` creates its temporary file and renames via that
mutable cache directory spelling.

**Exact reproduction, `alias_and_config` / `state-alias` fixture:**

1. Create `state-alias/state-link` pointing to `state-alias/outside`, separate
   from the selected `state-alias/retained/result.json` directory.
2. Construct the real `Asic_service` with that absolute state-link path.
3. Submit `Workloads (Load (Inspect RESULT) refresh=true)` and hold the reader
   at its explicit `entered`/`gate` barrier. Separation has passed at this point.
4. Retarget only `state-link` to `state-alias/retained`, leaving the selected
   result path and provider identities unchanged. Release the gate.
5. The operation succeeds, reports `Validated`, and writes this new file into
   the selected evidence root:

```text
/tmp/opencode/pt8-backend-review-.tmp.38eEgB/state-alias/retained/
  asic-workloads-32016cdb438887437bc8d3f5dd2f9acd7b98d5d5ed3763461af319688d619cfc.sexp
```

Receipt observation: `state alias retarget writes cache into evidence root` has
`validated:true` and a nonempty `files` array. This is an actual cache write into
the selected evidence directory, not merely a missed diagnostic. No pre-existing
user evidence was involved.

**Bounded correction:** anchor cache publication to the validated cache directory
generation/canonical location, ideally descriptor-relative, and enforce separation
at publication. Do not create temporary files through an alias that can now resolve
inside evidence. Merely checking source aliases again does not cover this directory.
The required regression is: the retarget either rejects before any evidence-root
write, or publication remains anchored to the original separated directory.

This probe requires a state-directory alias change while a read is pending; it
does not establish a failure for ordinary stable private state directories.

## R2 — P2: restored cache skips live query-to-document target binding

**Locations:** `backend/asic_workloads_service.ml:200–220` versus live
`check_targets:332–347` and its caller `backend/asic_service.ml:2374–2375`.

Restore checks the checksum, query/key, raw public envelope, expected digests and
response/descriptor equality. It does not check that the document belongs to the
cached query's selected result/targets. The live read path checks this separately
with `check_targets`, so restore admits a state the live path rejects.

**Exact reproduction, `cache_probe`:**

1. Publish a valid inspection for query `/original/result.json`. Its raw
   `provenance.sources` contains that exact path.
2. In the disposable persisted cache, replace the descriptor's query path with
   `/different/result.json`; update descriptor/response operation keys to the new
   query and recompute the cache checksum using the existing item serialization.
   Keep the response JSON, public digest, provider identity and descriptor digest
   unchanged.
3. `create ~identity:"independent-context"` accepts the entry with no cache error.
   Selecting `/different/result.json` returns the original-path payload.
4. The **same payload** passed to production
   `check_targets wrong_query ~paths:["/different/result.json"]` rejects.

Receipt observations:

```text
coherent cache query rebind accepted with original raw target:
  {"selected":true,"cache_error":null}
same rebound payload rejected by live target binding: true
```

The fixture retains `cache-forgery/original-cache.sexp` and
`cache-forgery/rebound-cache.sexp`. Its later malformed-envelope control alters the
active hashed cache file; use these named snapshots to inspect the two inputs.

**Bounded correction:** retain the admitted canonical target/source bindings with
the cached item and validate the restored JSON against those bindings as well as
the query and checksums. Preserve legitimate root-alias handling. Cache-only
restore must not call providers or reinterpret changed current filesystem roots
as historical bindings.

This requires a coherently rewritten local cache; random corruption already
rejects. It is a cache-admission consistency gap, **not** an authentication claim
or a demonstrated live-provider target-binding bypass. Restored freshness is
`Cached_unverified`; this probe does not turn it into `Validated`.

## Controls that passed

- **Digest domains:** distinct top-level comparison-side digests and nested
  standalone workload digests pass together. Substituting the standalone digest
  for the combined side digest rejects. Changed Inspect and nested comparison
  expectations reject. Live wrong-target and nested-digest failures preserve the
  original captured pair with `Refresh_failed`.
- **Strict admission:** wrong contract/version, extra outer fields, escaped
  duplicate keys, unexpected workload attachment, trailing-comma/tuple/nonfinite
  numeric forms reject. Exact integer `9007199254740993` remains unchanged in raw
  stored bytes. Malformed raw cached envelopes reject even with a new checksum.
- **Process bounds:** >1MiB single record and >1MiB multi-line stdout reject;
  exactly1MiB padded valid JSON passes. Two MiB stderr is drained without deadlock.
  Oversized metadata is rejected before the reader runs. Prior successful data
  remains selected and marked failed after drain errors.
- **Authorization:** false/missing and schema/read-only-incompatible capabilities
  reject. A real metadata refusal prevents the reader subprocess from starting.
- **Provider generations:** held reads reject helper-byte replacement, launcher-byte
  replacement, and byte-identical launcher alias replacement to another canonical
  path. Errors are `Workload provider changed during read`; original payloads stay
  present and affected owned child PIDs are reaped.
- **Source aliases:** retargeting a selected result's parent-root alias during a
  held read rejects with `Workload selected root aliases changed during read`.
  This contrasts with R1's unprotected cache-root alias.
- **Async lifecycle:** same-key held refreshes coalesce; another query remains the
  selected query after the old read completes. Failed/cancelled refreshes preserve
  earlier payload with failure freshness. Cancellation reaps the held owned child.
- **Context/persistence:** Get and restart Get launch no provider; restored entries
  are cached-unverified. Copying a checksummed cache into another context's cache
  filename rejects its internal identity. R2 is the remaining target-binding gap.

## Nonblocking lifecycle observations / owner decisions

### Loaded project configuration remains immutable across Refresh

`Asic_service.handle:3577–3586` memoizes the project by root/environment;
`load_project:359–367` binds the originally read config into its cache identity.
Workloads uses that captured config. In the private `config-change` fixture,
changing the on-disk provider executable to `/nonexistent/review-changed-provider`
then explicitly refreshing still executes the original provider and returns
`Validated`.

This is **not counted as a newly introduced PT.8 defect**: the general service
already treats provider project configuration as immutable captured scope. Its
source/provider identities are not relabelled as the new config. If Workloads
Refresh is intended to reject changed on-disk config, add a current-config equality
fence (the existing fresh-workflow path uses such a check); otherwise document
that context reload/restart is required to adopt configuration changes. The probe
records the exact behavior so this is an explicit lifecycle decision.

### Selected-query refresh failure diagnostic is not durable by itself

`fail:238–245` changes only memory; `publish` persists successful publication.
After success, failed refresh, and restart, that query restores the last successful
cache as `Cached_unverified`, with its last refresh diagnostic absent. The receipt
checks the **specific query key**, avoiding an unrelated failed pair's diagnostic.

This does not produce falsely validated results, so it is a nonblocking durability
observation unless failure-history persistence is required. The distinction matters:
the last retained payload survives and is qualified, but the reason refresh failed
does not necessarily survive restart.

## Preservation

Only the new independent review directory and this document were added during
this review. No B production/tests, frontend implementation, existing configs,
default build directory, live daemons, root example files, provider selections or
Protemu were changed. All builds used the prescribed lock, switch, isolated build
directory and explicit six-job limit. B/coordinator own any corrections and their
regressions; these independent probes remain available unchanged for rechecking.

## Independent correction recheck — R1/R2 closed

Read B's `pt8_workloads_backend_corrections.md`, then reviewed the actual
descriptor-bound storage and schema-2 publication/restore paths. **No B production
or test files were edited.** New independent wrapper files are confined to
`review_pt8_workloads_backend/schema2/`; the original `probe.ml`, `provider.py`,
original Dune target and historical receipts were left unchanged.

### Reproduction commands and receipts

From the Workbench root, the original probe was rebuilt and rerun unchanged:

```sh
flock /tmp/opencode/workbench-pt8-build.lock opam exec --switch=5.2.0+ox -- \
  dune build -j6 --build-dir _build_pt8_workbench review_pt8_workloads_backend/probe.exe
_build_pt8_workbench/default/review_pt8_workloads_backend/probe.exe \
  review_pt8_workloads_backend/provider.py
```

Its new receipt is
**`/tmp/opencode/pt8-backend-review-.tmp.1xG5Ht/receipt.json`**. All59 observations
completed. The original failure observations now report:

```text
state alias retarget writes cache into evidence root:
  {"files":[],"validated":false}
coherent cache query rebind accepted with original raw target:
  {"selected":false,"cache_error":"(Failure ... does not bind selected result path)"}
```

The original probe's later `same rebound payload rejected by live target binding`
assertion is no longer a substantive control after restore refuses the payload:
its `Option.value_exn` is inside the expected-rejection thunk. The separate wrapper
avoids relying on that assertion and exercises explicit schema-2 coherent forgeries.

Run the new standalone wrapper:

```sh
flock /tmp/opencode/workbench-pt8-build.lock opam exec --switch=5.2.0+ox -- \
  dune build -j6 --build-dir _build_pt8_workbench \
  review_pt8_workloads_backend/schema2/recheck.exe
_build_pt8_workbench/default/review_pt8_workloads_backend/schema2/recheck.exe \
  review_pt8_workloads_backend/provider.py
```

Final wrapper receipt:
**`/tmp/opencode/pt8-backend-corrections-review-.tmp.2Xx8R5/receipt.json`**.
It records **61 observations**, `error:null`, all positive/rejection controls true.
Counts include diagnostics and FD-count records; they are not61 independent tests.
The generated wrapper retains the historical helper definitions and replaces only
their entrypoint with new correction cases. Its generator checks the historical
entrypoint exactly. Generated code stays in the isolated build directory.

### R1 disposition: corrected and independently verified

The held real-service read starts from a successful persisted inspection, with
the state alias pointing outside retained evidence. Its new public response has a
different digest; there is no expected-digest refusal masking the storage check.
After the reader enters its gate, the test retargets the state alias into the
selected result directory and releases it.

Observed:

- Rejection reason: **`Workload cache directory alias changed`**.
- Entire retained-directory membership is unchanged, including no cache or
  temporary file additions.
- Original persisted cache bytes are unchanged.
- Prior in-memory payload and digest remain selected with `Refresh_failed` and
  a visible cache diagnostic, rather than admitting the new payload as Validated.
- No temporary file remains in either the original cache directory or evidence.
- Restoring the original alias permits explicit refresh to publish the new digest;
  the successful repair clears the storage diagnostic.

Additional descriptor-level controls use deterministic `before_write` barriers,
not timing sleeps to choose race positions. Alias retargets at callbacks1/2/3
(before directory admission, after admission/before file creation, and before
replacement) reject with old bytes preserved and no evidence writes. Renaming a
canonical ancestor and substituting an evidence symlink at callbacks2/3 also
rejects, with cleanup attached to the admitted old directory.

Failure resource controls in one process:

| Path exercised | Repetitions after warmup | FDs before / after | Temporary leftovers |
| --- | ---: | --- | --- |
| Destination-directory collision at final rename, after output FD creation/write | 256 | 12 /12 | 0 |
| Malformed cached-record restore after storage read | 256 | 12 /12 | n/a |

These establish zero observed descriptor growth on those failure paths. They do
not claim every possible close/write/filesystem exception has been injected.

### R2 disposition: corrected and independently verified

The schema-2 wrapper starts from a successful production cache containing its
historical `(query path, canonical admitted path)` bindings. For each negative it
rewrites query/descriptor/response keys **and** relevant binding paths, recomputes
the checksum over the exact item serialization, and leaves the admitted raw public
document unchanged. Before restore it proves that the same public envelope still
passes structural/digest admission under the rewritten query; rejection therefore
comes from the new query/binding/document association checks.

| Rebinding | Observed restore rejection |
| --- | --- |
| Inspection result path, with both original alias and canonical binding changed | `Workload inspection does not bind selected result path` |
| Comparison's right target, retaining expected combined and nested digests | `Comparison returned different selected targets` |
| Comparison's nested right workload path, retaining its captured digest | `Workload inspection does not bind selected result path` |

Every case leaves no selected response, no admitted entries and a cache diagnostic.
Reinstating each original cached record restores it successfully. The wrapper also
changes the raw inspection's source path while keeping the query/bindings and
coherently checksummed envelope intact; that wrong-source document rejects.

Positive compatibility controls:

- Remove the original source file **and** its root alias, then reopen: the exact
  historical response still restores with `Cached_unverified` and no source IO
  prerequisite. No provider is invoked by this cache API.
- Version1 derived cache is rejected with a diagnostic, rather than acquiring
  invented historical bindings.
- Legacy inspection without `binding.bundle` and additive absolute locator both
  remain admitted. Null, relative, NUL, boolean and oversized locators reject.
- A locator making the cache a child of the declared bundle root rejects before
  creating that evidence directory and admits no response.

New forgery inputs are retained under the final receipt root's `schema2-bindings/`
directory (`inspection-original.sexp`, `comparison-original.sexp` and the three
`*-rebound.sexp` records). All previous pre-correction records remain untouched.

### Reviewed corrected identities

| File | SHA256 |
| --- | --- |
| `backend/asic_workloads_service.ml` | `a487d0add6b89a8c1bf29b5dbff1bf06c40f8e04b6415eca18773c564fdb9984` |
| `backend/asic_workloads_service.mli` | `724e83364edb807ab883b9f80759592a5d59899843f8e508385de4a1d109da69` |
| `backend/asic_workloads_storage.ml` | `edf6dfc2bfe52b7c72427c26815bec9706757fc042ddd54caed99cfe892e9ebf` |
| `backend/asic_workloads_storage.mli` | `527c1af21d92dfe69cb6e86b227e3858964e56d62525047f71adaff55a2f8c7c` |
| `backend/asic_service.ml` | `3c5221752ba9d7ed3289f9cb9dffc0f49f6bbf56b9528cdbe61b99c80390e441` |

Unchanged original probe SHA256:
`d11aac4bb670bfe74b4eadaab9b76e2abfbcc4cb55323b5c0d7554961b1c5cbd`;
unchanged provider fixture SHA256:
`41a4038631408d39c8d711e306ba3e48ae8904034191e7eaf9cd42f9c8ff9ea3`.
The final receipt also binds the new wrapper sources and executable hash.

### Limits and remaining disposition

No new blocking finding was observed in this recheck. **R1/R2 are closed for the
demonstrated separation, descriptor-failure and internally inconsistent cache
rebinding cases.** The original configuration-freeze and failed-refresh diagnostic
durability observations remain nonblocking and unchanged in the original rerun.

Descriptor anchoring and these deterministic generation checks are not a cross-file
atomic snapshot/lease, an exhaustive ABA-history detector or execution authentication.
Stored historical alias mappings are checksummed cache data, not authenticated
history. A wholly fabricated, internally consistent replacement of all historical
bindings/documents is outside the consistency guarantees demonstrated here.
Restore intentionally does not claim that deleted or changed current sources are
validated. Linux `/proc/self/fd` is part of the reviewed storage implementation.

This recheck uses synthetic retained projections through actual backend code, not
the installed real ASIC producer or a fresh workload run. C's final real native
acceptance remains separate. No live daemon/root configuration, B implementation,
default build directory, example or Protemu changes were made for this review.
