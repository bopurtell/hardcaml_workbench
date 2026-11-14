# TUI frontend design system & candidate gallery — living handoff

**Status:** Exploratory design + comparative visual prototype for implementation handoff. **Version:** 0.5 (composable frontend decisions and candidate E, 2026-10-15).

> **This is the single canonical handoff going forward.** It supersedes `tui_design_system_handoff.md` for implementation purposes; do not require the agent to download or track a sequence of documents. Update this file in place as design reviews progress. `tui_style_gallery.html` is a useful visual reference, not an implementation spec or a validated terminal UI.

## Visual exploration 02 — latest artifacts and decisions

The canonical browser prototype is **`tui_style_gallery.html`** (updated in place). Companion capture files are `tui_style_gallery_preview.png` (Overview) and `tui_timing_gallery_preview.png` (Timing). They are **visual fixtures**, not Bonsai_term applications or pixel-accurate terminal layouts. No historical versions of this Markdown are required.

**Currently rendered in the HTML prototype:**

- **A — Instrument:** bordered btop-like metrics and monitoring dashboard, intentionally strongest for Overview but fully rendered for Timing too.
- **B — Structured:** Lazygit-like framed master/detail panels, naturally suited to timing investigations and diagnostics.
- **C — Minimal:** gh-dash-like reduced chrome; keep it as a real selectable option even though structure is less preferred initially.
- **D — Studio:** Posting-like workspace tabs, sidebar, card surfaces, internal path and file tabs, more prominent application chrome.
- **Fixture 1: Overview:** identical cells, WNS, Fmax, test status, module hierarchy, diagnostics, resource usage, build history in all four candidates.
- **Fixture 2: Timing:** identical path table, selected-path inspector, and a **placeholder** ches-mini source viewer in all four candidates. Do not mistake browser behavior for working Hardcaml or ches integration.
- **Axes exposed in demo:** workspace (Overview / Timing), color intensity (colorful / selective / restrained), icons (on/off), density (compact/comfortable), plus expanded viewing. These axes should remain independent in the real architecture.
- **Exploratory interactions:** clicking a critical path updates the common selected path/inspector fields for comparison; Ctrl+K previews a palette, and individual candidate cards can expand. The **source text remains illustrative** rather than a real per-path source fetch, even if the filename label changes. Only demand these features from the real app if existing architecture supports them or they are later prioritized.
- The **Resources** label is shown as a future workspace, **not** as an implemented third fixture. `Window 01` denotes one sample terminal/application surface and is not a new window-management subsystem.

**Current preference order (not final selection):** A/B visually strongest, D's tabs especially valued, C still retained. Add **E — Structured Studio**, a B+D hybrid, as a fifth implementation candidate. E is **specified here but not yet rendered in the HTML gallery**. The user prefers **seeing** variations to choosing exact border/color settings abstractly. The default remains deliberately undecided. The corrected ownership hierarchy is **Project Session → Window → Workspace → Tiles**, and must remain unchanged.

**Implementation interpretation:** `Theme` supplies semantic colors, icon fallback, spacing, borders and focus tokens; `Components` supplies panel, tabbar, metric, tree, table, diagnostic, inspector, editor-host and action-palette primitives; `Layouts` composes these into workspace tile geometry. Navigation strips, status lines, project summaries and other apparent “application chrome” should generally be **ordinary composable tiles**, not unconditionally reserved rows/columns. A/B/C/D/E are appearance/layout presets; **workspaces are named task contexts, not appearance names**. Do not hardcode Timing=B or Overview=A. D/E-style tabs should be available in A/B/C too.

**Important scope constraint:** the HTML prototype draws web elements inspired by terminal interfaces. The real implementation must use existing OCaml/Bonsai_term primitives and validate terminal width/height, unicode width and font/nerd-glyph fallback. Do not ship a web renderer inside Workbench as a consequence of using the preview.

## Decision update 03 — composable surfaces, headers, overlays, and environments

**These points supersede earlier mockup assumptions wherever they conflict.**

### Presentation ownership: almost nothing fixed

