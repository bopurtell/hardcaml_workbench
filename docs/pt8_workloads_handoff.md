# PT8 B frozen Workbench protocol

2026-11-05. Authoritative declarations are `protocol/asic_workloads.ml`, module
`Hardcaml_workbench_protocol.Asic_workloads` (W below). Frozen before implementation.

```ocaml
module Target : sig
  type t = Bundle of string | Coarse_run of string | Execution of string
end
module Axis : sig
  type t = Hardware | Resource_policy | Flow_configuration | Descriptive
end
module Query : sig
  type t =
    | Inspect of { result : string; expected_digest : string option }
    | Compare of {
        left : Target.t; right : Target.t; axis : Axis.t;
        left_workload : string option; right_workload : string option;
        expected_left_digest : string option; expected_right_digest : string option;
        expected_left_workload_digest : string option;
        expected_right_workload_digest : string option;
      }
end
module Operation : sig
  type t = Load of { query : Query.t; refresh : bool }
  val key : t -> string
end
module Freshness : sig
  type t = Validated | Cached_unverified | Refresh_failed of string
end
module Descriptor : sig
  type t = {
    key : string; query : Query.t; digest : string option;
    provider_identity : string option; freshness : Freshness.t;
    error : string option;
  }
end
module Response : sig
  type t = { key : string; digest : string; json : string }
end
module Snapshot : sig
  type t = {
    entries : Descriptor.t list; selected : Response.t option;
    cache_error : string option;
  }
  val empty : t
end
```

All types derive `bin_io, compare, equal, sexp`. Integration:
`Asic.Operation.Workloads of W.Operation.t`, and
`Asic.Snapshot.workloads : W.Snapshot.t option` with sexp default None/drop None.
Existing `/api/v1/asic` and client method are reused. Poll `Asic.Operation.Get`;
pending key is `W.Operation.key operation`. Key includes the complete ordered query
including expected digests, **excludes refresh**. No new terminal/build ownership.

Paths are explicit absolute paths, <=4096 bytes, no NUL. Digests are lowercase
SHA256. Expected target digests refer to public comparison `left.source_digest` /
`right.source_digest`; workload digests refer to each side's `workload.source_digest`.
Inspect expected digest refers to inspection `source_digest`. Missing expectations
mean explicitly capture current evidence; supplied expectations reject changed
evidence, never silently adopt it. A workload expectation requires its workload path.

`Response.json` is the bounded public JSON document (not a new metric policy).
Inspection envelope: `hardcaml-asic.workload-inspection` version1, digest
`source_digest`. Comparison: `hardcaml-asic.variant-comparison` version1, digest
`comparison_digest`. Preserve JSON integer/intlit and numerator/denominator values;
frontend must not route them through float. Provider comparability/deltas/outcomes
remain authoritative. B validates admission, envelopes, structure and capture fences.

Get and rendering never invoke providers. Load schedules/coalesces bounded reads;
refresh=false may reopen cache; refresh=true reads public provider. At most eight
cached responses / 8MiB raw JSON and one full selected response in snapshot. Persisted
entries restart Cached_unverified. Failures retain prior payload/digest and publish
Refresh_failed/error. Check descriptor freshness even when selected is present.
Changing selection while reads overlap cannot let an older completion steal selection.

An attached comparison side's `source_digest` is the provider's combined
target+workload generation, not the standalone workload inspection digest. A pair
captured from two inspections should set `expected_left_workload_digest` and
`expected_right_workload_digest`; leave target expectations absent until a comparison
has captured them. Reopening a comparison can pin all four returned digests.
Root aliases and returned target/provenance paths are also fenced on provider reads.

C seam: `hardcaml-asic-flow workload-inspect RESULT --json`, capability
`workload_inspection1` (read-only schema1 object or true); comparison requires
`variant_comparison1`, and workload attachments additionally `workload_comparison1`.
Exit0 means readable, including semantic failure; invalid evidence exits2.
Launcher plus actual installed/development companion hashes are fenced pre/post.

