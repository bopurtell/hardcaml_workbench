# Independent collateral Git-context verification

2026-11-05. **Bounded verification passes. No production edits or EDA execution.**
This review exercises the example owner's scoped Git correction through real
consumers and the immutable installed ASIC provider. It does not adopt a new
generation in the user's live store. Scope/ownership:
[recovery plan](development_git_context_recovery.md).

## Historical failure and actual authority

Read the retained operation directly:

```text
hardcaml_asic_example/.dev/workbench-development/asic-results/stage-preflight/operations/20261105T231057712738Z_bab3dadb/operation.json
```

Its `bundle` names the exact object
`83cda87c1cecadb5860ccee3661ca31bd8aae317bec00910bb7c1b5f9fabfcd7.550387.0252b0e3`.
The authority is that object's `manifest.json.requested_tools`, not a newly
inferred baseline. Read-only probes give:

| Probe | Expected / normal HEAD | With retained global Git selection |
|---|---|---|
| Support tools | `d66cf179e7bc4d296362ab7e2e3b344dc3c4f665` | `70ea683a395a4833aa29ab4de9fbc024c8bcd8c1` |
| PDK | `2bbec755dc67ca3db0261c3d6163e15735d66710` | `70ea683a395a4833aa29ab4de9fbc024c8bcd8c1` |

The historical `collateral/.../probe-1.json` records `/usr/bin/git -C
.../_flow_tools/tt rev-parse HEAD`, successful exit0, and the raw stdout is
`70ea683a395a4833aa29ab4de9fbc024c8bcd8c1\n`. This is actual wrong repository
selection, not Git failing to execute. Normal status for all seven declared
collateral references is empty. Contaminated status exits nonzero with an
outside-repository diagnostic; empty stdout alone would not prove cleanliness.
The independent harness records both stdout and stderr/exit status.

Raw historical copies, requested tools, real commands, and hashes:
`/tmp/opencode/development-git-independent-baseline-02/receipt.json`.

## Corrected private generation and consumer checks

Private store: `/tmp/opencode/development-git-independent-store-01`.
Final generation: `412c2dae1a794d0080f0c5544979aac3`.
It uses the same immutable ASIC installation
`ee3af8de9f83418b9afed9c67e473e3c` and the stable generation's copied SDK.
The initial capture was deliberately started with inherited `GIT_DIR`,
`GIT_WORK_TREE`, `GIT_COMMON_DIR`, and an invalid `GIT_INDEX_FILE`.

Verified independently:

- Capture builds with explicit Dune `-j2`; exported daemon environment has no
  global `GIT_DIR` or `GIT_WORK_TREE`.
- Captured dispatcher invokes actual pinned Git: exact private project root,
  nested child, malformed attached `-Cpath` (real Git error), repeated relative/absolute `-C` returning to
  the exact root, support repository and PDK repository. Nested source children
  do not receive the exact-root source override.
- Real revision commands remain correct with inherited repository selectors
  and `GIT_CONFIG_COUNT`/key/value contamination.
- Captured project `flow plan` and elaboration-only `flow emit` pass under that
  contamination. Emission produces the **same** original bundle identity
  `83cda87c...` and plan identity `bce48c36...`; expected revisions were not altered.
- Captured composite discovery contains `controlled-fifo` and
  `pt8-memory-workloads`. Native private Workbench Discover/Plan also pass.
- Private ordinary authored `test`, `asic_test`, and `timing` tests pass at2 jobs.
- Final receipt audit checks the captured launcher/helper/router bytes equal the
  owner's current implementation bytes at review completion.

Consumer receipt:
`/tmp/opencode/development-git-consumers-independent-03/receipt.json`.
Native receipt:
`/tmp/opencode/development-git-native-independent-02/receipt.json`.
Initial capture `6423bae4ae6a451b970e832bb345623d` remains retained. The final
private refresh/build receipt is under the private store's
`receipts/412c2dae1a794d0080f0c5544979aac3/`.

## Installed stage preparation and public metadata preflight

The installed public `stages --help` and its delegation code were inspected.
There is **no prepare-only option**: public `stages` directly calls execution
after successful preparation. Therefore this verification calls the actual
installed `hardcaml_asic.execution` `Stage_preparation.prepare` service from a
minimal independent consumer, which never calls `execute`. This is the same
service that produced the user's failed operation. The separately callable
installed public CLI `preflight` is also exercised successfully. This distinction
is intentional and should not be described as a public `stages` execution.

All bundle members are exact copies into new private paths. Preparation allocates
new workspaces/checkpoint stores/evidence, uses the real support/PDK checkouts,
and runs real installed host/container metadata payloads. Both the installed
stage service and public CLI return `ready: true`, `issues: []` with the captured
scoped helper and inherited contaminating selectors.

The stage receipt contains two actual revision probes matching `requested_tools`
and seven successful status probes with empty raw stdout/stderr. All seven
external-reference hashes are retained and valid. Host/container runtime policy,
image and resource checks pass, including actual pinned image
`sha256:d109140b8f17fc54f4fca998beb8124f4949404ec52e339eebd2250854a18b5a`.

Negative controls:

1. Actual installed stage preparation with real Git and historical global
   selection rejects `collateral revision mismatch: support_tools_revision`.
2. A private bundle copy changes expected support revision to40 zeroes, recomputes
   the order-sensitive manifest identity, then passes the installed library's
   `Bundle.verify_manifest_identity` before preparation. It still rejects the
   collateral revision. No Git init/commit/config mutation or original checkout
   mutation is involved.

Runtime allocation: EDA0. The stage service hardcodes workers6, and public
preflight requests workers20 for this bundle. A private fail-closed Docker adapter
allows only the metadata inline payload and Docker metadata/cleanup commands,
records original and actual argv, and changes the actual CPU quota/thread settings
to2. It delegates all output/status to real Docker. No flow command is admitted.
Both real metadata container invocations in the final run use `--cpus=2`; these
are metadata inspections, not two flow runs or evidence of synthesis success.

Final stage/public receipt:
`/tmp/opencode/development-git-stage-independent-06/receipt.json`.
The exact stage report path is recorded in:
`/tmp/opencode/development-git-receipts-independent-03/receipt.json`.
Raw collateral command receipts are under that stage operation's `collateral/`;
`docker.jsonl` records requested versus actually executed allocation arguments.

## Preservation, harness corrections, and remaining scope

Final read-only audit:
`/tmp/opencode/development-git-independent-final-02/receipt.json`.
It compares complete inventories of the failed operation, original emitted bundle,
and selected immutable capture, plus original root configs and selected manifest,
against the before-probe inventory. All hashes match. The active user store was
not refreshed/retried and its daemon was not stopped or restarted.

Retained failed harness attempts are not acceptance evidence: baseline-01 initially
asserted contaminated status must succeed; consumers-01 used unsupported emit
`--output` (correct option `--results-root`); stage-03 used unsupported public
preflight `--bundle` (bundle is positional). Their original receipts remain.
The receipt audit then detected B's final helper change after the initial private
capture. Only the private store was explicitly refreshed with
`--refresh --update-owned-support`; consumer, native, stage, public-preflight,
provenance and preservation gates were rerun against the final matching bytes.
The metadata adapter was also tightened to explicitly supply all three two-thread
variables when the public service's workers20 default omitted them.

No remaining readiness failure was observed in the corrected metadata/preparation
checks. The live user generation still needs explicit stopped-daemon refresh to
adopt the correction, under the owner's migration instructions. Full synthesis,
physical stages, and public `stages` execution are **unverified** here. Successful
metadata/preparation does not establish synthesis completion or correctness.
