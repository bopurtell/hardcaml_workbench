# Interactive synthetic flow demo

Implemented and exercised 2026-10-16 in the aesthetics worktree. This is a
development/demo provider behind the **normal daemon, adapter and terminal**.
It supplies explicitly synthetic data; it runs no synthesis, physical-design or
acceptance tools. No PDK or retained real-run directories are required.

**Testing is now included:** explicit seed creates Overview, Timing and Testing,
and runs two bounded synthetic FS2 examples (pass and intentional failure) through
the normal supervisor. Timing/Testing Session panels are wider. See
[Testing controls, upgrade instructions and both synthetic/real launch pairs](synthetic_testing.md).

## Launch in two terminals

The commands below use `$HOME/.local/state/hardcaml-workbench/synthetic-composition`
as a new persistent demo directory.
Choose a different name if it already exists; preparation deliberately refuses to
overwrite a prepared demo. The existing Workbench opam switch is required. Scripts
use `scripts/with-switch.sh`, respecting `OPAM_SWITCH` (default `5.2.0+ox`).

### Terminal 1 — prepare once and start the daemon

```sh
cd /home/wayne/devel/jane/silver
./scripts/with-switch.sh dune build -j 2 \
  daemon/main.exe terminal/main.exe terminal/workspaces/export_presets.exe

mkdir -p "$HOME/.local/state/hardcaml-workbench"

python3 -B scripts/synthetic-flow-demo.py prepare \
  --dir "$HOME/.local/state/hardcaml-workbench/synthetic-composition"

python3 -B scripts/synthetic-flow-demo.py daemon \
  --dir "$HOME/.local/state/hardcaml-workbench/synthetic-composition"
```

The daemon stays in the foreground. Its port is selected automatically and recorded
in the demo's discovery file; it has its own state directory.

### Terminal 2 — populate the daemon and connect

```sh
cd /home/wayne/devel/jane/silver

python3 -B scripts/synthetic-flow-demo.py seed \
  --dir "$HOME/.local/state/hardcaml-workbench/synthetic-composition"

python3 -B scripts/synthetic-flow-demo.py client \
  --dir "$HOME/.local/state/hardcaml-workbench/synthetic-composition"
```

Both commands discover this demo's exact daemon endpoint. Start with a terminal
at least **120 columns × 40 rows**. Overview, Timing and Testing already have useful tile
arrangements from the same `terminal/workspaces/` definitions used by ordinary
Workbench; no Apply default layout action is required. The exporter is required at
seed time. `--preset-export PATH` selects a matching non-default build.

For later sessions, repeat only `daemon` and `client`. `seed` reimports reference
evidence, selects the initial reference on a new demo, adds missing preset tiles
and explicitly discovers/submits the synthetic tests. Stable keys reuse retained
attempts on repetition. Existing selected or deliberately cleared contexts, extra
tiles, pins, hidden state and requested geometry are preserved; explicit **Reset
arrangement** restores preset requested sizes.

Prepared demos contain copied provider code and retained evidence. Create a fresh
directory to see updated production-like stage labels; old evidence is not silently
rewritten. Synthetic identity remains in runs/reports/provenance. See
[frontend composition](frontend_composition.md) for palette and presentation controls.

The latest [frontend refinement](frontend_refinement.md) adds border titles,
horizontal stages and compact Overview panels. Timing now uses a composed
investigation workspace rather than a full-window timing overlay.

The subsequent [sidebar/schemes pass](overview_sidebar.md) is now the current
Overview: Session, Runs and a wider vertical checklist at left; individual domain
summaries and planned-run stacked at right. Timing keeps its investigation topology.
Use a new directory name such as `synthetic-sidebar` to review clean defaults.
Palette **Color scheme: Carbon / Slate / Crimson / Neon** changes the live client.

`q` exits the client while the daemon stays alive. Ctrl-C stops the foreground
daemon. `--url` permits explicitly connecting to another endpoint; `--daemon` and
`--client` override binary paths. No setup command builds binaries automatically.

## What to try

### Testing workspace

