# Three-workspace synthetic demo and roomier Session panels

**Current Testing extension, 2026-10-17:** the shared preset now composes Catalog,
Attempts, Cases, Detail, Artifacts and Logs with a compact generic-test/Session/
execution column. It supersedes the original single-panel proportions below.
The same synthetic cases exercise these panes; standalone `simulation` remains
supported as an independent legacy tile. The actual ASIC example now separately
has a genuine FIFO provider. See [current controls and real evidence](testing_workspace.md).

Implemented and verified 2026-10-17. The synthetic demo now supplies **Overview,
Timing and Testing** by default, including useful explicitly synthetic FS2 results.
Timing and Testing layouts have wider Session/sidebar regions. The actual ASIC
example remains a separate hand-validation path; commands for both are below.

## Synthetic Testing data

`prepare` copies a self-contained standard-library Python simulation provider and
wire codec into the demo project and writes its FS2 companion configuration. The
provider uses the normal versioned FS2 discovery/event/artifact contract and existing
supervisor; it does not run hardware simulation, Dune test targets or EDA.

Explicit `seed` discovers `synthetic-checks` and submits two representative attempts:

| Attempt | Cases | Seed / parameters | Outcome |
| --- | --- | --- | --- |
| Representative pass | reset-sequence, seeded-pattern |42; walking pattern;8 steps |Passed, process exit0 |
| Representative failure | seeded-pattern, injected-mismatch |314159; alternating pattern;16 steps |Failed, process exit0 |

Cases emit live progress, labeled stdout/stderr, JSON reports and byte-preserving
synthetic binary trace artifacts. Reports and traces explicitly state that they are
not hardware evidence. The failed case is intentional, so it is not a broken setup.

The Testing workspace's simulation tile exposes cases, seeds, parameters, failures,
logs, artifact export and targeted reruns. Execution/log views consume the same
supervised jobs. The separate generic project-tests tile can still have no Dune test
attempts; structured results are not fabricated as generic Dune tests. None of these
project-scoped test attempts acquires the currently selected ASIC run as provenance.

### Controls

1. Select **3 Testing**, or palette **Switch to Testing**.
2. Tab to focus **simulation**.
3. Use j/k for attempts, n/p for cases, `l` for logs, and brackets to scroll.
4. Palette **Simulation: Reopen …**, **Select case …**, **Rerun case …** and artifact
   actions are available. Rerun creates a new linked job with the retained inputs.
5. Zoom the simulation tile when viewing longer reports/logs at120×40.

Seeding uses stable submission keys and retains exact request payloads/receipts in
`simulation-seed.json`. Re-seeding does not create duplicate attempts while those
reservations are retained. Ordinary viewing, navigation, scheme changes and client
restart do not launch tests. Explicit reseeding can run discovery again; it does not
pretend discovery is process-free. Both seed helpers now print progress notices.

## Layout changes

- **Timing:** Session:selector top-band width is1:2; at120 columns the Session tile
  is40 columns wide. Paths-left / Detail-over-Provenance remains unchanged.
- **Testing:** sidebar:main width is1:2. Session and generic project-tests have a
  wider sidebar, while FS2 receives most spare main-panel height. At120×40, the
  tested simulation panel is80×15; at180×55 it is120×24.
- Overview is unchanged by this pass. Narrow terminals retain grid/focused fallback,
  and custom/duplicate tiles, pins, hidden state and requested geometry remain intact.

Source settings are in `terminal/workspaces/timing.ml` and `testing.ml`; named
weights and height constants make these proportions adjustable. The demo consumes
the same exported OCaml definitions as normal Workbench.

## Hand-validation A: synthetic

From the checkout, using the already rebuilt normal binaries:

**Terminal 1 — fresh demo, prepare once and start:**

```sh
cd /home/wayne/devel/jane/silver
mkdir -p "$HOME/.local/state/hardcaml-workbench"
python3 -B scripts/synthetic-flow-demo.py prepare \
  --dir "$HOME/.local/state/hardcaml-workbench/synthetic-testing-demo"
python3 -B scripts/synthetic-flow-demo.py daemon \
  --dir "$HOME/.local/state/hardcaml-workbench/synthetic-testing-demo"
```

**Terminal 2 — seed and open:**

