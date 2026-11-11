# Real fresh-prefix pyramid tests

## Selection and scope

These opt-in tests drive a real production daemon/client and installed ASIC provider.
Each rung copies the selected authored source into a private persistent project,
builds and emits a fresh bundle, then executes the full prefix through its endpoint.
Rungs never resume another rung's checkpoint. Identical emitted bundle bytes are
permitted; each submission still owns a new preparation/workflow and source jobs.

| Root alias | One fresh execution |
| --- | --- |
| `@test-real-elaboration` | Build and emit only; no physical allocation |
| `@test-real-synthesis` | Elaboration → synthesis |
| `@test-real-floorplan` | Elaboration → synthesis → floorplan |
| `@test-real-placement` | Elaboration → synthesis → floorplan → placement |
| `@test-real-cts` | Elaboration → … → CTS |
| `@test-real-routing` | Elaboration → … → routing |
| `@test-real-timing` | Elaboration → … → timing |
| `@test-real-signoff` | Elaboration → … → signoff |
| `@test-real-pyramid` | All eight independent rungs, serially |

**`@runtest`, `@test-contracts`, `@test-local`, and `@all` do not execute these real
flows.** Only the inexpensive runner/registration controls join ordinary tests.
Setting the configuration environment variable does not activate a real alias.
Each explicitly selected real alias reruns via Dune's universe dependency; an old
cached result cannot masquerade as a new real run.

`@test-real-placement` runs just one fresh placement prefix, not separate
elaboration/synthesis/floorplan tests first. The full pyramid repeats earlier stages
across its independent rungs and consequently costs more than a signoff run alone.

## Run an endpoint

From `hardcaml_workbench`, this machine already has a prepared explicit config:

```bash
export HARDCAML_WORKBENCH_REAL_TEST_CONFIG=/home/wayne/devel/jane/hardcaml_asic_example/.dev/workbench-pyramid/real-tests-v2.json

flock /home/wayne/devel/jane/.workbench-build.lock \
  opam exec --switch=5.2.0+ox -- dune build -j2 \
  --build-dir _build_pt8_workbench @test-real-placement
```

Replace the alias with `@test-real-timing` for one fresh timing run. Signoff is
explicitly `@test-real-signoff`. For a large-change qualification, explicitly select
`@test-real-pyramid`. Neither is a default dependency.

Stop other heavy operations first, including owner-triggered flows in another
session. The runner refuses visible competing work/containers rather than stopping
them. Test-owned daemon/client state and results are separate from the main session.

The configured persistent evidence root is:

```text
hardcaml_asic_example/.dev/workbench-pyramid/evidence/
```

Every invocation creates a new `pyramid-<id>/` directory. It retains configuration,
source/tool identities, raw UI/RPC evidence, provider reports, per-rung results and
cleanup records. It does not update the owner's project companions or app selection.

## Configure another installation

Prepare the example's [ordinary main installation](../../hardcaml_asic_example/docs/workbench_main.md)
first. Then use the explicit config helper, choosing a **new output filename**:

```bash
python3 -B test/integration/pyramid/configure.py \
  --example-root /absolute/path/to/hardcaml_asic_example \
  --evidence-root /absolute/path/to/hardcaml_asic_example/.dev/workbench-pyramid/evidence \
  --output /absolute/path/to/hardcaml_asic_example/.dev/workbench-pyramid/new-real-tests.json \
  --flow standard --profile balanced
```

The helper performs no builds, simulations, EDA or daemon startup. It derives paths
from the selected main installation and writes a config plus an input-identity
sidecar, refusing overwrite. Configured inputs include source closure, exact provider,
Dune/Python, SDK identities, toolchain/PDK, environment, flow/profile/assignments,
evidence directory, locks and timeouts. Applications are supplied by Dune's executable
dependencies, so these tests exercise the selected Workbench build, not the owner's
previously installed application pair.

