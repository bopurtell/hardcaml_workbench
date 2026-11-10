# Hardcaml Workbench

A development workbench for inspecting, running, measuring, and debugging Hardcaml designs.

**Picking up in a new session?** Read the [cross-repository checkpoint](docs/session_checkpoint.md)
for PT.0–PT.8 status, paused acceptance and preservation constraints. Refactor
continuations are grouped under [migration guides](docs/migration_guides/README.md).

For tests **of Workbench itself**, start at [test/README.md](test/README.md) and
[the testing guide](docs/testing.md): subsystem-owned tests, explicit suite selectors,
and opt-in native/real-provider acceptance are distinct from hardware verification
launched inside the application's Testing workspace.

**Everyday example development:** use the [stable development session](docs/development_session.md)
for both FIFO assertion/regression suites and PT.8 memory workloads, normal ASIC
preparation, useful waveform Default/Fit, and retained history with explicit refresh.
This is the recommended entry point instead of successive feature-demo sessions.

**PT.8 Workloads (2026-11-05):** inspect verified workload results, capture explicit
A/B variants and launch a fresh example workload through Testing. The
[isolated session launch guide](docs/pt8_workloads.md) provides the server/client
commands and accepted retained→fresh-run walkthrough, preserving existing sessions.

**Current direction (2026-10-16):** configurable Bonsai Term tiles over typed
provider/module contracts, a command palette and named workspaces linked to a shared
Main run context by default. Workspaces can inspect independently; tiles can pin
references. Simulation/testing includes generic tests and structured suites/cases,
seeds, reruns and trace evidence over the existing supervisor. ASIC
flow ownership stays with the project and `hardcaml_asic`; development uses the
sibling FIFO specimen and headless tests.

**FS0 demos are implemented and exercised:** workspace/run-context persistence,
palette and generic test/log tiles, synthesis views, installed ASIC discovery/plan/
launch/observation, and L1/L2 summary reuse. Two real synthesis profiles produced
673 and 685 cells; those synthesis-only runs have acceptance `not_evaluated`. Existing Dune,
RTL/artifact and hierarchy workflows remain covered by installed tests.
**FS1 now adds** synthesis resource/check metrics and explicit finalization import
with aggregate timing, physical resources, check verdicts and declared-clock context.
Workbench can also launch collection/acceptance, observe and cancel its owned
finalization, and browse bounded report/artifact text with optional terminal-host
external text opening.
Real physical completion, external acceptance pass/fail inspection and owned-container
cancellation are exercised. FS1 now also delivers retained timing-path exploration,
measured clock reports, stage-specific physical/routing/congestion tables and exact
binary external handoff. These complete the adopted-evidence FS1 scope; embedded
graphical editing and appearance-gallery polish remain later work. See the
[current FS1 evidence and limits](docs/fs1_investigation.md) and [delivery record](docs/construction_phase_plan.md).
The owner has confirmed the Escape-responsiveness fix. Inspector presentation
polish and broader race/scaling coverage remain followups, not FS1 feature blockers.

**Substantial FS2 is delivered and accepted; milestone closed:** project-declared suites/cases, explicit seeds and
parameters, live progress/failure detail, targeted reruns, durable bounded history
and byte-exact trace export. Actual Hardcaml Cyclesim and native HTTP/terminal PTY
acceptance passed. Start with the [Cyclesim example](examples/fs2_cyclesim/README.md)
and [FS2 controls/acceptance](docs/fs2_acceptance.md). ASIC association is optional;
embedded waveforms and real gate-level adapters remain later integrations.

**Testing adoption extension:** the actual FIFO example now has a project-owned
FS2 provider with directed/seeded cases and genuine VCD/report artifacts. A catalog
and cooperative Attempts/Cases/Detail/Artifacts/Logs workspace expose the existing
backend coherently. [Open it and try the controls](docs/testing_workspace.md);
[implementation/evidence](docs/testing_cluster_plan.md). The original standalone
simulation tile and independent counter fixture remain supported.

## Documentation

- [Compose your own windows and workspaces](docs/workspace_configuration.md) — shared
  stock/user specification, editable examples, atomic apply and built-in recovery.

- [Execution durations](docs/execution_durations.md) — stage/run and simulation elapsed
  times in Overview and Testing, availability limits, and linked-context theme colors.
- [Lazy Timing details and cache configuration](docs/timing_cache_and_duration_alignment_plan.md)
  — selected-first loading, bounded neighbor warming, cache limits, and duration columns.
- [Reconnect and saved navigation](docs/client_reconnect_hydration_plan.md) — retained
  catalog reuse, immediate tab hydration, and restored attempt/artifact/Timing selections.