- **The daemon owns/tracks the existing Project Session → Window → Workspace → Tile model and currently open instances.** The frontend is a *presentation client* deciding how to render the available windows/workspaces/tiles. Do not create a second authoritative workspace registry in the frontend.
- A **Window** is a terminal/application surface, **not** an Overview/Timing view; a **Workspace** is an arrangement of tiles (including any utility/navigation tiles). Multiple windows may eventually render concurrently from the same daemon on different monitors/terminals.
- **Tile-first UI:** design navigation bars, workspace switchers, status summaries, legends, headers, and inspector areas as composable/mountable UI wherever feasible. An Overview workspace can include a top tab strip while a Timing workspace can choose side navigation, hide it, or move it without changing core session semantics. Do not make the gallery's permanent header/sidebar/footer into architectural requirements.
- Distinguish *semantic functionality* (navigate workspace, activate tile, show status) from *presentation geometry* (top bar, bottom strip, sidebar, floating, hidden). Both the former and their bindings must remain usable even if no navigation tile is mounted in a particular arrangement.
- There will inevitably be **thin non-tile infrastructure** for the terminal renderer, input/focus routing, z-order/overlay host, lifecycle, and minimum recovery/navigation affordances. Treat these as infrastructure, not a visually fixed application shell. Reuse what already exists.
- Keep **shared project/daemon state** distinct from **per-window/per-client presentation state** such as focus, terminal dimensions, open overlay, scroll offsets or panel geometry *as supported by the existing app*. Inspect existing ownership before formalizing storage/persistence.

```text
Project Session / daemon           shared project data + tracked windows/workspaces
  ├─ Window A                     terminal/application surface
  │    ├─ Workspace: Overview     tile arrangement + optional chrome tiles
  │    │    ├─ [workspace-selector tile]  (optional; may move or hide)
  │    │    ├─ [status/metrics tiles]
  │    │    └─ [diagnostics tile]
  │    └─ Workspace: Timing
  │         ├─ [path list tile]
  │         ├─ [path inspector tile]
  │         ├─ [ches-mini tile]
  │         └─ [tab/navigation tile] (optional)
  └─ Window B                     potentially another concurrently rendered surface
       └─ Workspaces / tiles according to existing daemon model
```

### Tile headers

- **Most tiles should have a header by default**, with a title and room for contextual tabs, focus indicator, compact actions, progress, or a metric. A deliberately headerless tile remains supported (e.g. a tiny status widget or full-bleed graph).
- Header anatomy should be configurable: `title`, optional subtitle/status, optional tabs, optional actions, emphasis when focused, and optional border integration. Avoid obligating each tile to own a duplicated navigation system.
- Header presence is a **tile presentation choice** and its look comes from design tokens, not from a hard-coded rendering style. In minimal candidate C, a header may be text-only; in B/E it may integrate into a box border; in D it may carry rich tabs.

### Existing floating panels: extend, do not replace

