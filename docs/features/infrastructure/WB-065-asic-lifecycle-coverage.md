---
id: WB-065
title: Broader ASIC lifecycle/cancellation race coverage
category: infrastructure
feature_sets: [FS1]
status: delivered
kind: validation
priority: P2
severity: n/a
requested_size: Unspecified
size: M
points: 13
confidence: medium
estimate_scope: incremental
origin: existing-backlog
tags: [asic, lifecycle, cancellation, races]
depends_on: []
related: [WB-044, WB-062]
---

# WB-065 — Broader ASIC lifecycle/cancellation race coverage

## Request
Carry forward construction-plan lifecycle/cancellation coverage gaps across late
responses, allocation and reconnect. These are existing followups, not new owner requests.

## Current baseline
FS1 records real owned backend/container and postcheck cancellation, plus focused
fixture coverage. Those records explicitly do not establish every race permutation.

## Scope
- Define a bounded lifecycle matrix across allocation, launcher, reader and postcheck.
- Add deterministic late-response/reconnect/cancel and concurrent-client specimens.
- Verify exact owned-process targeting and separation of reader/producer lifecycle.
- Retain actual frontend/transport evidence for selected interaction boundaries.

## Out of scope
- A second ASIC engine, fresh broad physical acceptance or claims of exhaustive races.
- Treating client detach or reader shutdown as permission to terminate historical producers.

## Acceptance criteria
- The matrix maps prior evidence, new coverage and remaining explicit gaps.
- Cancel before/after allocation and during postcheck preserves exact operation identity.
- Late responses cannot retarget newer selections or resurrect cancelled work.
- Client detach preserves work; shutdown/cancellation signals only owned processes.
- Concurrent readers/clients do not duplicate launch or falsely report producer termination.
- Fixtures distinguish execution completion, cancellation and acceptance verdicts.

## Dependencies
No additional prerequisite tickets; existing services and fixtures provide the seams.
[WB-044](WB-044-load-acceptance.md) supplies related load coverage and
[WB-062](../verification/WB-062-submission-recovery.md) addresses simulation receipt recovery,
not prerequisites for targeted ASIC lifecycle coverage.

## Estimate rationale
13 points, M, medium confidence: known lifecycle boundaries need a coherent matrix
and deterministic race fixtures. Incremental estimate covers bounded validation,
excluding unrelated runtime redesign and new physical-flow execution campaigns.

## Assumptions and decisions needed
Select the highest-value uncovered permutations from construction records first.
Use fixture evidence where it proves ownership/order, retaining limits on real-tool claims.

## References
- [Construction lifecycle coverage gaps](../../construction_phase_plan.md).
- [FS1 lifecycle/cancellation evidence](../../fs1_lifecycle_and_artifacts.md).
- [ASIC service ownership/shutdown contract](../../../backend/asic_service.mli).
- [Backlog coverage followups](../../backlog/README.md).

## Targeted delivery — failed launcher/final observation race (2026-10-21)

The real demo run `d041691ff79b44a4b5a81e483be5576a` reached signoff, then the
backend timed out after 607.08 seconds and exited 2. The supervisor cancelled its
automatic observer without joining it or reconciling terminal provider records.
Workbench retained cursor 19, `observing`, and signoff `Running`, while records
20–21 contained the terminal failure. The spinner stopped because the owned run
operation was no longer active, not because the daemon or client animation clock
had been shown to hang.

`backend/asic_service.ml` now cancels and joins the polling observer after the owned
process ends, then performs final reconciliation with a fresh 90-second cancellation
budget and at most two observation passes. The original process error is retained
independently. Stage outcomes come from provider evidence, never inferred from the
launcher exit. If final evidence is unavailable or its writer remains active,
observation becomes explicitly unavailable and unresolved Running/Pending stages
become `Unknown observation_unavailable`; already terminal stages remain intact.

The checklist also qualifies unresolved state as **Observation stopped; stage state
unconfirmed** when exact-run failure evidence warrants it. Vertical, compact,
horizontal, scrolled and pinned views retain the warning and error details. An active
replacement observer suppresses an obsolete warning. Absence of a locally owned
producer alone does not establish failure of an external run.

Regression coverage includes terminal failure records published immediately before
exit 2 during an in-flight read, failed final inspection, a still-active writer,
successful completion, cancellation, deduplicated submissions and Refresh recovery.
Full combined build, tests and lint passed serially at `-j4`.

The existing live run was recovered using one explicit `Refresh`, without restarting
the daemon or launching execution: cursor 19 → 21, run `observing` → `failed`, signoff
`Running` → `Failed`, retained summary `Validated` with failed completion and acceptance
`not_evaluated`. Missing signoff checkpoint/clock/timing evidence remains honestly
unavailable; reconciliation cannot create results the failed stage never published.

This closes the concrete incident, not the entire broader lifecycle matrix above.

## Bounded matrix delivery (2026-11-05)

The [coverage matrix and verification record](../../asic_lifecycle_matrix.md)
maps prior evidence, new backend/HTTP/frontend receipt specimens and remaining
limits. Queued/pre-allocation/late-allocation and postcheck cancellation, identity
rejection, detached/concurrent clients, reconnect/shutdown ownership, and stale
selection responses are covered. Two pending-task run identity omissions were fixed.
Full build, tests and lint passed at `-j5`; changed OCaml files pass formatting,
while global formatting retains baseline failures. Delivery is bounded to this
matrix, not exhaustive physical-stage or crash races.
