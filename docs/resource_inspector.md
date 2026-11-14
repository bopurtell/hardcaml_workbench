# Inspect resources in Workbench

Resources shows ASIC-owned requested, selected, elaborated and realized facts.
Opening a source reads existing evidence; it does not build, emit, synthesize or
run physical tools. The provider owns selection, reconciliation and measurements.

## Open the workspace

Open **Space c c** and choose **Inspect resources (open Resources workspace)**.
Fresh default sessions include Resources after Timing. Existing saved layouts are
preserved: this explicit action creates/opens Resources without resetting other
workspaces. **Add resource-summary tile** adds the compact Overview entry.

### Inspect the actual SRAM evidence

Choose **Resources: Import retained resource evidence**, enter the following exact
directory **without quotes**, then press Enter:

```text
/home/wayne/devel/jane/hardcaml_asic_example/acceptance/resource-measurements/accepted-live-01/run
```

This is a retained coarse-run capture, not a newly executed run or a synthetic
observation stream. It preserves original run `be961b2c95f74c81ad6af81ca4d2b269`
and its build identity. The table should show `program`, the stock SRAM selection,
actual instance `hc_resource_7_program`, and synthesis/final `matched` observations.

Other explicit targets:

- **Resources: Import emitted bundle** — verify exact bundle inputs and inspect
  selected inventory before any physical execution.
- **Resources: Select workflow bundle …** — inspect that workflow's exact emitted
  bundle; failed/not-yet-emitted workflows have no successful empty inventory.
- **Resources: Select execution … / Select finalization …** — retain the selected
  execution/operation linkage. Unsupported named-stage realization is unavailable;
  aggregate checkpoint counts do not prove per-resource retention.
- **Resources: Follow tile run binding** — follow the exact workspace selected or
  pinned run. Explicit imported sources remain independent of Main changes.

Historical sources lacking inventory show **Unavailable** or **Unknown**, not
“Resources: 0.” A genuinely verified resource-free FIFO shows available empty
inventory. Likewise, implementation selection is not synthesis/physical retention.

## Controls

| Key/action | Behavior |
| --- | --- |
| `j` / `k`, arrows | Select resource/source rows; scroll in detail |
| Enter | Open selected resource detail or authorized source bytes |
| Esc | Return to the previous inspector view |
| `/`, Ctrl-U | Filter resources; clear filter |
| `g` | Geometry, physical component areas and gross-area ratios |
| `t` | Sampled timing paths |
| `e` | Electrical point observations |
| `d` | Full source provenance/context |
| `a` | Authorized source catalog |
| `n` / `p` | Next/previous provider page |
| `[` / `]` | Scroll eight wrapped lines |
| `r` | Explicitly refresh the exact evidence source |

The palette also exposes inventory, synthesis and final detail sections. Timing
items are byte-bounded: a page may contain fewer than the requested eight rows.
Follow the returned next page rather than assuming a fixed offset. All 76 advertised
sources in the SRAM capture are reachable through the paged catalog.

Source bytes are addressed by provider-authorized handles and validated hashes,
not arbitrary client paths. Text is sanitized for display; byte offset/hash remain
the original source identity. External SRAM model references may be recorded without
retained bytes and are not turned into readable artifacts.

## Interpret the example

- Requested contract: 256×16 single-port memory; explicit exact mapping and its reason.
- Selected macro: `RM_IHPSG13_1P_256x16_c2_bm_bist`.
- Footprint: **28,127.104 µm²**; nonspacer standard-cell footprint sum:
  **4,793.6448 µm²**; gross core rectangle: **902,417.2416 µm²**.
- **186 sampled timing paths / 372 electrical point observations**.
- Slow setup path includes macro `A_DOUT[11]` → `uo_out[3]`, slack
  **11.246561 ns**, output slew **0.067838 ns**, reported load **0.004815 pF**.
- Fast hold path ends at macro `A_ADDR[6]`, slack **0.223533 ns**; blank load remains
  absent. Analysis −40°C and bound SRAM model −55°C are displayed separately.