There is no `/tmp` requirement. Source/evidence overlap is allowed only beneath
excluded storage such as `.dev`; ordinary authored-source overlap is rejected.
Private Git metadata and source-scoped Git dispatch preserve provenance without
changing the owner's repository or contaminating toolchain/PDK Git queries.

## Assertions and execution budget

- Exact staged intent, enabled production launch command and allocated-run selection.
  Staging/inspection use supporting typed RPC; submission uses actual PTY input.
- Completed source build/emission and exact bundle/plan identity. Different JSON
  formatting is permitted only when complete decoded values agree; each file keeps
  its own independently checked byte digest.
- Exact schema4 ordered prefix, occurrences/publications/checkpoints and provider-
  validated report. Selected stages complete; every successor is not requested.
- Timing binds its own frozen analysis source, producer and digest. Analysis
  completion is distinct from the reported timing-goal verdict.
- Signoff means the selected physical prefix completed. It does **not** invoke
  Finalize/acceptance: acceptance and external postcheck remain `not_evaluated`.
- Failure stops the aggregate; later rungs remain `not_run`. Cancellation/cleanup
  targets only exact test-owned processes/containers. Unresolved cleanup leaves a
  durable interlock; investigate its receipt rather than deleting it to force a run.

The runner serializes via a shared external execution lock, in addition to Dune's
`real-eda` lock. Its source build uses the separate example build lock. Do not set
the source build lock equal to an outer flock already held by Dune's caller.

Source preparation records the production requested `-j6` and the test's executed
`-j2` override. Normal named EDA retains its configured six-worker transport. These
settings and observed commands are not a kernel-enforced aggregate task cap. Account
for all other sessions under the owner's global20 budget; do not combine real EDA
aliases with unrelated expensive build/test aliases in one invocation.

Outer endpoint deadlines are configurable. Defaults are 900 seconds for elaboration,
1800 synthesis, 2700 floorplan, 3600 placement/CTS, 5400 routing/timing and 7200 signoff.
They are time limits, not measured expected runtimes. The full pyramid uses each
rung's own budget serially. Provider per-call stage timeout is configured separately.

## Actual verification — 2026-11-11

**Implemented:** all eight endpoint selectors and the serial pyramid.
**Actually executed here:** real Elaboration and real Synthesis only.
**Not yet executed in this runner:** Floorplan, Placement, CTS, Routing, Timing,
Signoff, or the full pyramid. Registration is not evidence that those runs passed.

- 28 configuration/registration/orchestration controls and15 runner self-tests pass.
- Actual missing-config `@test-real-synthesis` fails before provider/process launch.
- Default exclusion was independently checked even with a real config selected.
- Real Elaboration passed through the production client/server, with no physical run.
- Corrected real `@test-real-synthesis` passed uninterrupted with66 assertions:
  run `9b29379d2abe42a3aa3a689d2d5afd46`, synthesis11.515209 seconds,673 mapped cells,
  area13,041.6048µm², zero recorded synthesis errors/latches/unmapped cells, two lint
  warnings, one checkpoint, no successors/finalizations, and successful cleanup.

Under the evidence root above:

| Receipt | SHA256 |
| --- | --- |
| `pyramid-d571d445dbb94e7a820eeaa027d9fbb7/result.json` (Elaboration) | `8e4dbdba90b074c30e557815fe8628cce5643cdc92fc66ed1e54dfce8ffeb00c` |
| `pyramid-73358502a42e4cf08f369173efa93026/result.json` (Synthesis) | `ab9f5f5911fc82c2d32abe2664dd03582829326decd93bd2c3c0343f6e18c86b` |

The preceding real synthesis attempt completed its producer but failed an overly
strict JSON-byte comparison in the harness. Its failed receipt remains unchanged;
a separate read-only verification and the final uninterrupted rerun establish the
correction. `runner.py --verify-retained` writes a separate verification receipt;
it never relabels or resubmits the original attempt.
