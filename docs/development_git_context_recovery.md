# Development synthesis collateral revision recovery

2026-11-05. Bounded plan written before implementation. User's source elaboration
completed, but stage preflight rejected `support_tools_revision`. The failed
operations and immutable captures remain historical evidence; no tool checkout,
expected revision or revision-validation policy may be changed to make them pass.

**Correction implemented and independently verified in isolated captures.**
The active user generation was not refreshed or restarted. See
[independent consumer/preflight review](development_git_context_independent_review.md).

## Established cause

The stable launcher's globally exported `GIT_DIR`/`GIT_WORK_TREE` select the copied
example's repository context even for `git -C SUPPORT_TOOLS rev-parse HEAD`.
Read-only reproduction: support tools normally reports
`d66cf179e7bc4d296362ab7e2e3b344dc3c4f665`; under the launch environment it reports
example revision `70ea683a395a4833aa29ab4de9fbc024c8bcd8c1`. PDK normally reports
`2bbec755dc67ca3db0261c3d6163e15735d66710`. This is repository-context leakage,
not evidence of modified collateral.

Retained failed operation:
`hardcaml_asic_example/.dev/workbench-development/asic-results/stage-preflight/operations/20261105T231057712738Z_bab3dadb/`.
Its bundle is `83cda87c1cecadb5860ccee3661ca31bd8aae317bec00910bb7c1b5f9fabfcd7`.
No live mutation/retry has been performed by this investigation.

## Exclusive slices and acceptance

- Example implementation owner: scope copied-source Git context to Git reads
  directed at the exact private source tree only. The daemon must not export
  repository-selecting Git variables globally. A captured, pinned Git dispatcher
  may inject source context for that explicit root and remove it for collateral/
  other repository probes; no fake output, revision waiver or checkout change.
  Preserve command arguments, real command exit/status and arbitrary non-repository
  environment. Handle inherited contaminating variables. Update setup/launcher,
  tests and explicit refresh instructions; do not refresh the active user store.
- Independent verification owner: reproduce actual collateral probes against the
  user's retained failed bundle read-only, verify expected and observed hashes,
  wrong-revision negative, and isolated real preflight through the installed public
  provider. Metadata probes are permitted; no synthesis/P&R/EDA launch. Verify
  source Plan/emit, both simulation catalog entries and history/config preservation.
- Coordinator: inspect the actual failed command receipts, review repository
  selection/scoping, record remaining blockers and manual same-store recovery.

New generation is adopted only via explicit stopped-daemon `prepare --refresh`.
Retain the stable project/state/history/preferences paths and prior generations;
no requirement to create another user demo session. Active state locks must still
refuse refresh. A genuine mismatch or modified collateral must still reject.

## Execution policy

At most two agents, each2 jobs. All Dune explicit `-j2` or lower, switch5.2.0+ox,
private roots/builds and shared example/ASIC/Workbench locks. Initial EDA allocation0;
no new physical/synthesis execution. Runtime metadata containers, if required by
preflight, must be explicitly bounded and recorded as probes, not a flow run.
No Git add/commit/amend/push/config writes, provider pointer changes, collateral
checkout modifications, original-evidence rewrites or user-daemon restart.

## Actual disposition and same-store recovery

The example now captures a pinned real-Git dispatcher with an exact source-root
mapping. The launcher/router no longer export repository selectors globally;
only a Git process directed at a mapped source root receives the source context.
Collateral Git processes remove inherited repository/index/object/config selectors
and discover their actual repositories. Original arguments, output and exit status
come from real Git. Ambiguous global overrides reject; no revision is fabricated.
The dispatcher checks the captured real-Git executable hash before exec.

All14 example direct/lifecycle tests pass. Independent verification consumed the
actual user's bundle and wrong-probe receipts, then exercised the same installed
stage-preparation library service and the separate public `preflight` CLI in
private captures. Both report `ready:true`, `issues:[]`; two exact revision probes
and seven clean collateral-status probes pass. A correctly rehashed bundle with
the wrong expected revision still rejects. Metadata containers were constrained
to2 CPUs/threads; no synthesis/physical flow was executed. Source Plan/build/emit,
both-suite discovery and ordinary private tests also pass.

Final independent private generation: `412c2dae1a794d0080f0c5544979aac3` in
`/tmp/opencode/development-git-independent-store-01`. Receipts and exact provenance
are in the independent review. This is not reattributed to user generation
`26f0d5e474bc4d45b5fc5859325c162d`; that capture, its failed operations, bundle
and root configuration hashes remain unchanged. The coordinator independently
reproduced the normal-versus-contaminated Git queries and inspected the final
dispatcher and actual installed service gates.

After the owner stops the development daemon, from the example checkout:

```bash
opam exec --switch=5.2.0+ox -- python3 -B scripts/workbench_dev.py prepare \
  --refresh --update-owned-support --git /usr/bin/git
opam exec --switch=5.2.0+ox -- python3 -B scripts/workbench_dev.py daemon
```

Then start `scripts/workbench_dev.py client` in another switch-wrapped terminal,
stage a NEW synthesis intent (`r` or Plan), and launch explicitly. The old consumed
intent/failed workflow is not retried or relabelled. The update verifies baseline
support-file hashes and refuses unknown edits; project/state/history/preferences
paths do not change. Actual synthesis success remains unverified until a flow is
run; this correction establishes successful revision/runtime metadata preparation.