```sh
cd /home/wayne/devel/jane/silver
python3 -B scripts/synthetic-flow-demo.py seed \
  --dir "$HOME/.local/state/hardcaml-workbench/synthetic-testing-demo"
python3 -B scripts/synthetic-flow-demo.py client \
  --dir "$HOME/.local/state/hardcaml-workbench/synthetic-testing-demo"
```

Later sessions need only daemon/client. If that directory already exists, skip
prepare to reuse it or choose a new name in every command.

### Upgrade an existing synthetic demo

Restart matching rebuilt daemon/client binaries, then explicitly rerun `seed` with
the existing demo directory. It validates the synthetic manifest, adds owned missing
FS2 files/config, creates missing Testing by stable preset ID and applies defaults
additively. It preserves renamed/custom workspaces, pins, geometry, extra/hidden
tiles and saved selections, including deliberately cleared selections. It does not
duplicate an existing renamed Testing preset.

Unrelated or edited simulation configuration/provider files are not overwritten.
An ownership/hash conflict produces an actionable error; keep the custom setup and
prepare a separate demo directory rather than deleting state. Existing real-example
configuration is outside this upgrade path.

## Hand-validation B: actual ASIC example

The prepared persistent real-demo binaries have been refreshed to the current
build and verified again. Stop/restart an older demo daemon/client to load them.

**Terminal 1:**

```sh
cd /home/wayne/devel/jane/silver
python3 -B scripts/real-asic-example-demo.py daemon
```

**Terminal 2:**

```sh
cd /home/wayne/devel/jane/silver
python3 -B scripts/real-asic-example-demo.py client
```

Each demo uses its own automatically chosen port/state, so they can be open side by
side. The real root is `hardcaml_asic_example`, with673 genuine synthesis cells,
retained signoff/acceptance and rich Timing inspection. Daemon/client alone reopen
saved state; seed is an explicit historical import, not a startup requirement.
The original synthetic pass did not inject cases into that root. The subsequent
[Testing cluster](testing_workspace.md) separately adopts its actual FIFO Cyclesim
tests, with genuine reports/traces and no implied ASIC-run provenance.
The real provider's structured recipe/occurrences now populate checklist status on
Refresh. Checklist r also uses the project's explicit fresh-prefix capability
mapping, with bounded discovery when needed. See [real evidence and limitations](real_asic_example_demo.md)
and [the restored preparation workflow](checklist_launch_workflow.md).

For future builds refresh the persistent real-demo copies explicitly:

```sh
scripts/with-switch.sh dune build -j 2 \
  daemon/main.exe terminal/main.exe terminal/workspaces/export_presets.exe
python3 -B scripts/real-asic-example-demo.py refresh-binaries
```

## Verification

Final normal format/lint, full `dune runtest` and full build passed serially at2.
No staging, commits, pushes or new EDA executions were performed; live sessions
were not stopped or retargeted.

- Final normal-binary synthetic acceptance:
  `/tmp/opencode/synthetic-flow-kkw_d303/testing-result.json` — passed. Includes
  standalone copied provider, old-demo upgrade/refusal tests, all three workspaces,
  two seeded attempts plus one explicit PTY rerun, byte-exact reports/traces, labeled
  logs, stable reseeding/renames/pins/extras and restart without test replay.
- Agent synthetic ASIC launch/Timing/cancel regression passed at
  `/tmp/opencode/synthetic-flow-xy0yuwys/`; all five interrupts passed at
  `/tmp/opencode/workbench-terminal-interrupt-dxuryee7/`.
- Layout tests cover80×24/120×40/180×55 bounds, topology, visible FS2 and duplicates.
  Actual Timing/Testing120×40 and180×55 text/ANSI captures are in the final synthetic
  evidence directory above.
- Real binary refresh receipt: example
  `.dev/workbench-real-demo/receipts/refresh-binaries-ba3b02607ee446e88a67058d0d746203/`.
- Matching actual-example HTTP/PTY adoption passed at example
  `.dev/workbench-real-demo/receipts/acceptance-f3248de97eac43cfb4cc65862aebb98e/`.
  Genuine retained data and its canonical-input inventory checks remain separate
  from the synthetic FS2 demonstration. No real implementation was rerun.

Reproduce the focused synthetic check with existing normal binaries:

```sh
python3 -B scripts/test-synthetic-testing.py \
  --daemon _build/default/daemon/main.exe \
  --client _build/default/terminal/main.exe \
  --preset-export _build/default/terminal/workspaces/export_presets.exe
```
