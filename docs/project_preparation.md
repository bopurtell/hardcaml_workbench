# Project preparation — build and EDA-less bundle emission

WB-004 is implemented, automatically verified and **owner-accepted/closed** on 2026-10-26.
Preparation builds the declared source executable, invokes selected-flow bundle
emission, and stops before synthesis or physical execution.

## Controls

Open the palette with **Space c c**.

1. In an existing saved workspace, choose **Add preparation tile**, or explicitly
   restore the default Overview layout. Fresh stock Overview includes the tile.
2. Choose **Preparation inputs: FLOW / PROFILE** and enter the endpoint and optional
   parameter overrides using the existing selection form. This selects inputs only.
   Existing remembered Plan inputs can also supply the selection.
3. Press **r** on the preparation tile or the checklist's **Elaboration** row to
   stage an input plan for manual launch. This performs no build or emission.
   Review it in Planned run, then choose **Launch planned PREPARATION** from the
   palette. Alternatively, **R** stages and launches immediately.

The endpoint is part of the bundle's selected methodology; selecting `synthesis`
as the endpoint does **not** execute synthesis during preparation.

The planned-run tile uses the same compact status/endpoint/launch/selection structure
as physical run previews:

```text
▸ ready: elaboration input plan / launch: not requested
endpoint: elaboration
launch: build and emit (EDA-less)
flow: standard / profile: balanced
assignments: (none)
```

Enter expands the exact stage receipt, provider endpoint, source/build/results paths,
environment and staging limitations. Stale, consumed and unavailable plans keep
compact disabled headlines; their exact reasons remain in details. Detail wrapping
and scroll bounds share icon-aware widths so the final metadata rows remain reachable.

| Control on preparation tile | Action |
| --- | --- |
| `r` | Stage preparation inputs for review/manual launch; no processes |
| `R` | Stage, then immediately build current source and emit selected bundle |
| Enter | Inspect scope, outcomes and existing job logs |
| `j` / `k` | Browse retained session attempts |
| `[` / `]` | Scroll inspection details/logs |
| `x` | Cancel active preparation |
| `a` | Inspect the selected attempt's bundle artifact |
| Esc | Leave inspection/artifact view |

Palette artifact entries expose individual imported files. **Build project** and
**Run project tests** remain separate commands. Merely viewing a row, log or artifact
does not submit work.

### Uniform checklist launch controls

For physical stages, **r** retains the existing plan-for-manual-launch behavior.
**R** obtains the exact selected stage's plan, waits for that plan to be ready, and
launches it once. Failed planning or changed captured context/selection prevents
automatic launch; an unrelated retained preview is never substituted.

Palette options persist per project:

- **Quick-launch behavior: view launched run** (default).
- **Quick-launch behavior: keep current context**.

### Palette launch queries

The palette prioritizes action names over behavior settings:

| Query prefix | Default action |
| --- | --- |
| `launch and vi` | Launch and view the already planned run (or staged preparation) |
| `quick lau` | Quick launch selected stage |
| `launch syn` | Launch synthesis and view |
| `launch elab` | Launch elaboration bundle (build and emit; context retained) |

**Quick launch selected stage** uses the focused checklist, or the active workspace's
unambiguous checklist selection from another tile. It uses the saved quick-launch
view preference. Explicit named physical actions always request viewing the newly
allocated run without changing that preference. Named stage commands still require
declared capability; unsupported actions explain why they are unavailable.

Editing the search query selects the new highest-ranked match. Explicit arrow/Tab
navigation is retained until the query changes again. Prefix matching and aliases
remain compatible with fuzzy search and Unicode highlighting.

Selected-stage actions capture the stage/run and revalidate selection, inputs and
capability throughout asynchronous planning. Changing the checklist cursor or
withdrawing the selected stage's capability before launch prevents execution.

Elaboration follows the same r/R split, through typed backend `Stage` and
`Launch_staged` operations. Its staged receipt captures selection/build/configuration,
not a generated provider plan or frozen source bytes. Superseded receipts and changed
configuration are rejected at launch. Preparation does not allocate an ASIC run,
so either view option leaves the ASIC context unchanged for this operation.

The Elaboration checklist duration uses the same aligned time column as physical
stages. It measures total preparation including build and emission, advances while
active, and freezes when terminal timestamps are available; otherwise it is unknown.

Preparation is already part of stock Overview, above Synthesis. For older saved
geometry, use **Restore default layout: Overview (hide extras)**. Restore preserves
tile IDs, pins and contexts while restoring default visibility/geometry; extra tiles
are hidden rather than deleted.

## What the statuses mean

- **Build:** the captured preparation build job's process result. If no preparation
  attempt exists, the tile can show the generic project build command result.
- **Elaboration-bundle emission:** a separately supervised `flow emit` operation;
  completion requires a validated receipt, selected plan, manifest and file digests,
  followed by successful artifact import. A successful build is insufficient.
- **Verification (project test command):** the configured test command's process
  outcome. It is not a structured all-cases-passed or ASIC acceptance verdict.