Area ratios are component rectangle sums over gross core/die rectangles, not
geometric unions or usable placement-site utilization. Electrical compliance is
**not_assessed**; timing coverage is sampled, not exhaustive. No per-resource power,
optimized-flop ownership, timed SRAM conformance or IR/EM qualification is implied.

Import the original `acceptance/sram/physical-p4` separately to see geometry with
timing unavailable: it does not contain the raw STA reports. The inspector never
borrows those reports from the augmented capture. Likewise, the separate synthesis
specimen's 30,309.8272 µm² combined estimate is not a physical area for this run.

## Compare explicit sources and use declared controls

1. Select/import the first source and choose **Resources: Capture comparison A**.
2. Select/import the second and choose **Resources: Capture comparison B**.
3. Choose **Resources: Compare captured A / B (c)**. Swap using the palette action.

Captures keep exact source/provider/index identities; Main changes never retarget
them. Changed provider/projection or lost validation is visible. Contract, policy,
selection, reason, role and realization differences remain explicit. Numeric deltas
require finite values and equal name/unit/stage/definition/scope/classification.
Only provider-classified **Observed** or **Derived** values receive measured deltas;
estimates/unknowns do not. Missing values retain their actual unavailable reasons.

Existing **Plan ASIC FLOW / PROFILE (enter endpoint)** and **Preparation inputs:
FLOW / PROFILE** actions expose the project's advertised controls. This feature
does not add unsupported memory-policy knobs or launch a variant sweep. Changing
inputs stages a new explicit workflow; inspecting/comparing alone never launches it.

## Freshness and failures

Rendering, filtering, ordinary polling and warm cached reopening do not invoke the
provider. Explicit cold open/refresh/page requests are bounded read-only operations.
Restored cache is **Cached_unverified**. Failed refresh, missing source, unsupported
capability and invalid evidence remain distinguishable from a valid failed resource
check. Failed required-macro evidence is readable rather than discarded as a transport
error. A late response cannot populate a different target or acknowledge a new retry.

Index truncation is visible. Catalog/detail pages are bounded; a single item too
large to represent produces an explicit error. Current limits are 32 source
descriptors, eight indexes and a bounded detail cache; these are not unlimited archives.

## Start the tested app pair

Both daemon and client changed. Stop the previous pair when no work is active, then
start the rebuilt default binaries. No demo `seed` or pinned-binary refresh is needed.
Only one daemon may own the selected state directory. Substitute your intended
state directory if it differs from the earlier session below.

Server:

```sh
cd /home/wayne/devel/jane/hardcaml_asic_example
source .dev/asic-pt6/generations/97b85a9e25e24615b758b97b21ca9697/activate.sh
export OCAMLPATH="$OCAMLPATH:$PWD/.dev/workbench-provider-sdk/lib"
export DUNEJOBS=6 OPAMJOBS=6 OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 MKL_NUM_THREADS=1
/home/wayne/devel/jane/silver/scripts/with-switch.sh \
  /home/wayne/devel/jane/silver/_build/default/daemon/main.exe \
  --port 41735 --state-dir /tmp/opencode/workbench-pt5-Zcj6Y5
```

Client:

```sh
cd /home/wayne/devel/jane/silver
./scripts/with-switch.sh _build/default/terminal/main.exe \
  --connect http://127.0.0.1:41735 \
  --project-root /home/wayne/devel/jane/hardcaml_asic_example \
  --environment inherited
```

After owner approval, only the example companion's `provider_executable` was moved
to the exact final PT.6 generation above. Its project executable, tool paths,
timeout, results and all existing `current` pointers were preserved. The dedicated
PT.6 `current` still identifies an earlier capture; use the **immutable final path**
above, not that pointer. New capability `resource_inspection1` is required.

Provider-scope change can require explicit re-registration of older named runs;
original result bytes remain intact. The SRAM import above works independently of
that named-run cache and does not create/execute a physical run.

See [implementation contract](resource_inspector_plan.md),
[frozen API handoff](resource_inspector_handoff.md) and
[native acceptance evidence](resource_inspector_acceptance.md).
