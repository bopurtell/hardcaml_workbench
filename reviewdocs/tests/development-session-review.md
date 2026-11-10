# Independent C review after initial A/B suites

**Final disposition: no remaining C blocker or definite issue.** Regular config
publication and both waveform findings are independently corrected and retested.
Complete native09, strict audit09, corrected adversarial review86/86, and actual
history refresh controls pass. See `development-session-final-c.md` for final
receipts/app hashes and B's final capture handoff. Original review chronology below
is preserved; its open labels describe the earlier reviewed snapshots.

2026-11-05. C has made verification-only Workbench scripts/review notes. No A/B
production changes, owner live sessions, root configs, old providers/evidence or
Git state were mutated. Functional simulation/EDA were not launched in C's initial
direct controls; later native functional runs will be recorded separately.

## Blocking integrated finding: FS2 config symlink

**Resolved by B's regular publication; native Discover independently retested.**
The original B prepared project installed
`hardcaml-workbench-simulation.sexp -> <store>/selected/config/...`. Real production
daemon `backend/simulation_service.ml:342` reads that path with
`Simulation_files.read`, which explicitly rejects every symlink component at
`backend/simulation_files.ml:93`. Actual production HTTP Discover returns
`Invalid_request (Failure "Symlink in simulation artifact path")` before provider
launch. Workbench client launches but cannot expose either suite through Testing.

Reproduced three times with the real B daemon/client launcher in C's independent
private store; receipts `/tmp/opencode/development-c-native-{01,02,03}`. This is not
a direct-provider failure: `/tmp/opencode/development-c-provider-01/receipt.json`
passes real catalog parity and adversarial/exec routing controls. Preserve the
artifact reader's no-symlink protection; the responsible production owner needs to
resolve the config integration contract. C has not applied a test-only config
workaround that would hide this launch failure.

## Subsequent blocking integrated finding: native FIFO VCD MIME admission

**Open.** After B's regular-publication fix, C prepared private store02 and actual
native two-suite discovery plus FIFO directed/seeded normal and mismatch all pass.
The real OCaml FIFO child emits `text/x-vcd`, but production
`terminal/simulation_export.ml:vcd_media` only admits `text/vcd`, `application/vcd`,
`application/x-vcd`. Actual selected-case `Simulation: Open embedded waveform
seeded.vcd` is absent (`No matching commands`). Retained native05 demonstrates
the real action failure, without modifying provider output or private configs.
Responsible production owner must reconcile those valid VCD media types. C has
made no production fix.

Native06/07 used an explicitly labelled diagnostic continuation after that failed
FIFO waveform action; they never claim full native acceptance. Actual same-session
PT8 flops256/exact256 UI launches, exact VCD/JSON transport, actual selected-case
Workloads handoff, seven comparable zero deltas, PT8 80ns default, Fit13.07us and
exact2595000=13C6/2595001 pass. Daemon restart preserves actual attempt history,
exact captured attempt/artifact metadata/bytes and shared workspace.

Native06/07 later stop on C's overly strict byte-equal client preference oracle:
before/after snapshots in native07 show only same-case artifact hydration added
to an originally unset Testing artifact selection. Actual explicit attempt/case,
focus, selected Workloads result and A/B pair remain identical. C corrected its
oracle to verify the enriched artifact against the exact native attempt/case/
digest/size instead of forbidding legitimate hydration. No production failure is
claimed from that oracle. Actual Stacked waveform display preference was selected
through the production palette and saved.

Read-only independent raw closure audit **passes**, scoped to completed executions:
`/tmp/opencode/development-c-native-audit-07/receipt.json`. Each PT8 result's ledger
matches its actual FS2 attempt/case/seed; all retained result/simulation/stimulus/
trace/model references match bytes and hashes;1307 raw trace rows independently
check against the memory oracle,525 reads/262 writes/2083 defined observations;
seven zero deltas; FIFO real normal/mismatch VCD equality and injected reports.
Audit explicitly records `native_acceptance_passed=false` and the native blocker.

## Earlier integrated finding: private source lacks Git context

**Resolved by B's captured read-only context, independently retested.** Early
`native-02` standard Plan failed at `git rev-parse HEAD`. After explicit preparation
refresh using B's updated environment, `native-03` proves actual source-only
standard/balanced/synthesis Plan, StageFreshAvailable intent, Available preparation,
and real source build + emission through the captured two-job Dune shim. Workflow
Completed; build/emission jobs Complete; emitted bundle remains private; no physical
run/reference. Files `source-only-plan.json`, `elaboration-only-workflow.json`,
`build_job-logs.json`, `emission_job-logs.json` retain exact identities/logs.

## General-development source closure

**Review question open.** Current explicit `SOURCE_DIRS` omits existing `test/`,
`asic_test/`, `timing/`, `named_timing/`, and `physical_timing/`. The captured main
source build/emission succeeds, but the editable project is not the complete set of
existing example development/test directories. B/coordinator should reconcile this
with the source-complete general-development promise. No root source was recopied
or altered by C.

## Independent passing controls

- `/tmp/opencode/development-c-prepare-01/receipt.json`: initial capture, matching
  freshly built daemon/client hashes, fixed private project root.
- `/tmp/opencode/development-c-provider-01/receipt.json`: 21 checks: exact actual
  child catalogs; failed/invalid/oversize/duplicate discovery has no partial output;
  both routes preserve PID/PGID/exit/argv/request bytes; real providers reject
  invalid suite/cases/seeds without evidence. No simulations/builds.
- `/tmp/opencode/development-c-refresh-01/receipt.json`: 18 checks: repeat without
  reset; editable source drift retained; stale simulation rejects before events;
  failed source-build refresh keeps selection; successful refresh captures edited
  private source; state/artifacts/preferences retained byte-exact; old generation
  retained; state lifetime lock blocks refresh. At this point state contained a
  genuine shared workspace and client preferences, **not yet FS2 attempt history**.
- `/tmp/opencode/development-c-waveform-01/receipt.json`: independent prebuilt native
  probe controls after A's initial passing suites: even subcell pulse has dense
  original-event marker; alias equality; hidden X/Z excursions and separate exact
  X/Z; inclusive Fit survives narrow rendering; exact samples above2^53 through
  Int64.max_value; every max-int64 tick covered by gap-free cells; one-point value;
  explicit 100000-event budget exhaustion. Synthetic controls, zero simulations.

## Remaining integrated gates

No full native pass claimed while the config finding is open. C's retained harness
will run actual same-session Testing FIFO directed/seeded normal and mismatch,
PT8 both positives, VCD/JSON closure and Workloads handoff/seven zero deltas,
production Default/Fit13.07us/exact2595000=13C6, preserved FIFO navigation and durable
history/artifact/preferences restart after production correction and final app
capture. Per-suite FS2 cancellation/reaping remains untested by C; B's separate
direct cancellation receipt is not relabelled as C native verification.
