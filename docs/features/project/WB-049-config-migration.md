---
id: WB-049
title: Configuration-location migration and precedence
category: project
feature_sets: [FS3]
status: closed
kind: enhancement
priority: P2
severity: n/a
requested_size: Unspecified
size: M
points: 13
confidence: medium
estimate_scope: incremental
origin: owner-intake
tags: [configuration, migration, precedence]
depends_on: []
related: []
---

# WB-049 — Deliberate configuration migration

## Request
Original size: **Unspecified**. Move shareable project configuration toward a
dedicated location with explicit migration and unambiguous precedence.

## Current baseline
Delivered 2026-11-11: `.workbench/` holds the four unchanged generic, ASIC,
simulation and preparation basenames. Legacy root lookup remains supported.
All loaders share explicit byte-conflict resolution; personal state remains separate.
See the [migration and verification guide](../../migration_guides/project-configuration.md).

## Scope
- Select one project configuration directory and enumerate migrated file classes.
- Define lookup precedence and conflict diagnostics for old/new coexistence.
- Provide explicit dry-run and no-clobber migration of the agreed configuration set.
- Preserve provider path interpretation and explain identity/cache consequences.

## Out of scope
Moving canonical run evidence, merging personal state into source configuration,
or silently transferring registries between provider identities.

## Acceptance criteria
1. Old-only projects retain documented behavior throughout the compatibility window.
2. New-only and both-present cases have deterministic, visible resolution.
3. Conflicting content never silently selects a different provider or execution environment.
4. Dry-run describes every write; a failed migration leaves original configuration usable.
5. Generic, ASIC and simulation lookup behavior is documented consistently.

## Dependencies
Required: existing loaders and FS3 initializer; no additional ticket prerequisite.
Related: none; upward discovery can use today's root filenames independently.

## Estimate rationale
13 points cover one agreed migration policy, loader updates and bounded migration tooling.
Exclude root-discovery changes, template redesign and automatic run-registry migration.

## Assumptions and decisions needed
Selected `.workbench/`, retaining four independent schemas and basenames. Legacy
compatibility has no scheduled removal. Equal dual files select the common location;
differing bytes fail. Explicit migration copies without deleting originals or
clobbering targets. Relative paths retain project-root meaning. New generic and
simulation initialization uses the common directory.

## References
- [Setup policy](../project_setup.md)
- [Generic manifest](../../../project_integration/manifest.ml)
- [ASIC configuration](../../../project_integration/asic_config.ml)
- [Simulation configuration](../../../project_integration/simulation_config.ml)