Choose **3 Testing** and focus **simulation**. It contains `synthetic-checks` pass
and intentional-failure attempts with declared cases/seeds/parameters, logs, JSON
reports and synthetic binary traces. Use j/k to select attempts, n/p for cases,
`l` for logs, or palette **Simulation: Reopen … / Rerun case …**. Zoom for longer
details. These are project-scoped illustrative tests, not actual hardware evidence
or ASIC-run acceptance. See [full Testing guide](synthetic_testing.md).

### Run a simulated prefix from the checklist

1. In Overview, use **Tab / Shift-Tab** to focus **Stage checklist**.
2. Use **j/k** to select Placement (the order is synthesis, floorplan, placement,
   CTS, routing, signoff).
3. **Enter** inspects the selected stage, reason and advertised action; **Esc**
   returns. Use the palette's **Zoom focused tile** if you want more room.
4. Press **r** to prepare the advertised selection. This plans but does not execute.
5. When the matching preview is ready, press **Space c c**, search for
   **Launch and view in captured context**, and press Enter.

This starts a **new run from synthesis through placement**, not a restart of
placement inside the reference run. The normal allocation/context machinery
selects the new run. Stages advance at 1.5 seconds each by default; stages beyond
the selected endpoint are explicitly not requested. Selecting signoff instead
exercises the entire six-stage simulation (about nine seconds).

Overview's **planned-run** tile displays the pending/ready preview prepared by `r`,
including flow/profile/endpoint and assignments. Enter exposes full plan identity
and metadata. This is not yet a queued job; only explicit Launch starts execution.
Changing the selected historical run does not retarget that project-scoped plan.

The separate **Launch …** action runs without changing the selection.
Run selection, pinning, inspection, scrolling and appearance changes do not launch
work. Producer calls are recorded in `project/provider-calls.jsonl`.

### Inspect good and failed evidence

- The run selector contains **synthetic-reference** (six completed stages) and
  **synthetic-failed** (routing failed, signoff skipped). Select a row with j/k
  and Enter. The failure profile can also be launched through its advertised actions.
