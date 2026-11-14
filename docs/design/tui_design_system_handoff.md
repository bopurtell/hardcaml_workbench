# Reusable TUI Design System — Implementation Handoff

## Goal
Build a small, composable OCaml UI foundation for terminal applications such as **Silver** and **ches**. Separate *appearance*, *reusable components*, and *spatial layout* from application-specific state and behavior. Favor a consistent design vocabulary over a large widget framework.

## Proposed structure

```text
tui_ui/
├── theme/
│   ├── palette.ml       # semantic colors; no hard-coded colors in components
│   ├── typography.ml    # emphasis, muted text, headings, selection styles
│   ├── spacing.ml       # padding, gaps, compact/comfortable density
│   └── borders.ml       # line styles, corners, active/inactive borders
├── components/
│   ├── panel.ml         # optional title, frame, focus state
│   ├── tabs.ml          # active/inactive tabs, overflow
│   ├── status_bar.ml    # app state and contextual key hints
│   ├── command_palette.ml # searchable action list / transient overlay
│   ├── tree_view.ml     # expandable hierarchy, current selection
│   ├── inspector.ml     # label/value properties and sections
│   └── data_table.ml    # columns, rows, sorting/selection presentation
└── layouts/
    ├── split.ml         # horizontal/vertical splits, min sizes, resizing
    ├── dock.ml          # optional side/bottom regions and collapse
    └── workspace.ml     # named pane composition and focus traversal
```

Names are illustrative; adapt to existing module conventions. Avoid implementing everything at once.

## Architectural rules

1. **Theme tokens, not literal styling:** components consume semantic roles such as `text`, `muted`, `accent`, `selected`, `focused`, `error`, `warning`, `success`, `border`, `surface`. Support at least one dark theme; swapping themes should not change component logic.
2. **Components own presentation, not domain logic:** no Hardcaml-specific assumptions in `tui_ui`. Pass data, selection, focus, and actions explicitly; keep I/O, builds, simulations, and source navigation outside the library.
3. **Layouts own geometry:** child widgets should not calculate global screen positions. Handle terminal resizing, small viewports, min-size constraints, and overflow deliberately.
4. **Keyboard-first, discoverable:** distinct *focus* and *selection* states, consistent navigation conventions, a contextual keybinding footer, and an overlay/command-palette pattern. Mouse support is optional.
5. **Visual discipline:** consistent spacing, restrained color, optional borders (including borderless panes), no nested-box explosion, and legible dense-data modes. Prefer semantic color over decorative color.
6. **Fit existing stack:** build on the repository's actual Bonsai_term/Notty/Nottui primitives rather than inventing a parallel renderer. Avoid speculative APIs; inspect current dependencies and adapt this structure accordingly.

## First implementation slice (priority order)

- Implement semantic **theme tokens** and two density presets (`compact`, `comfortable`).
- Implement **Panel**, **Tabs**, **Status_bar**, and **Split** with uniform focus/selection styling.
- Create a small **demo workbench** with a hierarchy sidebar, diagnostics list, inspector, and bottom status bar, using mock data.
- Add **Tree_view**, **Inspector**, **Data_table**, **Dock**, and **Command_palette** only as the demo requires them.

## Definition of done

- The demo renders coherently at wide and narrow terminal sizes; panes degrade gracefully rather than overlap or crash.
- Focus, selection, active tabs, warnings/errors, and disabled/muted content are visually distinguishable.
- Switching theme/density changes the whole interface without editing components.
- At least two different application screens share the same components with no domain-specific imports in `tui_ui`.
- Include a small screenshot/gallery or executable examples for visual review; add focused tests for layout/focus behavior where practical.

## Non-goals (for now)

Full IDE/window manager behavior, graphics/waveform rendering, persistence, plugin APIs, animation, and implementation of Silver features. Those belong to later layers.

## Design iteration contract

Keep appearance decisions parameterized, not baked into widgets. Expect multiple candidate frontends described using the vocabulary **theme / components / layouts** (e.g. “muted monochrome theme + borderless panels + left hierarchy dock + tabbed inspector”).