- [Restore a default workspace layout](docs/default_layout_restore.md) — one-step
  recovery from extra/hidden tiles or altered sizes, preserving runs and pins.

- [Documentation index](docs/README.md) — orientation and reading routes.
- [FS0 controls](docs/fs0_terminal.md) and [acceptance](docs/fs0_acceptance.md) — run the demo and inspect its evidence.
- [Synthesis inspection](docs/synthesis_inspection.md) — FS1 cell tables, sorting/filtering and evidence drilldown.
- [FS1 physical inspection](docs/fs1_acceptance.md) — metrics, timing/check/resource views, exact finalization import, real acceptance and limits.
- [Finalization and reports](docs/fs1_lifecycle_and_artifacts.md) — collect/accept palette commands, reconnect/cancel, paged artifact reading and configured external text viewing.
- [FS1 investigation completion](docs/fs1_investigation.md) — timing paths, measured clocks, physical/routing evidence, binary handoff, exact installed provider and adoption instructions.
- [FS2 simulation controls and acceptance](docs/fs2_acceptance.md) — suites, seeds, failures, reruns, history and trace export; real Cyclesim/native HTTP/PTY evidence.
- [FS2 provider/RPC contract](docs/fs2_simulation_contract.md) — configure a project-owned simulation provider and implement structured discovery/events.
- [FS3 adoption](docs/fs3_adoption.md) — initialize existing projects, import/export/clone layouts and retain presentation preferences.
- [Feature list](docs/feature_list.md) — concise scope/status and focused feature specs.
- [Feature sets](docs/feature_sets.md) — FS0 initial demos and later themed work groups.
- [Decision log](docs/decisions.md) — accepted run contexts; remaining command/snapshot policy.
- [Architecture](docs/hardcaml_workbench_architecture.md) — product, ownership, providers,
  runs/storage and workspace/window/tile boundaries.
- [Construction plan](docs/construction_phase_plan.md) — active demo phases M0–M5 and progress.
- [Rendering](docs/rendering.md) — styles, layout, interaction and headless UI testing.
- [Appearance handoffs](docs/design/README.md) — imported aesthetic sources and F12/FS5 interpretation.
- [Try the appearance presets](docs/appearance_presets.md) — A–E skins and independent color/icon/density controls.
- [Workspace composition and palette](docs/frontend_composition.md) — per-workspace OCaml definitions, floating fuzzy palette, configurable badges/chrome and typed status emphasis.
- [Refined Overview and Timing](docs/frontend_refinement.md) — border titles, compact summaries, horizontal stages, wide run labels and cooperative Timing investigation panes.
- [Current Overview sidebar and schemes](docs/overview_sidebar.md) — tightly packed vertical sidebar/right summaries, live Carbon/Slate/Crimson/Neon schemes and exact planned-run preview.
- [Real ASIC example demo and current polish](docs/real_asic_example_demo.md) — black default, value-only status colors, split checklist/planned-run sidebar and verified actual-example launch commands.
- [Launch/checklist consistency](docs/launch_stage_consistency.md) — exact submitted-run tracking beside preview readiness, real stage observations and read-only refresh after upgrade.
- [Checklist r → Plan → Launch](docs/checklist_launch_workflow.md) — real capability-backed stage shortcuts, cold-catalog discovery and visible launch-command availability.
- [Interactive synthetic flow](docs/synthetic_flow.md) — populated Overview/Timing, live checklist, simulated launches and FS1 inspection without EDA tools.
- [Synthetic Testing and both demo launch pairs](docs/synthetic_testing.md) — Overview/Timing/Testing defaults, synthetic FS2 pass/failure evidence, wider Session panels and actual-example hand-validation.
- [Formatting guide](docs/formatting_guide.md) — retained source conventions.
- [Backlog](docs/backlog/README.md) — explicitly deferred ideas and reactivation triggers.
- [Archive](docs/archive/README.md) — earlier designs, plans and completion evidence.

## Development

Build concurrency is one **shared pool of 20 jobs**, including nested builds and
provider helpers. One worker may use `-j20`; two may use `-j10` each; three must
divide the pool (for example 6/6/6 with 2 reserved). Parent verification may use all 20
only after other builds stop. Always pass an explicit job limit. This supersedes
the earlier conservative two-job guidance in historical acceptance records.

Use `scripts/with-switch.sh` for Workbench commands. It selects the existing
`5.2.0+ox` opam switch by default; `OPAM_SWITCH=my-switch` overrides it. The wrapper
does not create a switch or install dependencies. Inspect dependency requirements:

```sh
./scripts/with-switch.sh opam install . --deps-only --with-test --show-actions
```