- **1 / 2** switch Overview and Timing; their run context remains linked.
- Use **Space c c → Inspect timing paths** to focus the Timing investigation
  workspace, then **j/k**, **Enter** for selected detail, **s** to sort, and **/**
  to filter. Tab changes between Paths, Selected path and Provenance; each detail
  pane scrolls independently. Esc closes the selected detail reader, not the
  workspace; use workspace navigation to return. An incompatible existing context
  or pin opens an independent captured-run arrangement rather than changing Main.
  Other palette inspection commands retain full-window clocks/physical/routing
  explorers through the same FS1 interfaces as a real provider.
- Synthesis contains 128 cells for the reference and 144 for the failed candidate.
  Reference setup/hold slack is 0.42/0.08 ns. The timing dataset has 12 paths across
  two corners and two groups, with setup/hold entries and varied values.
- Five clock rows distinguish declared constraints from synthetic measured facts;
  physical and routing indexes each have five rows. Text artifacts can be inspected
  using existing artifact commands. File hashes and source references are genuine
  hashes of these synthetic evidence files.

Freshly launched runs publish synthesis/checkpoint evidence. Their collection
receipts are retained under the run's `finalizations/` directory; adoption of
aggregate terminal results still uses the normal explicit finalization import.
The seeded reference/failed runs already have those aggregate results imported.

### Cancellation and manual advancement

The normal palette cancellation command stops the daemon-owned simulated launch.
Cancellation can stop its automatic observer as well; use the normal **Refresh**
action to reconcile the final provider-reported cancelled stages if the checklist
still shows the last running observation. Cancellation is not inferred from process
exit alone.

For deterministic stepping, prepare a separate directory with `prepare --manual`.
After launching, advance the exact allocated attempt explicitly:

```sh
/tmp/opencode/MANUAL-DEMO/project/synthetic-flow advance /ABSOLUTE/ALLOCATED/ATTEMPT
```

Each advance completes one stage and starts the next. `advance ... --cancel`
publishes cancellation. All launches, including manual mode, have a 120-second
bound. Ordinary reads never advance the simulation. `prepare --delay SECONDS`
sets timed playback between 0.01 and 2 seconds per stage.

## Implementation boundary

- Shared scenario definitions and provider implementation: `demo/synthetic_flow/`.
- Setup, seed and convenience launch: `scripts/synthetic-flow-demo.py`.
- Typed optional stage observations/actions: `Asic.Stage`, `Asic.Run.stages`.
- Stage parsing/persistence: `backend/asic_public.ml` and `backend/asic_service.ml`.
- Checklist projection/input: existing terminal host, with stable stage IDs and
  exact run/pin scope.
- Build/ownership plan: [synthetic flow implementation plan](synthetic_flow_plan.md).

The synthetic provider implements an optional versioned stage-plan extension.
Other providers that do not supply it continue to show unreported stage state;
this feature does not claim new real-provider stage-action support. Existing
Plan/Run operations are reused, rather than a demo-only execution path.

The original ASIC demo slice does not generate RTL hierarchy, binary layouts or
real simulator waveforms. The subsequent FS2 provider now supplies explicitly
synthetic cases, reports and binary traces. Some compact labels clip at 120×40; zoom and
inspection expose full context. Routing's aggregate tile still reports unavailable
detail where appropriate; its FS1 routing inspector has populated synthetic rows.
Provider acceptance remains `not_evaluated`; illustrative check passes are not EDA
acceptance evidence.

## Verification

```sh
./scripts/with-switch.sh dune build -j 2 @fmt
./scripts/with-switch.sh dune build -j 2 @lint
./scripts/with-switch.sh dune runtest -j 2
./scripts/with-switch.sh dune build -j 2

python3 -B scripts/test-synthetic-flow.py --smoke
python3 -B scripts/test-synthetic-flow.py --pty \
  --daemon _build/default/daemon/main.exe \
  --client _build/default/terminal/main.exe \
  --preset-export _build/default/terminal/workspaces/export_presets.exe
```

**Current composition integration:** updated same-definition seeding, production-like
stage labels and bounded palette passed synthetic HTTP/PTY at
`/tmp/opencode/synthetic-flow-huttcbvv/`; final format/lint/full tests/build passed at
`-j 2`. Broader frontend and FS2 regression evidence is in
[frontend composition](frontend_composition.md#verification-and-retained-evidence).

**Latest refinement:** styled panels, compact Overview and composed Timing passed
synthetic HTTP/PTY at `/tmp/opencode/synthetic-flow-y0hx51su/`. Refinement57,
two-run12, composition44, FS2 45 and five interrupt cases passed with final normal
format/lint/full tests/build at `-j 2`; see [current evidence](frontend_refinement.md#verification).

**Current sidebar/schemes/plan pass:** final normal binaries passed106 HTTP/PTY
checks at `/tmp/opencode/overview-sidebar-835bf5f34f02/`; synthetic launch/cancel
passed at `/tmp/opencode/synthetic-flow-d0emyda4/`. Full final normal-checkout
format/lint/tests/build passed serially at2. See [latest evidence](overview_sidebar.md#verification).

Historical first-slice evidence: formatting, lint, full tests and build passed; terminal tests were repeated after
checklist viewport/preview refinements. Final provider + real HTTP + PTY acceptance
passed at **`/tmp/opencode/synthetic-flow-8rmfu7xu/`**. This includes:

- Valid source hashes, read-only evidence, all four inspection domains and text artifacts.
- Automatic timed playback and deterministic manual stage transitions.
- Distinct runs, idempotent resubmission and exact captured-context launch selection.
- No producer calls from browsing, details, restyling or planning.
- Explicit cancelled-state observation after the cancellation lifecycle settles.
- Full Overview/Timing terminal captures, 12-path sort/filter and exact detail text.

Review `pty-full-overview`, `pty-full-timing`, `pty-path-index`, `pty-path-sorted`,
`pty-path-filtered`, and `pty-path-detail` in that directory (`.txt` and `.ansi`).
The harness stops only its own processes and retains its evidence. No actual EDA
execution, sibling repository changes or Git staging/commit/push were needed.
