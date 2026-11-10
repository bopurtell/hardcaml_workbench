# Migration and refactor handoffs

This directory groups actionable migration/refactor guides for another session.
Guides describe the starting state, boundaries, staged changes and verification;
they do not create another active queue or retroactively change historical evidence.

| Document | When to use it |
| --- | --- |
| [Workbench test refactor](workbench-test-refactor.md) | Continue organizing local tool tests, shared support, integration runners and external/example-sensitive acceptance |
| [Cross-repository session checkpoint](../session_checkpoint.md) | Recover the PT.0–PT.8/backend/Workbench context, completed slices, paused acceptance and next decisions |

Authoritative queues:

- [Workbench construction phase plan](../construction_phase_plan.md).
- [ASIC phase plan](../../../hardcaml_asic/docs/phase_plan.md).

Related existing documents remain at their original paths so evidence and links
are preserved:

- [First test-organization implementation plan](../test_organization_plan.md)
- [Testing ownership and suite guide](../testing.md)
- [Test inventory](../testing_inventory.md)
- [Test-selector verification](../test_suite_selection_verification.md)
- [Configuration-migration ticket](../features/project/WB-049-config-migration.md)
- [Native provider migration/acceptance](../native_provider_plan.md)

For future guides, include: snapshot date, authoritative queue, what is already
done versus proposed, compatibility/preservation constraints, affected contracts,
exclusive file ownership, incremental steps, acceptance/negative controls, exact
commands where safe, and a short next-session checklist. Link old evidence rather
than moving or rewriting it merely to group documents.