Review the actions before installing; omit `--show-actions` to apply them. Formatting
and lint tooling also need `ocamlformat` and `ppx_js_style`. Generated opam metadata
comes from `dune-project`. The native package is separate from optional web tooling.

Build and launch the current client against an independent project:

```sh
./scripts/with-switch.sh dune build -j20 terminal/main.exe daemon/main.exe
HARDCAML_WORKBENCH_DAEMON="$PWD/_build/default/daemon/main.exe" \
  ./scripts/with-switch.sh dune exec -j20 hardcaml-workbench -- \
  --project-root /absolute/path/to/project --environment opam:PROJECT_SWITCH
```

From anywhere inside a project, `--discover-project` replaces `--project-root` and
opens the nearest ancestor containing a regular `dune-project` (the selected root is
reported; an explicit `--project-root` never searches upward). Simulation provider
configuration can be generated and checked (discovery only, no tests run) with
`hardcaml-workbench-simulation-setup init|check`; see
[WB-039](docs/features/project/WB-039-simulation-setup.md).

Use the project's actual switch. `--environment inherited` means the daemon's
startup environment, not necessarily the current client's shell. Add `--plain`
for noninteractive use. The current `b`/`t` controls submit build/test; `q` exits
the client while the daemon stays alive.

The palette (**Space c c**) also offers **Appearance: A - Instrument**, **B - Structured**,
**C - Minimal**, **D - Studio**, and **E - Structured studio**, plus separate color,
icon and density controls. These experimental client-local choices preserve run
contexts and pins; see the [preset guide](docs/appearance_presets.md).

Separate foreground startup is:

```sh
./scripts/with-switch.sh dune exec -j20 hardcaml-workbench-daemon -- --port 8080
# In another terminal:
./scripts/with-switch.sh dune exec -j20 hardcaml-workbench -- \
  --connect http://127.0.0.1:8080 --project-root /absolute/path/to/project \
  --environment opam:PROJECT_SWITCH
```

### Open the current real ASIC example demo

The **Resources inspector** is now available through **Space c c → Inspect
resources (open Resources workspace)**. It can explicitly import the retained SRAM
capture without running EDA. See [Resources controls, current provider and restart
commands](docs/resource_inspector.md); existing saved layouts are preserved.

