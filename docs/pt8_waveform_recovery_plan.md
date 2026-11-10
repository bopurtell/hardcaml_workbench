# PT.8 simulation → Waveforms recovery

2026-11-05. Written before implementation. User opened a fresh PT.8 simulation's
result-reference JSON in Waveforms; no VCD was produced or published by that
provider. Preserve the failed view, completed runs and immutable provider/session
records. Do not restart the user's daemon or rewrite existing results.

**Accepted after independent corrections:** [final real execution/UI evidence](pt8_waveform_final_acceptance.md).
The original bounded plan follows. The launch guide now selects the new immutable
waveform-enabled source-complete session; historical captures remain unchanged.

## Bounded slices

- Frontend owner: inspect Testing's open-waveform/default artifact selection,
  Waveforms navigation, artifact admission and relevant tests. Select only exact
  available VCD artifacts bound to selected attempt/case. JSON references continue
  to use Workloads inspection. Missing VCD must have a truthful unavailable reason,
  not be treated as a waveform or silently retarget another case. Existing size,
  digest, stale reply and viewer parsing gates remain required.
- Example owner: add opt-in VCD generation to the reusable producer without
  changing historical default execution artifacts, dump only bounded top-level
  interface signals (not the full flop array/vendor hierarchy), retain actual
  simulator VCD and publish an FS2 case-bound waveform artifact alongside the
  unchanged result-reference schema. Use a new source-complete immutable session
  with private writes and pinned provider. No reconstruction of old waveforms.
- Coordinator: shared interface agreement, provenance review and independent
  acceptance. The FS2 VCD artifact should use kind `trace`, media type `text/vcd`
  (or the exact existing VCD contract after inspection), ID `CASE-waveform`.
  Preserve FS2 attempt prefixing, case attachment and byte digest identity.

## Acceptance

Real Flops and Exact positive workload simulations produce a nonempty supported
VCD with clock/enable/write/address/data/response transitions. Same 1307-cycle
logical workload and functional oracle/counters still pass; undefined outputs are
not initialized or sanitized. Interface dump remains <=8MiB and within viewer
signal/event limits. Production Testing → Open waveform loads real signals and
waves via the existing hash-bound artifact transport. JSON-only attempts show
no-VCD availability and remain inspectable as Workloads results. Cross-case,
wrong-attempt, missing/changed/oversize and mixed artifact tests are required.
Independent review after initial passing tests; retain failures and exact commands.

## Operating constraints

No EDA; functional Icarus execution allowed sequentially. All Dune explicit `-j2`,
switch5.2.0+ox, `_build_pt8_workbench`; shared Workbench lock
`/tmp/opencode/workbench-pt8-build.lock`, example lock
`/tmp/opencode/example-pt7-build.lock`, ASIC lock if needed
`/tmp/opencode/asic-pt7-build.lock`. At most two implementation agents with2 jobs
each; respect global20 including other sessions. Preserve existing frontend fixes,
example source modifications, untracked work, provider/config/history and live
daemon. No Git publication/authorship changes. No synthesis/physical run.