- **Generic RTL (not ASIC bundle):** an observed generation job matching the current
  project/target/configuration can be inspected separately. Its success does not
  establish an ASIC publication. No capability is inferred from target names alone.

Unavailable capability is distinct from supported but not requested/no session
history. New failed/cancelled attempts remain the headline; earlier attempts are
inspectable. Build success remains visible if the subsequent emission fails.

Preparation is current-project evidence, independent of a selected historical ASIC
run. The UI only reports an exact plan association when supplied identities match.
No preparation result completes a physical checklist stage.

## Project configuration

Opt in with `hardcaml-workbench-preparation.sexp` at the source root:

```scheme
((schema_version 1)
 (build_target bin/project.exe)
 (results_root /absolute/path/to/preparation-results)
 (timeout_seconds 600))
```

Workbench runs `dune build -j6` for that target using the selected project
environment, then executes `SOURCE/_build/default/bin/project.exe` directly.
It does not substitute the ASIC companion's pinned executable. Configuration is
revalidated before queued build/emission execution; changed configuration cannot
silently launch the old captured operation.

The executable must implement the versioned `project flow emit` contract. The FIFO
example now does, reusing existing `hardcaml_asic` methodology preparation and
bundle publication. No core `hardcaml_asic` changes were required.

The receipt contains `schema_version = 1`, `kind = "bundle_emission"`, bundle and
plan identities, absolute output directory, verified-reuse boolean and the full
selected methodology plan. The manifest and its files are imported as exact job
artifacts. Supported native store publication includes identity directories and
the provider's private-object publication links.

## Run the prepared real FIFO demo

The example's opt-in config publishes under
`hardcaml_asic_example/.dev/workbench-real-demo/preparation-results`, separately
from existing physical execution evidence.

After existing work finishes, close the old client and stop the old daemon normally.
The daemon shell needs the example's installed ASIC SDK to compile current sources:

```bash
cd /home/wayne/devel/jane/silver
source /home/wayne/devel/jane/hardcaml_asic_example/.dev/asic-prepare/current/activate.sh
export OCAMLPATH="${OCAMLPATH}:/home/wayne/devel/jane/hardcaml_asic_example/.dev/workbench-provider-sdk/lib"
python3 -B scripts/real-asic-example-demo.py daemon
```

In a second terminal:

```bash
cd /home/wayne/devel/jane/silver
python3 -B scripts/real-asic-example-demo.py client
```

No reseeding is needed. Demo daemon/client/exporter copies were refreshed after
verification; live processes were not restarted. Refresh receipt:
`hardcaml_asic_example/.dev/workbench-real-demo/receipts/refresh-binaries-a02a24b1cd824c2aab423106244186a9/`.
The SDK environment was also checked with the demo's `opam:5.2.0+ox` build path.

## Verification and limits

- Combined `scripts/with-switch.sh dune build -j8 @all @runtest @lint` passed.
- Changed OCaml files pass formatting checks. Global `@fmt` still reports existing
  drift in unrelated hierarchy/indicator/hydration/waveform/workspace files; only
  WB-004 changes were formatted.
- Native HTTP/PTY regression passed against normal rebuilt binaries:
  `/tmp/opencode/wb004-palette-final-preparation/result.json`. Covers scoped generic RTL,
  zero-work staging, manual launch, quick launch, unavailable state, logs/artifacts,
  failure history, reconnect, cancellation and live/frozen duration rendering.
- Full checklist HTTP/PTY workflow passed at
  `/tmp/opencode/wb004-palette-final-checklist/`, including physical R once-only
  launch, context-follow on/off and preference restart, planning failure and
  changed-selection fences. Includes incremental palette queries, named launch-and-view
  despite keep-context preference, and pending-plan cursor/action/capability withdrawal.
  Physical execution in these checks is synthetic.
- Real FIFO HTTP acceptance passed:
  `/tmp/opencode/wb004-real-example-acceptance-review/report.json`.
  Selected `standard / synth_delay / synthesis`, with
  `SYNTH_ABC_BUFFERING=true` and `SYNTH_STRATEGY=AREA 0`.
  Both build and emission completed, 25 artifacts per successful attempt were read
  and digest-checked, reuse passed, and expected-identity mismatch failed without
  publication changes. Descendant execution tracing recorded zero provider/EDA
  executions; retained physical evidence stayed unchanged.
- Provider CLI tests cover selection, overrides, deterministic publication/reuse,
  identity mismatch and EDA-less operation. Backend regressions cover cancellation,
  config drift, malformed/tampered receipts, nonzero/timeout outcomes and deduplication.

Attempts, generic jobs, logs and imported artifact handles are **daemon-session
scoped**. Published bundles remain in their results store, but restart/external
receipt discovery is [deferred](backlog/README.md#preparation-history-and-external-emission-adoption).
Resource-preparation composition and exact-bundle verification remain separate work.
Owner visual/workflow acceptance covers the initial preparation feature and the
subsequent staging, quick-launch palette and compact planned-run refinements.
