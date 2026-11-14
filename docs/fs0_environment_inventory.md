# FS0 environment and acceptance inventory

**Historical pre-integration inventory.** Executable selections, blockers and
requested updates below describe the 2026-10-15 audit, not current setup
instructions. FS0 integration and installed checks subsequently passed; current
provider adoption and completed FS1 scope are in [FS1 investigation](fs1_investigation.md).
Original hashes, checkout observations and audit results are retained unchanged.

Read-only audit, 2026-10-15. Only this new inventory was written. No Dune,
build, EDA, provisioning, installation or mutative Git command was executed.
Public subprocesses were limited to provider version/observation description/
historical inspection and project flow list/describe. File metadata/hashes,
read-only Git status/log/diff and an installed-opam-package listing were checked.

## Checkout state and provenance

| Checkout | Observed HEAD | State at inspection |
| --- | --- | --- |
| `/home/wayne/devel/jane/hardcaml_asic` | `031498db573949793e980f4d645c343e6b705915` | `main`, clean |
| `/home/wayne/devel/jane/hardcaml_asic_example` | `ae6fa46caabfbd077a81152421a5cb8ecb5ae4dc` | `main`, clean |
| `/home/wayne/devel/jane/silver` | `e99221b81807648bc8ee66f8ad1e3b9d1235add3` | `oxcaml`, existing modified terminal files and untracked FS0 integration files |

Workbench's existing changes include `terminal/{dune,main.ml}`, ASIC adapter,
backend/process/public/service files and tests, workspace service/protocol/tests,
project ASIC configuration, terminal host files and FS0 documentation. These were
preserved. Status is an observation, not an ownership or frozen-snapshot claim.

The consumer dependency record `../hardcaml_asic_example/asic-dependency.json`
still records provider revision `1714764859274f80a9f5ad207421a04601824e99`.
That record is distinct from both current provider HEAD and installed captures.

### Normal installed selection

`/home/wayne/devel/jane/hardcaml_asic_example/.dev/asic/current` resolves to:

```text
/home/wayne/devel/jane/hardcaml_asic_example/.dev/asic/generations/3c70c76700764a58974ef7d969adba36
```

Its `receipt.json` says development mode, observed base revision
`ad290d825272b588eb0fe0202e84ce407ae221f5`, snapshot SHA-256
`4d804d7f454a940bd93a9a5b72192922c901011e2f0d18e3413ac5c095f78f3f`,
refresh time `2026-10-15T08:35:53.786253+00:00`, and
`differs_from_recorded_snapshot=true`. This is explicitly a local receipt, not a
P6.5 source stamp. There are 21 retained generation directories. The older
`3cd135a1d9e14525a53789eb646a69ae` generation mentioned in synthesis evidence still
exists, but is no longer current. Do not infer current selection from old docs.

## Ready executable pair

Use the explicit retained real-synthesis pair for reproducible FS0 integration:

```sh
SOURCE=/home/wayne/devel/jane/hardcaml_asic_example
PROJECT="$SOURCE/_build_namedflow_real/default/bin/project.exe"
PROVIDER=/tmp/opencode/namedflow-real-20261015/provider/bin/hardcaml-asic-flow
TOOLS="$SOURCE/_flow_tools"
```

Both files exist and are executable. Current SHA-256:

| Artifact | SHA-256 |
| --- | --- |
| `$PROVIDER` | `2c6604d355b819ee5cec8f731b4ba810ea9415ebf56f24ebac798a8d346bcdd5` |
| `$PROJECT` | `5e8bdaab7dc4a5f5dbda8dae22a3e9946c4db09bf16951381d125a418d3a49b1` |

The provider's receipt records a fresh dereferenced-hardlink installation from
`@install`, with captured source checksum
`a12a763f842f283ab31649e8ded40786b304277f8e572d0f68e500e1fdc1686d`.
The retained source expectation records base
`0d04baeb5c6538412e3dfb173422b4aa5e174544`; its per-file capture includes work
that was not necessarily committed at capture time. Do not equate this capture
with today's clean HEAD. Provenance records are:

```text
/tmp/opencode/namedflow-real-20261015/provider/receipt.json
/tmp/opencode/namedflow-real-20261015/source-expectation.json
/tmp/opencode/namedflow-real-20261015/consumer-source-expectation.json
/tmp/opencode/namedflow-real-20261015/commands.jsonl
```

The provider at
`/tmp/opencode/namedflow-race-provider-v2/bin/hardcaml-asic-flow` also exists,
passes version metadata, and has the identical executable hash. Its documented
consumer is `$SOURCE/_build_namedflow_race/default/bin/project.exe` (present,
hash `891fd3fd208bc234a00bb3cbf4f8309a72eb95f6ea83cdd8f92ef3355d7fb7bb`).
The real pair has direct retained physical-synthesis evidence, so it is preferred.