Fresh checklist launches now execute **Elaboration → Synthesis → … → endpoint**
as one daemon-owned workflow, consuming the exact emitted bundle. Both app binaries
must be current. See [unified fresh-prefix controls and restart instructions](docs/unified_fresh_prefix_plan.md#delivery-and-user-verification)
for the PT.5 example provider configuration and validated default-binary pair;
the pinned demo launcher below keeps its own copied binaries until refreshed.

The actual example has a prepared persistent provider and isolated demo state.
From this checkout, Terminal1:

```sh
python3 -B scripts/real-asic-example-demo.py daemon
```

Terminal2:

```sh
python3 -B scripts/real-asic-example-demo.py seed
python3 -B scripts/real-asic-example-demo.py client
```

This adopts real retained named signoff evidence without EDA. See
[the current guide](docs/real_asic_example_demo.md) for exact provenance, limits and
`refresh-binaries` after future builds. It replaces the volatile historical setup below.

### Historical FS1 manual demo (superseded)

The commands in this section record the earlier temporary installation and evidence
paths, which may no longer exist after reboot. Use the persistent launcher above
for current testing rather than copying these old provider/result paths.

This local demo inspects the retained `hardcaml_asic_example` physical execution
and its accepted finalization; it does not rerun implementation or acceptance.
Use the existing matching client/daemon binaries and a terminal around 120×40.
The example's `hardcaml-workbench-asic.sexp` must select the inspection-capable
provider (the manual-demo config has been updated to this generation):

```sexp
(provider_executable /tmp/opencode/workbench-fs1-inspection-provider/generations/59466eda06df463e8d921678830ff5c2/bin/hardcaml-asic-flow)
```

Changing that setting requires reopening with a daemon that rereads the config.
ASIC registration/cache identity includes configuration, so re-register exact known
references after a provider-path change. Existing layout/pin records are separate.
The retained test harness's deadline-limited relay is not a permanent demo provider.

From this checkout, **Terminal 1**, create fresh state and start the daemon:

```sh
STATE=$(mktemp -d /tmp/opencode/workbench-manual-fs1-XXXXXX)
./scripts/with-switch.sh _build/default/daemon/main.exe \
  --port 41734 --state-dir "$STATE"
```

Keep the chosen state path to reopen this arrangement later. Use an unused port
and the same URL below; only one daemon may own a state directory. To reuse an
existing session, use its intended daemon/state lifecycle instead of starting a
second owner.

In **Terminal 2**, also from this checkout, register the retained evidence once
for this project/configuration namespace:

```sh
ROOT=/home/wayne/devel/jane/hardcaml_asic_example
URL=http://127.0.0.1:41734
wb() {
  ./scripts/with-switch.sh _build/default/terminal/main.exe \
    --connect "$URL" --project-root "$ROOT" --environment inherited \
    --api --plain "$@"
}

wb --asic-operation \
  '(Register ((attempt /tmp/opencode/workbench-fs1-physical-w0rftdi0/results/observations/20261015T192439611662Z_965b68b0) (stream_id 965b68b0f7454e14bc7d6f12f32ab9c7)))' \
  --wait --wait-timeout-seconds 120

# Exact Run_ref for this retained specimen, not a directory-derived new identity.
RUN='((backend asic) (id 965b68b0f7454e14bc7d6f12f32ab9c7) (build ()) (label ()))'
wb --asic-operation \
  "(Inspect_finalization (run $RUN) (attempt /tmp/opencode/workbench-fs1-acceptance-5oa67d8u/operations/20261015T203811140090Z_3bbfa7f1))" \
  --wait --wait-timeout-seconds 120

./scripts/with-switch.sh _build/default/terminal/main.exe \
  --connect "$URL" --project-root "$ROOT" --environment inherited
```

These API operations only read existing provider evidence and populate Workbench
state. The specimen shows **673 synthesis cells**, aggregate setup/hold around
**11.6755/0.125029 ns**, and terminal acceptance **pass**. Execution completion,
individual checks and that explicit acceptance operation remain separate facts.

In the client:

1. **Space c c → Apply default layout (add missing tiles)** supplies the dashboard
   while preserving existing tiles, pins and contexts.
2. Use **Tab** to focus the run selector and **Enter** to select the registered run.
3. Use the palette's **Inspect timing paths**, **Inspect clocks**, **Inspect physical**,
   **Inspect routing**, or **Browse reports/artifacts** commands.

Timing inspection now opens a composed **Timing investigation workspace** with
Paths, Selected path and Provenance panes; Tab changes panes and Enter requests
selected detail. Esc closes its detail reader; workspace navigation returns to
Overview. See [current Timing controls](docs/frontend_refinement.md).
Other rich inspectors remain full-window, client-local views attached to the
initiating tile. Enter opens a row detail; Esc returns to the table, then closes
the inspector. Switching to the already-active Overview does not dismiss a retained
non-timing inspector. `/` filters, `s` sorts and `c/g/p` cycle corner/group/producer.
See [all controls and evidence](docs/fs1_investigation.md#timing-paths-and-navigation).

**Finalize**, **Finalize and accept**, and flow-launch commands start work;
Inspect/Browse commands read existing evidence. `q` exits from the normal workspace;
Ctrl-C exits from every mode while daemon work continues. Domain refresh remains
polled, but local input redraw is immediate. If tmux delays Escape, the explicit
server-wide setting `tmux set-option -s escape-time 10` reduces its ambiguity wait;
see the [measured followup](docs/fs1_investigation.md#escape-responsiveness-in-tmux--2026-10-16-followup).

**Historical FS0 comparison:** the 673/685 two-run state at
`/tmp/opencode/workbench-fs0-91em64rl/real/state` is retained with its original
configuration identity. The upgraded example config does not automatically open
that registry. Its original commands/screens remain in [FS0 acceptance](docs/fs0_acceptance.md);
`test-fs0.py --reopen-real` mutates that selected state and is not the fresh-state
manual demo above. Preserve it and use private copies with matching configuration
for historical acceptance replay.

Run repository checks serially because they share Dune's build lock:

```sh
./scripts/with-switch.sh dune build -j20 @fmt
./scripts/with-switch.sh dune build -j20 @lint
./scripts/with-switch.sh dune runtest -j20
./scripts/with-switch.sh dune build -j20
```

Relevant integration checks, when changing those boundaries:

```sh
FIXTURE_OPAM_SWITCH=5.2.0+ox ./scripts/test-fixture.sh
./scripts/test-native-application.sh
./scripts/capture-terminal-baseline.sh --check
python3 -B scripts/test-fs0.py
```

The fixture uses an explicitly selected compatible switch. The installed-application
script tests an isolated install; legacy capture checks retain the original inspector
baselines, while `--capture-fs0 DIR` captures the new host with synthetic fixtures.
Historical toolchain investigations and detailed acceptance
records remain in the [archive](docs/archive/README.md). Record new phase evidence
in the construction plan rather than starting another general development diary.
