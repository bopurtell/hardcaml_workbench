# PT8 backend corrections — B

2026-11-05. Corrects R1/R2 from A's independent
`pt8_workloads_backend_review.md`. The independent document and
`review_pt8_workloads_backend/` probes remain unchanged for A's rerun.

## R1: anchored, descriptor-bound publication

New `backend/asic_workloads_storage.{ml,mli}` anchors the requested state directory's
canonical location (and existing directory device/inode) when the workload cache
is created. A changed state alias or directory generation rejects publication.
On Linux, it walks from `/` through directory descriptors, rejects symlink
components, and checks lstat/fstat directory identity during admission. File
creation, replacement and cleanup use `/proc/self/fd/<directory-fd>/...`, not a
mutable state-directory spelling. Temporary files use O_CREAT/O_EXCL and writes use
the admitted file descriptor. No general `Asic_process` behavior changed.

Separation is checked before directory creation, before file creation and before
atomic replacement, against both the historical admitted roots and current
selected roots. The optional public bundle locator is also an evidence root when
present. Cache directory aliases/generation and the descriptor's canonical location
are rechecked. Retargeting a state alias to retained evidence cannot direct a
temporary write/rename there. This is descriptor-bound storage and directory
generation fencing, not a cross-file atomic snapshot or execution authentication
claim.

Publication no longer replaces the in-memory response before asynchronous storage
finishes. Failed persistence leaves the old payload/digest; the service publishes
Refresh_failed. Cancellation is checked before starting storage and again after
the async result, before marking the response Validated. Selection remains owned
by the latest request rather than whichever background read completes last.

## R2: restore repeats query/document binding without source IO

Persisted cache format2 stores ordered `(original query path, admitted canonical
path)` bindings alongside each response. Live publication validates those bindings
against the full query, then applies the same `check_targets` used for provider
reads. Restore repeats envelope/digest/key/checksum validation **and** the query /
historical binding / document checks, plus cache/evidence separation.

Restore does not canonicalize current source paths or run tools. A deleted source
or removed/retargeted source-root alias can still reopen its exact historical
cached response as Cached_unverified. Changing a cached query/keys and recomputing
its checksum cannot rebind the unchanged raw document to a different result,
comparison target or nested workload.

The old derived format1 lacked these historical alias bindings and is rejected
with a cache diagnostic; explicit Load/Refresh rebuilds format2. Public legacy
inspection responses remain accepted. No protocol/workspace migration or root
provider configuration change is involved.

## Additive C public locator

`validate_response` now accepts and validates `binding.bundle` when present: it
must be a non-NUL absolute path within the existing4096-byte path budget. Missing
locator remains valid for legacy inspection and nested workload projections;
explicit null/wrong-type/relative/oversized locators reject. Raw JSON and exact
numbers remain unchanged. ASIC remains authoritative for bundle identity/binding.

## Owned regressions

`backend/test/workloads/test_storage.ml` adds30 checks:

- deterministic state-alias retarget during a held real supervisor/provider read;
  no cache file appears in evidence, the original persisted cache is unchanged,
  and old data remains selected with failure freshness;
- alias retarget after directory-descriptor admission and immediately before
  replacement; canonical-ancestor rename/symlink substitution; zero evidence files
  and no leftover temporary files;
- coherently rewritten query/response keys/bindings/checksum for Inspect, comparison
  target and nested workload reject on restore;
- source missing and historical root alias removed still restore cache-only,
  Cached_unverified;
- direct publication binding and publication/restore separation reject;
- additive bundle locator and legacy-response admission controls.

The original B workload suite still passes63 checks. The pure cache fixtures were
updated to supply real query/provenance bindings rather than relying on the old
direct-publish admission gap. A's original probes/tests were not altered.

Commands use the isolated build and shared lock:

```sh
flock /tmp/opencode/workbench-pt8-build.lock opam exec --switch=5.2.0+ox -- \
  dune build -j6 --build-dir _build_pt8_workbench backend/hardcaml_workbench_backend.cma
flock /tmp/opencode/workbench-pt8-build.lock opam exec --switch=5.2.0+ox -- \
  dune runtest -j6 --build-dir _build_pt8_workbench \
  backend/test/workloads protocol/test adapters/test daemon/test
```

The passing owned run was followed by an explicit request for A to independently
rerun the unchanged probes. Expected corrected observations: R1 has no
evidence-root cache file and does not claim Validated; R2 has no selected restored
document and a cache diagnostic. Independent rerun is a separate gate, not claimed
by these owned tests. Root configs, live daemons, ASIC/example work and A's terminal
corrections remain untouched.