Other existing prebuilt consumers: `_build_delivery` and `_build_headless` have
the same executable hash as `_build_namedflow_real`; normal `_build` exists with
hash `460ae9e0d282cd0fcc7dbb3222b571166210a47523a98eeb38cf84562391ef47`.
Only the recommended pair's list/describe was executed in this audit; presence
alone is not validation of the other pairings.

## Public API/capabilities verified now

The real prefix, race-v2 prefix and normal current generation all return:

```json
{"tool":"hardcaml-asic-flow","identity_schema":1,"package_version":"0.1.0",
 "supported_record_schemas":[1],
 "cli_contract":{"version":4,"capabilities":{"namedflow1":true}}}
```

All report `source.stamped=false`, null revision/inventory/artifact match and
unknown source state. Package version and local capture receipts are not a
verified source-to-linked-artifact stamp.

For the recommended provider:

```text
module_dir = /tmp/opencode/namedflow-real-20261015/provider/lib/hardcaml_asic/flow/hardcaml_asic_flow
data_dir   = <module_dir>/data
lock       = <data_dir>/toolchain.lock (present)
```

Capabilities include JSON `report`, `stages`, `checkpoint-inspect`, observation
`describe`, `inspect`, `read-updates`, `watch`, `finalize` and
`finalization-inspect`; JSONL `stages`, `finalize`, `observation watch`; flushed
records, observation default-on, writer schema 2/read schemas 1 and 2, producer
timestamps and monotonic elapsed time. Watch interval defaults to 0.5 seconds;
reconnect requires stream ID and after-cursor together. Watch exits: terminal 0,
lost/unknown writer 3, query error 2, reader interrupt 130. A terminal exit does
not establish successful execution or acceptance.

Public `observation describe --json` confirms read-only readers, no resume,
no request idempotency, no store-wide journal, no fsync durability, path-bound
retention, observation response schema 2, allocation/error-terminal schema 1,
and a validated absolute `execution_file` or null. Consumers must use that returned
file, not reconstruct a filename. `collect --json` writes results; it is not a
read-only audit command.

The prebuilt project returned `hardcaml-asic.flow-list` and
`hardcaml-asic.flow-describe`, schema 1, with:

| Flow/profile | Settings |
| --- | --- |
| `standard/balanced` (default pair) | `SYNTH_STRATEGY="AREA 0"`, `SYNTH_ABC_BUFFERING=false` |
| `standard/synth_delay` | `SYNTH_STRATEGY="DELAY 1"`, `SYNTH_ABC_BUFFERING=false` |

Recipe `librelane.classic.v1`, fresh input, complete prefixes through synthesis,
floorplan, placement, cts, routing or signoff. No continuation or arbitrary
overrides. Only the declared enum/boolean keys are configurable. Profile requires
flow; unknown IDs error; flow alone selects its default profile.

Installed public OCaml interfaces are under the recommended prefix's
`lib/hardcaml_asic/`: `project.mli`, `resolved_flow.mli`, `flow_spec.mli`,
`methodology_plan.mli`, `flow_recipe.mli`. Project exposes checked render/emission
APIs; Flow_spec supplies catalog/list/describe/selection codecs. Workbench consumes
the public executable boundary rather than linking this library. Wire lineage:
catalog/list/describe/methodology plan/snapshot/reference v1; physical recipe v3;
observation readers/events v2; report/historical methodology v1. Successful Runner
summary has no outer schema discriminator.

## Exact tools and limits

```text
toolchain     /home/wayne/devel/jane/hardcaml_asic_example/_flow_tools
host Python   /home/wayne/devel/jane/hardcaml_asic_example/_flow_tools/.venv/bin/python
support tools /home/wayne/devel/jane/hardcaml_asic_example/_flow_tools/tt
PDK root      /home/wayne/devel/jane/hardcaml_asic_example/_flow_tools/pdk
Docker        /usr/bin/docker
client Python /usr/bin/python3
taskset       /usr/bin/taskset
```

Roots exist and Python is executable. `pyvenv.cfg` records 3.11.17; its resolved
binary is under `_flow_tools/python/cpython-3.11.17-20261009-x86_64-unknown-linux-gnu-install_only_stripped-89db7607ebadb77a64709d159b86555d995368ec385a2ab33b00477790c543b0/python/bin/python3.11`.
Host Yosys is present at `/usr/bin/yosys`; host OpenROAD is absent from PATH.
The intended backend is the provisioned Docker runtime, not those host tools.
No Docker/EDA/runtime readiness probe was executed during this audit.