- **ches already has a floating-panel system.** Inspect and reuse its actual overlay/stacking/lifecycle APIs; do not implement a parallel floating-window manager for Workbench or the generic design library.
- Borrow **Posting's navigation discoverability** (contextual key help, quick jump-to-target labels, searchable command palette) and **Zellij's presentation/interaction options** (tiled↔floating transition, optional frames, resize/reposition, hide/show and pin where appropriate) as *candidate behaviors*, not compulsory scope. Prefer thin adapters and reusable skins around the existing ches mechanism.
- Test a small set of showcase overlays: **command palette** (search actions), **path/source quick peek** (temporary inspector/editor), and **context help** (relevant bindings for the focused tile). Avoid hardcoding all overlays as modal: distinguish blocking dialogs from nonblocking peeks.
- References: [Posting navigation](https://posting.sh/guide/navigation/), [Posting features](https://posting.sh/), [Zellij floating pane controls](https://zellij.dev/documentation/cli-recipes.html). These are UX references, not implementation dependencies.

### Target use environments (do not overfit to pixels)

- **Primary:** desktop workstation with four monitors in a 2×2 arrangement, roughly 2560-class resolution per monitor; Workbench normally fills **one monitor**. A high-density multi-pane Overview is a useful default *fixture*, not a permanent layout restriction.
- **Secondary:** ~13-inch ThinkPad X1 Carbon, connected to a server through **SSH and tmux**. The user is comfortable changing zoom/font size or switching to narrower workspace layouts; we do **not** need to nail automatic responsiveness in the first pass.
- Design/layout testing must be in **terminal rows and columns**, not pixels. Support a wide and a modest/narrow cell grid, accounting for tmux, glyph widths, and keybindings swallowed by outer terminal/tmux layers. At minimum provide a graceful narrower fallback (select/scroll/hide instead of clipping critical information).
- In future, several windows may attach to the daemon simultaneously, potentially across monitors or clients; avoid global presentation assumptions (one active workspace, one focus location, one screen size). **Do not implement multi-client coordination just for the gallery.**

### Candidate E — Structured Studio

Add a genuine fifth appearance variant combining **B's strong framed tile structure, grid and inspectors** with **D's more developed tab treatments, contextual actions and selective application-like polish**. E should remain a **composition of existing primitives**, not a fifth fork of domain logic.

For the next gallery update, show A–E on the **same Overview and Timing fixtures**. Keep color, icons and density independent of preset. The existing A–D HTML captures are still valid historical *fixtures*, but do not imply E is already implemented.

## Goal

Build a reusable OCaml terminal-UI foundation for **Silver** and **ches**, then demonstrate several independently selectable visual styles. The user wants to see implementations before deciding defaults and expects to retain alternate styles. The immediate deliverable is a five-candidate gallery and reusable primitives around the **existing** window/workspace/tile and ches overlay mechanisms, **not** a new window manager or domain integration.

### Confirmed design feedback

- Candidate **A / instrument** (btop-like): highly attractive for an **Overview workspace** displaying system/build/design status.
- Candidate **B / structured** (Lazygit-like): highly attractive for **interactive investigation workspaces**; visible boxes and clear organization are positives.
- Candidate **D / studio** (Posting-like): attractive for interactive workspaces; **its tab system is particularly appealing**.
- Candidate **C / minimal** (gh-dash-like): lack of explicit structure is less attractive, **but retain it as a candidate** and implement it in the gallery.
- Experiment independently with **vivid**, **selective**, and **restrained** color intensity. In selective mode, neutral chrome with emphasis on engineering information such as **WNS**, cell count, and **PASS/FAIL**. Keep iconography optional, inspired by Posting/Yazi/Superfile, with font-safe fallbacks.
- **Do not select a default or eliminate candidates yet.**
- Nearly all visible UI (including optional top/bottom bars, workspace tabs, sidebars) should be composable **tiles** rather than fixed application chrome.
- Most tiles have configurable headers; some small/full-bleed tiles may omit them.
- **E / structured-studio** combines B's framed grid and D's richer tabs without duplicating tile logic.

## Existing Workbench hierarchy — preserve, do not invert

**Confirmed by the user:** Silver is already built around this hierarchy. Do **not** model workspaces as parents of windows or treat “window” as a task-specific tile arrangement.

```text
Project session                         # shared project context and services
  Window(s)                            # independent terminal/application surfaces
    Workspace(s)                       # Overview, Timing, Resources, etc.
      Layout/arrangement               # splits, tabs, docks, tile geometry
        Tile instance(s)               # hierarchy, metrics, diagnostics, ches-mini…
          Component(s)                 # panel, table, tree, tab strip, editor host…

Appearance configuration                # orthogonal to functional hierarchy
  colors + component skin + icons + density + presentation rules
```

A **window** hosts multiple named **workspaces**. A **workspace** is the task-oriented collection and arrangement of **tiles**, including optional navigation/status tiles. Several windows can exist in a project session; do not assume they must all show the same active workspace, arrangement or terminal size. The **daemon tracks the actual open windows/workspaces**; the rendering client should not become a competing state owner. Precise synchronization and persistence are existing-app concerns to inspect rather than invent here.

Suggested *workspace* examples (not fixed definitions):

- **Overview workspace** (A): utilization metrics, WNS, test summary, recent diagnostics, high-level hierarchy.
- **Timing workspace** (B + optional D-like tabs): critical paths, path details, timing reports, and a **ches-mini source-editor tile** to inspect source beside timing data.
- **Diagnostics workspace** (B or D): diagnostic list, source/editor tile, contextual inspector, tabs for errors/warnings/tests.
- **Simulation workspace** (D): tabbed logs, signal/state inspection, run controls; B's strong pane boundaries remain available.
- **Minimal presentation** (C): alternate chrome/layout treatment of *any* compatible workspace, not a separate domain or missing candidate.

**Important distinctions:**

- Switching **workspaces** changes the displayed tile arrangement **within a window**.
- Switching **windows** moves between terminal/application surfaces; it is **not** the same as selecting a task view.
- Switching **tabs** changes the selected panel/view *within a workspace or tile*; D-like tabs may appear in other visual presets.
- Switching **appearance** changes styling/presentation, not project state, workspace identity, or tile behavior.
- A named **workspace definition** (tile membership and semantics) must not be coupled to one visual preset. An Overview workspace might use A; Timing may use B plus D-style tabs; C must remain testable.
- Tiles may synchronize on selected module, source location, path, or diagnostic through explicit shared context; tiles also retain appropriate local focus, scroll, and filters.
- A `ches-mini` editor should be hosted as a reusable tile/adapter, not reimplemented in Timing; the integration boundary should carry source-navigation requests and focus/keymap ownership.
- Any changes to actual windows, workspace lifecycle, or navigation **must follow existing Silver implementations**. The design-system task should not impose a new window manager.

## Core library decomposition

```text
tui_ui/
  theme/             # semantic roles, color intensity/palette, typography/emphasis,
                     # spacing/density, border styles, focus/selection tokens
  components/        # Tile_header, Panel, Tabs, Status_bar, Tree, Inspector, Data_table,
                     # Metric, Diagnostic_list, Command_palette, icon/text primitives
  layouts/           # Split, Dock, Stack/Tabs, tile arrangements inside workspaces,
                     # optional chrome tile placement, min sizes, resizing
  overlays/          # thin presentation adapters to EXISTING ches floating panels;
                     # no second floating-panel/window manager
  icons/             # named semantic icons; none/ascii/unicode/nerd_font fallbacks
  gallery/           # mock workbench fixtures, palette/layout selector, captures

workbench/           # outside generic UI library
  tiles/             # overview, hierarchy, diagnostics, timing paths, ches-mini host…
  windows/           # terminal/application surface hosts (existing architecture)
  workspaces/        # named arrangements of tiles: Overview, Timing, Resources…
  session/           # shared project state/services; adapt to existing structure
```

These are conceptual boundaries, not assumed existing Bonsai_term modules. Inspect the repo and actual Bonsai_term / Notty / Nottui APIs before choosing names or adapters; do not build a competing terminal renderer.

### Independent axes

1. **Workspace composition**: the *functional* tile set and interactive purpose (Overview vs Timing vs Diagnostics).
2. **Layout geometry**: position/sizing/docking/stacking of the workspace’s tiles, independent of the data they display.
3. **Component skin**: framed vs quiet borders; tabs, badges, active/focused panels, dividers, status chrome.
4. **Color treatment**: `vivid | selective | restrained`, applied via **semantic tokens**, not component hard-coded colors.
5. **Icon mode**: `none | ascii | unicode | nerd_font`, with width-tested reliable fallbacks and no hard dependency on fonts.
6. **Density**: `compact | comfortable` (spacing, row heights, amount of metadata visible).

7. **Chrome composition**: which (if any) utility tiles are mounted as top/bottom/side/floating navigation, status, action legend or project context; do not reserve fixed bands by default.

An end-user **appearance preset** can bundle geometry/skin/color/icons/density and suggested chrome tile positions, with optional overrides. It is **not** the definition of a functional workspace, nor a second hierarchy of windows.

### Starter visual candidates

| Key | Influence | Distinguishing treatment | Likely initial fit |
| --- | --- | --- | --- |
| `instrument` / A | btop, bottom | Framed metrics, charts, dense dashboard, clear panels | Overview |
| `structured` / B | Lazygit | Strong pane boundaries, focus, master-detail inspectors, hints | Timing/Diagnostics workspaces |
| `minimal` / C | gh-dash | Border-light, whitespace and text hierarchy | Alternate for evaluation |
| `studio` / D | Posting, Yazi, Superfile | Rich tabs, sidebars, icons, polished active states and overlays | Simulation, source, Diagnostics workspaces |
| `structured_studio` / E | B + D | Strong rectangular panes and inspectors; D-inspired contextual tabs, labels and tile actions | Timing, interactive workspaces |

**Note:** A/B/C/D/E are *visual exemplars*, not rigid templates dictating which domain tiles a workspace may contain. D/E-style tabs should be usable in B and A workspaces, and minimal C must stay represented.

### Color semantic roles

Define logical roles such as `foreground`, `muted`, `surface`, `border`, `focused`, `selected`, `accent`, `success`, `warning`, `error`, `neutral_metric`, `emphasized_metric`, `tab_active`, and `tab_inactive`. Preserve the *meaning* of errors, negative WNS, and failed tests even in restrained or monochrome mode (text, prefix, contrast, emphasis). Do not color every figure solely because vivid mode is active.

## Comparison fixture & interaction coverage

Use the **same mock data per compared view**, with the same semantic states:

- Synthetic project: `tickweave` (clearly marked *demo*).
- Hierarchy: `top / packet_parser / order_book / strategy / order_submit`.
- Metrics: `cells=18,432`, `WNS=-0.18 ns`, `Fmax=156.2 MHz`, `tests=126/128`.
- Diagnostics: timing violation, test failure, unused signal, width truncation.
- Timing detail: critical paths, path selection, source jump target like `strategy.ml:214`.

Produce **two comparable fixtures initially**, initially showing A–D and extending the next gallery iteration to **A–E**:

1. **Overview workspace fixture** to compare A/B/C/D/E using dashboard-like data.
2. **Timing workspace fixture** to compare A/B/C/D/E using a table, details, and a mock `ches-mini` editor tile.

Do not declare that the preview represents a true editor integration. Use a placeholder source-view widget until ches-mini APIs are understood. Each gallery configuration should demonstrate focus changes, tab switching, selection, and at least one **ches-backed (or clearly mocked)** overlay/command palette so the comparisons include interaction chrome. Showcase optional **tile-based chrome**: top navigation in D, framed header/action region in B/E, minimal/hidden chrome in C, status tiles in A. Do not imply that fixed bars are mandatory.

## Implementation phases

**Phase 1 — reusable foundation and gallery (do this first)**

1. Inspect existing stack and share primitives for styling, focus/selection, sizing, and terminal glyph handling.
2. Implement semantic tokens and palette mappings; support three color treatments and optional icons.
3. Implement core components: `Tile_header`, `Panel`, `Tabs`, `Status_bar`, `Tree`, `Data_table`, `Metric`, `Inspector` (add others only if the gallery needs them).
4. Implement composable `Split`/`Dock`/`Tabs` layout primitives and **five** thin visual examples, with arbitrary status/navigation tile placement.
5. Inspect the existing **ches floating-panel** mechanisms; prototype styling and a tiny adapter for a command palette or contextual quick-peek rather than creating a new overlay manager.
6. Build Overview and Timing **mock** galleries, hot-swappable at runtime; preserve selection/focus where applicable.
7. Capture a large-monitor-equivalent cell grid and laptop/tmux-like cell grid for comparative review; prioritize functional display over polished responsive rules.

**Phase 2 — integrate with existing project session → window → workspace → tile model (after gallery)**

- Inspect and reuse existing window surfaces, workspace switching, and project-session ownership; **do not invert the hierarchy or build a competing window manager**.
- Associate named workspace definitions with their tile arrangements, **including optional chrome tiles**; maintain per-window/per-client active-workspace and focus state according to the daemon's actual model and existing code.
- Integrate tile mounting, mostly-on tile headers, focus traversal, resize/collapse, per-workspace tab state, and keyboard dispatch where not already provided. No mandatory global header/sidebar/footer.
- Use shared selection/navigation context and an editor tile-host interface for `ches-mini`.
- Keep new persistence mechanisms, drag-and-drop docking, and complex reparenting out of initial scope unless already supported.

**Phase 3 — domain integration (later)**

- Connect real workbench reports, diagnostics, paths, simulations, tests, and ches-mini source editor.
- Validate focus/keyboard ownership and source navigation across tiles, workspaces, and window surfaces.

## Acceptance criteria for Phase 1

- Five visual candidates available, including **E = B+D hybrid**; **C is not omitted**.
- Three color intensity modes independently switchable; optional icon mode; high-priority engineering statuses still clear without color.
- A and B visibly framed; D demonstrates real tabs; C intentionally lower-chrome.
- Both mock workspace fixtures (Overview and Timing) can be rendered in each candidate without duplicating domain logic; any optional chrome is itself placeable/hideable as a tile.
- Focus differs visibly from selection; active workspace/tab and window focus remain clear **even without fixed global chrome**; most tiles have clear optional headers.
- No overlap, crash, or silent data loss at modest/narrow **terminal cell dimensions**; degrade via scrolling, tabbing, hiding secondary details, or explicit overflow controls. Do not overengineer pixel-responsive design.
- Swapping style does not destroy app state; switching workspaces, windows, or tabs is conceptually separate from changing theme.
- Generic `tui_ui` layer contains no Hardcaml-specific business logic and does not replace the existing ches floating-panel implementation or daemon window/workspace ownership.

## Iteration policy

Show functional variants first; do not ask for individual hex colors or border glyphs until there is something concrete to critique. Accept combinations such as **A's dashboard widgets + B's framed panels + D's tabs + selective color**. After each review, update **this same Markdown file** and the gallery preview rather than creating an accumulating series of handoffs. The current HTML artifact still visualizes A–D; E is a requirement for the **next** gallery implementation/revision, not something already delivered.
