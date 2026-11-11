# F07 — Project setup and approachable presets

**Ticket entry points:** [WB-010 progressive adoption](project/WB-010-progressive-adoption.md),
[WB-017 project files](project/WB-017-project-files.md),
[WB-039 simulation setup](project/WB-039-simulation-setup.md),
[WB-049 config migration](project/WB-049-config-migration.md),
[WB-050 upward discovery](project/WB-050-upward-discovery.md),
[WB-051 creation](project/WB-051-new-project-creation.md) and
[WB-052 adoption polish](project/WB-052-adoption-polish.md).
The [catalog](README.md) separates additional work from the delivered initializer.

Status: bounded existing-project initializer delivered; current root manifest remains
supported. See [FS3 adoption](../fs3_adoption.md) for the initializer, portable
starter templates and persistent presentation preferences. Configuration-directory
migration is delivered in [WB-049](../migration_guides/project-configuration.md);
upward discovery and new-project creation remain requested.
The initializer requires a direct `dune-project`, matching the opener. An already
open project adopts its manifest through explicit refresh; a driverless reload
succeeds without scheduling a job. Installed initializer/client handoff is covered
by the 2026-10-17 integration evidence.

## Requirements

- Initialize Workbench configuration inside an existing directory/repository/Dune
  project without taking ownership of its build or version-control system.
- Support explicit roots and convenient upward configuration discovery; generic
  Dune fallback remains useful without hardware hooks.
- Keep project-local integration configuration in `.workbench/`, with explicit
  no-clobber migration and continued root-file compatibility.
- Separate committed integration/layout templates from personal selections,
  machine-specific paths, transient session state and rebuildable caches.
- Preserve/migrate existing `hardcaml-workbench.sexp` deliberately; do not silently
  change precedence when both old and new configuration exist.
- Offer starter/minimal layouts with a small visible command set. Users can add
  tiles/controls as they learn; the backend retains its real capabilities.
- Current shared starters are Overview/Timing/Testing; Resources is an illustrative
  future arrangement. ASIC-following views deliberately link to the session's Main
  context; Testing attempts remain project-scoped without implied ASIC association.
  Templates instantiate separate views; session persistence
  preserves intended shared context identities/linkage (F10). A minimal generic
  project can instead start with build/log and project-test views (F09).
- Appearance presets (F12) are separate from functional workspace templates.
  Persist explicit skin/density/icon/color choices without rewriting project flows,
  run contexts or canonical evidence; utility-tile placement is a layout preference.
- Later, create new projects using project/provider-owned templates, then open the
  result. Recipe content belongs to the ASIC project, not the Workbench config.
- Git is optional; Mercurial/non-VCS roots remain valid projects. Provider/source
  identity support for each VCS is a separate capability, never inferred falsely.

## First demo / later

First demos configure the existing specimen explicitly. Setup wizard, new-project
creation and expanded beginner templates follow the proven integration/layout model.

Dependencies: F01 configuration; F04 layout serialization; F03 command availability.