Installed lock pins LibreLane `3.1.0.dev3`, support-tools revision
`da63c9927411e3aca350977d653d24bbf5bca972`, PDK revision
`2bbec755dc67ca3db0261c3d6163e15735d66710`, image reference
`ghcr.io/librelane/librelane:3.1.0.dev3`. Prior actual runs recorded image
`sha256:d109140b8f17fc54f4fca998beb8124f4949404ec52e339eebd2250854a18b5a`
and container Python 3.13.13. These are retained evidence, not a new image probe.

Installed `execution/runtime/execution_transport.ml:127,132,155` explicitly sets
Docker `--cpus=20`, `_OPENLANE_MAX_CORES=20`, `OPENROAD_THREADS=20`,
`OMP_NUM_THREADS=20`, including execution/publication transport; metadata containers
also have the CPU quota. Installed coarse runner sets the same thread environment.
Postcheck sets tool threads to 20 and uses a host affinity cap of 20. Prior actual
transport evidence is retained in `balanced-transport-evidence.json`,
`synth_delay-transport-evidence.json` and `lineage.json` under the real evidence root.

**Serialize acceptance profiles and do not overlap a build or another EDA job.**
The provider's quota is per container, not a machine-wide shared budget. Workbench
currently allows two ASIC launchers, so that concurrency cap alone does not enforce
a 20-core aggregate limit. Host affinity currently permits CPUs 0–31; the command
below restricts host descendants to 0–19. Docker daemon-created containers do not
inherit client taskset affinity: their own 20-CPU quota is the relevant backend
limit. CPU quota is not a Docker cpuset restriction. No explicit container memory
limit was found in this transport. A strict shared host+container aggregate ceiling
would need owner-managed shared cgroup/container scheduling beyond these settings.

## Recommended future synthesis command (not executed)

Run from any directory using the absolute variables above. Use a fresh result/cache
namespace per acceptance session; keep cache outside the provider result store.
This client does discovery/preview/identity comparison before launching the same
selection. It does not invoke Dune or install dependencies.

```sh
AUDIT_ROOT="$(mktemp -d /tmp/opencode/fs0-synthesis.XXXXXXXX)"
for PROFILE in balanced synth_delay; do
  /usr/bin/taskset -c 0-19 /usr/bin/env \
    OMP_NUM_THREADS=20 OPENROAD_THREADS=20 _OPENLANE_MAX_CORES=20 \
    /usr/bin/python3 -B "$SOURCE/scripts/headless_flow.py" \
      --project "$PROJECT" --provider "$PROVIDER" --source-root "$SOURCE" \
      --results-root "$AUDIT_ROOT/$PROFILE-results" --toolchain "$TOOLS" \
      --python "$TOOLS/.venv/bin/python" --support-tools "$TOOLS/tt" \
      --pdk-root "$TOOLS/pdk" \
      --flow standard --profile "$PROFILE" --endpoint synthesis \
      --stage-timeout 600 --timeout 1800 \
      --receipt "$AUDIT_ROOT/$PROFILE-receipt.json" || break
done
```

The provider budget is 600 seconds per segment/publication, not a whole-flow
deadline. The client budget is 1800 seconds with owned-launcher cleanup. There is
no CLI `-j20` for this flow; Dune job limits and EDA thread controls are separate.
For reconnect, the headless client writes its cache: use a new owned copy of a
receipt if preserving the original. Public provider inspect/read-updates/report
are the appropriate read-only historical queries.

## Existing actual evidence versus FS0 acceptance

`../hardcaml_asic/docs/development/project-flow-catalog-progress.md:1113` and
`../hardcaml_asic/evidence/namedflow/20261015-real-synthesis.json` document actual
two-profile synthesis with the recommended pair. Raw evidence and
`verified-summary.json` are under `/tmp/opencode/namedflow-real-20261015`.
Recorded counts are 673 balanced and 685 delay, with completed execution and
available identity-matched reports. Acceptance/external postcheck remain
`not_evaluated`; this is synthesis-only evidence.

This audit independently ran public inspect on:

```text
attempt /tmp/opencode/namedflow-real-20261015/balanced-results/observations/20261015T040209621884Z_92f042b3
stream  92f042b36d7444f3952901bd419ee4f0
cursor  7
execution_file /tmp/opencode/namedflow-real-20261015/balanced-results/synthesis-282074-021204d728d6db21247aaeef2319376a/execution-92f042b36d7444f3952901bd419ee4f0.json
```

It returns final, writer inactive, completed outcome/exit 0, synthesis occurrence
completed, validated readable execution reference and acceptance not evaluated.
The coarse observation `physical_completion=not_recorded` must not overwrite the
detailed stage report's synthesis completion. Historical checkpoint closure needs
retained external PDK collateral; it is not toolchain-free relocation.