FS2 result link stays the plan's `hardcaml-workbench.pt8-result-reference` version1
JSON artifact with `result` absolute retained path and `source_digest`. A reads it
using existing simulation artifact RPC, then submits Inspect with expected_digest.
No generic artifact/source browser is introduced. C retains relative-file closure
outside FS2 work directory. Root provider configurations remain unchanged.

## B implementation and verification

Implemented in `backend/asic_workloads_service.{ml,mli}`, the ASIC adapter, and
`backend/asic_service.ml`. The existing scheduler/query throttle/process lifecycle
owns reads; general `Asic_process` limits/policy were not changed. Each workload
response drains with explicit 1MiB total and record limits. Provider identity hashes
the resolved launcher and the exact inspect/compare companion, before/after the
read. Explicit target aliases and returned target/provenance bindings are fenced.
Cache restore runs off the Async thread, validates an identity-scoped checksum and
each response, and marks descriptors cached-unverified. Persistence uses atomic
replacement outside selected evidence roots. Failed reads preserve earlier data.

Final focused suite: **63 checks**, plus protocol inline tests. Additional optional
admission of the installed PT8 `acceptance-final-01/flops/stdout.log` inspection and
`acceptance-final-01/matched-cli/stdout.log` comparison passes (**65 checks total**).
This checks compatibility with retained public response bytes; it does not rerun a
source reader or simulator, and does not replace C/coordinator real RPC acceptance.

Commands run from Workbench root (every Dune command uses this lock/switch/build
directory/job limit):

```sh
flock /tmp/opencode/workbench-pt8-build.lock opam exec --switch=5.2.0+ox -- \
  dune build -j6 --build-dir _build_pt8_workbench backend/hardcaml_workbench_backend.cma
flock /tmp/opencode/workbench-pt8-build.lock opam exec --switch=5.2.0+ox -- \
  dune runtest -j6 --build-dir _build_pt8_workbench \
  backend/test adapters/test protocol/test daemon/test
flock /tmp/opencode/workbench-pt8-build.lock opam exec --switch=5.2.0+ox -- \
  dune runtest -j6 --build-dir _build_pt8_workbench backend/test/workloads protocol/test
```

The broad backend/adapter/protocol/daemon regression run passed, including existing
Resources, FS2 simulation, timing analysis, generic supervisor cancellation and fresh
synthesis/CTS fixtures. Those fresh fixtures use fake providers; EDA allocation0.
Initial compile errors (missing adapter interface declaration and an integer-local-open
type mismatch), then a test harness Deferred bind error, were fixed before passing.

Optional retained-payload compatibility invocation, from
`_build_pt8_workbench/default/backend/test/workloads`:

```sh
PT8_WORKLOAD_INSPECTION_JSON=/home/wayne/devel/jane/hardcaml_asic_example/acceptance/pt8-workloads/acceptance-final-01/flops/stdout.log \
PT8_WORKLOAD_COMPARISON_JSON=/home/wayne/devel/jane/hardcaml_asic_example/acceptance/pt8-workloads/acceptance-final-01/matched-cli/stdout.log \
./test_workloads.exe
```

B did not edit terminal/workspace builtin files, ASIC/example files, root provider
configuration, live daemons or queue/review documents. Concurrent A/coordinator
changes visible in the working tree are independent work and remain preserved.

### Backend review correction handoff

R1/R2 corrections are recorded in `pt8_workloads_backend_corrections.md`.
Publication is now anchored/descriptor-bound, rechecks separation at write time,
and commits in-memory data only after async persistence. Internal cache format2
retains query-to-historical-canonical bindings and checks them on cache-only restore
without source IO. Format1 derived caches require explicit rebuilding; public legacy
responses remain accepted. Optional additive `binding.bundle` is admitted only as
a bounded absolute non-NUL path. Frozen OCaml protocol types remain unchanged.