This audit does not establish a Workbench end-to-end acceptance pass. FS0 still
needs the parent integration, fixture tests, RPC launches for both profiles and
restart/reopen of their exact registered references.

## Workbench script/test side effects and parent-owned updates

| Location | Behavior / necessary update |
| --- | --- |
| `scripts/with-switch.sh` | Lists existing switches and delegates to `opam exec`; no dependency install, no automatic Dune bound. Default switch `5.2.0+ox`. |
| `scripts/test-fixture.sh:21–24,35,39` | Copies fixture to mktemp, builds/runtests/executes drivers there and removes scratch on exit. Add `-j20` to build, runtest and all three exec calls. No Git commands or dependency installation. |
| `scripts/test-native-application.sh:84–91` | Builds Workbench in live checkout; installs Workbench itself to temporary prefix; copies/builds/tests/cleans fixtures, starts/stops daemons and writes runtime/log/cache files. No opam dependency install or live-Git mutation. Add `-j20` to build/install and fixture build/runtest. Clean has no build-job workload. App-driven nested builds need adapter updates below. |
| `scripts/capture-terminal-baseline.sh:29` | Always builds terminal, even `--check`; add `-j20`. Default mode deletes/regenerates tracked captures; `--check` renders to temporary directory and diffs. Neither is read-only with respect to build outputs. |
| `scripts/test-terminal-resize.py` | Drives supplied client via PTY; native test supplies copied fixtures/runtime. Not an environment-only metadata check. |
| `adapters/dune_adapter.ml:149,151` | Runtime build/test argv have no `-j20`; parent must bound both. Top-level `dune build -j20` does not bound later independent child Dune invocations. |
| `adapters/project_driver_adapter.ml:9,25` | Both discovery and RTL generation use `dune exec`, which can build. Add `-j20` to both generated argv and update adapter expectations. |
| `backend/test/test_service.ml:46–58,1094–1103,1364–1385` | Git init/config/add/commit occurs only in an owned temporary project created by `with_temp_tree`, not the live checkout; cleanup removes it. No dependency install. Some service opening probes Dune, so this suite is outside a no-Dune audit. |
| `backend/test/asic/{test_asic.ml,fake_provider.py}` | Own temporary project/cache and injected Python public-provider fixture. Writes fake results/call logs; no EDA, Dune-at-runtime, Git or dependency install. Building/running the alias is still not read-only. |
| `backend/test/workspace/test_workspace.ml` | Pure workspace transitions plus temporary persistence tests, not live Git/dependency installation. |

The new ASIC adapter uses explicit project/provider executables with environment
prefixing and no runtime Dune. Optional stage timeout forwards to project `flow
run --timeout`. Workbench state must be physically separate from provider results.
See `docs/fs0_provider_integration.md` for API/configuration and cache limits.

Parent integration blocker observed: `backend/dune` does not yet declare `yojson`.
The existing switch has installed `yojson`, `core`, `async`, `cryptokit`; no install
is needed for that addition. After wiring, and only in an authorized build phase,
run focused checks serially, for example:

```sh
./scripts/with-switch.sh dune build -j20 @backend/test/asic/runtest
./scripts/with-switch.sh dune build -j20 @backend/test/workspace/runtest
./scripts/with-switch.sh dune build -j20 @adapters/test/runtest
./scripts/with-switch.sh dune build -j20 @backend/test/runtest
```

After parent-owned `-j20` edits, fixture/native/baseline-check scripts are suitable
for their documented mutating test phase, not for this read-only audit. Existing
formatting-guide build examples also omit `-j20`; parent should bound those when
following them. No script or adapter was changed by this inventory.

### Safe public metadata/read-only commands

With the absolute variables above:

```sh
"$PROVIDER" --version --json
"$PROJECT" flow list --json
"$PROJECT" flow describe --flow standard --json
"$PROJECT" flow plan --flow standard --profile balanced --endpoint synthesis \
  --source-root "$SOURCE" --json
"$PROVIDER" observation describe --json
"$PROVIDER" observation inspect "$ATTEMPT" --json
"$PROVIDER" observation read-updates "$ATTEMPT" --stream-id "$STREAM" --after 0 --json
"$PROVIDER" report "$EXACT_RETURNED_EXECUTION_FILE" --json
```

Plan reads declared source/Git, performs no tool probes and creates no result
directories; it was inspected in source but not executed here. Use stdout rather
than redirection when requiring a strictly read-only command. The last three
commands require explicit returned references, not guessed store paths. Report
may validate substantial retained checkpoint/PDK closure but launches no EDA.
