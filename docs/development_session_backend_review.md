# A independent review of B's development-session backend

**Final disposition, 2026-11-05: PASS — closure finding resolved; no open blocker
in A's backend-review scope.** Unchanged original runner38/38 and independent
migration recheck24/24 pass. Final stable generation
`26f0d5e474bc4d45b5fc5859325c162d` was inspected read-only. See the final recheck
section below; the original finding, reviewed hashes and failed receipt are
preserved as historical evidence.

2026-11-05. Reviewed the corrected regular-config implementation after B's10-test
pass. **37 of38 independent checks pass; one confirmed medium development-source
closure gap remains. No additional launcher/router runtime blocker reproduced.**

This review owns only this document and new verification files under
`reviewdocs/backend_review/`. B production/tests, C probes/reviews, example/root
configs, user-selected generation, prior evidence and live processes were not
edited. No Git commands, functional simulation or EDA were run.

## Remaining finding: editable development project omits existing test sources

**Medium, confirmed; the scope question already raised by C is still open.**

`hardcaml_asic_example/simulation/workbench_provider.py:19-21` defines the source
copy/capture closure with `SOURCE_DIRS`/`SOURCE_FILES`. It omits existing directories:

```text
test/
asic_test/
timing/
named_timing/
physical_timing/
```

`scripts/workbench_dev.py:226-235,325,457-460` uses that inventory for initial
editable-project copying and later immutable captures. A fresh real preparation
therefore lacks those directories both in its editable `project/` and captured
source inventory. In particular the actual example's `test/fifo_test.ml`, its Dune
test stanza, and `asic_test/{catalog,resolution,wrapper}_test.ml` are absent.
This prevents the promised source-complete everyday development root from carrying
its existing project tests. It does **not** imply that the two advertised frozen
simulation programs fail: their relevant-source edit guards and discovery passed.

Reproduction is retained in:

- `/tmp/opencode/development-backend-a-review-01/receipt.json`,
  `source_closure_omissions` and the sole failed check.
- Fixed private project:
  `/tmp/opencode/development-backend-a-review-01/store/project`.
- Initial generation `a97e2df1406342e68a04d9d96f7f4cab`; refreshed generation
  `a76d51c70bd34dd5939d09621e96ab2c`. Both retain this incomplete closure.

B/coordinator should complete the initial source-copy inventory and specify an
explicit, non-overwriting addition of missing directories for already editable
projects. Merely expanding the inventory then blindly recopying the owner checkout
would break the existing preserve-edits contract. No such migration was attempted
by A. Recheck ordinary project-test discovery after the closure is completed.

## Independent probes and actual results

Primary receipt:
`/tmp/opencode/development-backend-a-review-01/receipt.json`.
The runner completed and intentionally exits1 for the source-closure finding;
this is not an interrupted/harness-failure run.

### Actual prepare, app capture and native Discover — PASS

- Prepared a new independent `--store` with B's normal source build and the actual
  SDK/ASIC capture. No config replacement workaround was used.
- All three installed configs are regular files and hash-match the selected
  generation. Both copied apps hash-match the prebuilt pair while holding the
  Workbench build lock, and captured app files are read-only.
- Started only that private store's foreground daemon through the real launcher.
  Submitted real `/api/v1/open-project` and `/api/v1/simulation` Discover/Get.
- Native discovery has no error and advertises exactly `controlled-fifo`, then
  `pt8-memory-workloads`. Its suites equal the full original child catalogs,
  including cases, labels, parameters/defaults and seeds.
- Full request/response evidence: `native-discover.json`, direct child discovery
  stdout/stderr and `daemon.{stdout,stderr}` in the evidence directory.
- Idempotent prepare works while that daemon is active; refresh refuses without
  changing selection. Only the test-owned daemon was explicitly stopped.

Captured app pair in both real preparations:

| App | SHA256 |
| --- | --- |
| daemon | `ec0108fd3ae65ac8bc8113462bfc1eb4dcdcbecf6410c144fbc982113f495a38` |
| client | `896cee9b6546be5c5d7fcd132306a55cf33cbc43d1c25edbd7cea9c467bd7a42` |

The client is A's MIME/clipped-label corrected app. The user's default store was
not refreshed or launched by this review.

### Publication, ownership, interruption and lifetime locks — PASS

- Both state and discovery lifetime locks independently reject refresh before a
  capture receipt is allocated. The live launcher shared setup lock additionally
  fences refresh/start for its daemon lifetime.
- Editing each installed config in turn causes explicit refresh refusal, preserving
  the exact unknown edit, selected generation and receipts. This includes the
  preparation config, which is last in publication order.
- A synthetic ordinary publication failure after the first actual replacement
  automatically restores the old configs and selection.
- Separate private state-machine fixtures interrupt publication after config1,
  config2, config3 and after selecting the new generation. These use B's actual
  fsynced journal/replacement/recovery functions, with a `BaseException` injected at
  the checkpoint; they are not runtime provider/app generations and not a claim of
  actual machine power-loss testing.
- Every interrupted state fences selection reads with an explicit refresh/recovery
  instruction. An unknown edit to the last config causes recovery to refuse before
  **any** config/selection rollback. The edited bytes and selection stay untouched.
- A third-party selection during an interrupted publication is likewise refused.
- Restoring the known interrupted bytes/selection in the fixture and explicitly
  invoking recovery restores every old config and selection, verifies them, and
  moves the journal into the rollback receipt.

Fixture journals/rollback receipts remain in `publication-{0,1,2,3,4}/` beneath the
private evidence directory. No B module or production file was patched on disk;
fault injection is process-local to these explicitly synthetic fixtures.

### Exact suite routing and edited-source freshness — PASS

- Both captured router routes were independently exercised with a clearly labelled
  inspection-only child, never a hardware simulator. Each preserves PID, process
  group, every original FS2 argument (including paths containing spaces) and request
  byte digest. Empty event/artifact paths remain untouched.
- Edited actual private `lib/controlled_fifo.ml` and `variants/variant_memory.ml`
  separately. Each actual captured router rejects its stale suite before child
  events/artifacts, with the actionable `prepare --refresh` diagnostic.
- Restoring the bytes restores the expected inventory. No source freshness
  failure was reproduced for the actual runtime dependencies inspected here.
- Existing B invalid-discovery/selection and cancellation sources were reviewed;
  this review does not broaden them into an authentication/cache-security audit.

### Actual failed/successful refresh preservation — PASS

- Made a new harmless edit only in the private project's FIFO source.
- Explicit refresh with `/bin/false` as the build command fails and retains exact
  prior selection, edited source and all existing state/client-state bytes.
- A subsequent real two-job refresh captures that edited private file, keeps the
  fixed project root, retains all old immutable-generation files byte-exact, and
  preserves the entire state/client-state snapshot.
- Own state here includes the real native-open/discovery project state plus explicit
  history/artifact and preference sentinels. It is **not** a newly executed FIFO/PT8
  attempt history or an actual saved Stacked UI preference. C independently covers
  those real histories/preferences; its retained refresh02 receipt reports72 durable
  state files and2 preference files preserved across repeat/failed/successful refresh.
  A read that receipt without rerunning or mutating C's store.

### Cancellation: actual production FS2 acceptance of retained prefix — PASS

New `cancellation_prefix_probe.ml` feeds B's retained real cancellation streams
through the **production event codec and `Simulation_reducer`**, then finishes with
`cancelled=true`. Both prefixes have no diagnostic and normalize to lifecycle
Cancelled / outcome Incomplete without a forbidden provider terminal constructor:

- FIFO:2 events, `Started`, `Case_started seeded`.
- PT8:3 events, `Started`, `Case_started exact256`, emit-stage Progress.

Sources are the unchanged
`/tmp/opencode/workbench-dev-b-t8l6wa8a/store/test-evidence/cancel-*/events.sexp`.
Probe stdout is retained in A's `cancel-prefix-*.stdout`. A did not launch new
hardware work or repeat B's process-kill/reaping test. Child reaping itself remains
B's retained direct-test evidence, not a new independent OS-reaping claim.

## Exact commands and preservation

From `/home/wayne/devel/jane/silver`:

```sh
flock /tmp/opencode/workbench-pt8-build.lock \
  opam exec --switch=5.2.0+ox -- dune build \
  --root /home/wayne/devel/jane/hardcaml_workbench \
  --build-dir _build_pt8_workbench -j2 \
  reviewdocs/backend_review/cancellation_prefix_probe.exe

opam exec --switch=5.2.0+ox -- python3 -B reviewdocs/backend_review/run.py \
  --evidence /tmp/opencode/development-backend-a-review-01 \
  --cancel-probe /home/wayne/devel/jane/silver/_build_pt8_workbench/default/reviewdocs/backend_review/cancellation_prefix_probe.exe
```

The evidence path must be new. B's invoked prepare/refresh internally uses explicit
source root/private output, `-j2` and the shared example lock; app capture uses the
shared Workbench lock. No B production/test suite was edited or rerun wholesale.

Before/after hashes in A's receipt prove unchanged root configs, pre-existing
modified `asic/project.ml`/`acceptance/dune`, B launcher/router/test source, and the
user store's manifest/config selection. Reviewed source hashes:

| Source | SHA256 |
| --- | --- |
| `scripts/workbench_dev.py` | `dd4183bed01d552ca7ee0faaff6b5afd26215fbf58359f5aa1086d5371ba41c7` |
| `simulation/workbench_provider.py` | `eebd560025b972c947e0911342f068e970f5d0eec9d96a9c0effe3b799fb54e5` |
| B `scripts/test_workbench_dev.py` | `9084bd1e1c2844b4ae74d83ce35cbdcc4927cc69c08277863ea035f170b2fcaa` |

C owns the final combined native FIFO/PT8 UI/restart retest. This review neither
duplicates that full run nor relabels its prior MIME-blocked receipt as passing.

## Final independent correction recheck — PASS, no open blocker

2026-11-05. B completed the five omitted test/timing source roots and added
`bootstrap.sh` plus exactly four authored acceptance harness inputs required by
the existing Dune rules. Explicit missing-source import and baseline-only owned
support updates address the preservation requirement from the original finding.

### Unchanged original review:38/38 PASS

Receipt: `/tmp/opencode/development-backend-a-review-02/receipt.json`.
The original `reviewdocs/backend_review/run.py` was rerun **without changes** and
returned0, with no findings and `source_closure_omissions: []`.

This independently rechecks real regular-config native Discover, exact two-child
catalog parity, immutable matching app capture, locks, source freshness, config
ownership, interrupted publication/recovery, failed/successful refresh preservation
and actual FS2 reducer acceptance of the retained cancellation prefixes.

Initial private generation `e9e3410c02554c3ab0883243699a73d3`; refreshed private
generation `55fc58a077844306aafdb4c78cf5a24f`. The original review01 receipt and
37/38 result remain unchanged. Original runner SHA256 remains
`138c2c56be5e6a59c27eba14f7108289a4b15e96b07783535f6f6304535ef2cd`.

### New independent migration controls:24/24 PASS

Receipt: `/tmp/opencode/development-backend-a-migration-01/receipt.json`.
New verification-only entrypoint: `reviewdocs/backend_review/migration_recheck.py`.

- Entirely missing authored directories import exact staged source bytes.
- Existing empty directories and existing symlinks are never merged or replaced.
  Capture's original source inventory still rejects symlinked sources.
- An empty directory or symlink created between staging and publication causes
  atomic no-replace failure. The third-party destination, staged source and durable
  intent/result receipts survive intact.
- `--update-owned-support` updates matching recorded baselines only and preserves
  exact old bytes in checksum-verifiable backups. Arbitrary support edits and a
  symlinked support parent refuse overwrite/write-through.
- In A's private review02 project, omitted entries were moved into a separate
  retained-source directory to model the old incomplete closure. Plain refresh
  refuses with explicit import guidance. Explicit import followed by `/bin/false`
  build failure retains every approved addition, journals what was installed, and
  records the unchanged prior selected generation in `failure.json`.
- Exactly the four authored acceptance files import; no prior acceptance
  results/snapshots are copied.
- A subsequent user edit to the existing FIFO test survives another explicit
  import/failing-build attempt. Existing FIFO source edits and all state/client-state
  bytes remain unchanged throughout.

The private failed-capture migration receipt is:
`/tmp/opencode/development-backend-a-review-02/store/receipts/eb97f7925b6e41e1a7bb03d0027a27de/`.
Review02's selected immutable generation remains unchanged; only its explicitly
review-owned editable project was used for these later migration controls.

### Final stable generation: read-only verification PASS

Stable generation: `26f0d5e474bc4d45b5fc5859325c162d`.
Manifest SHA256:
`2170d35af3be1dc350f8dd1b8a49e2cf0aecf5bdc55adea75e6d20eedf5d139c`.

Independent `verify` passes its captured/dependency/config hashes. The stable
editable project's complete approved inventory equals that manifest's source
inventory, including all five added directories, bootstrap and acceptance inputs.
Both suite-specific source drift lists are empty. The corrected captured app hashes
are client `896cee9b6546be5c5d7fcd132306a55cf33cbc43d1c25edbd7cea9c467bd7a42`
and daemon `ec0108fd3ae65ac8bc8113462bfc1eb4dcdcbecf6410c144fbc982113f495a38`.

Before/after hashes prove no change to the stable manifest/configs, owner configs,
pre-existing edited owner source, or B production/tests. The user's stable daemon
was not launched. The original review rerun started/stopped only its new private
test daemon for Discover.

B's separate12-test PASS receipt and actual ordinary-test command/logs were read:
`/tmp/opencode/workbench-dev-b-jzc4uvlt/store/test-evidence/result.json` and
`standard-source-flow/ordinary-tests.{command.json,stderr}`. They record successful
`dune runtest --root PRIVATE_PROJECT -j2 test asic_test timing`, including FIFO,
wrapper, catalog/resolution and timing-core checks. A did not duplicate those
functional hardware tests; no new functional simulation or EDA was run by A.

### Exact correction-recheck commands and source hashes

From the Workbench checkout, switch `5.2.0+ox`:

```sh
opam exec --switch=5.2.0+ox -- python3 -B reviewdocs/backend_review/run.py \
  --evidence /tmp/opencode/development-backend-a-review-02 \
  --cancel-probe /home/wayne/devel/jane/silver/_build_pt8_workbench/default/reviewdocs/backend_review/cancellation_prefix_probe.exe

opam exec --switch=5.2.0+ox -- python3 -B reviewdocs/backend_review/migration_recheck.py \
  --evidence /tmp/opencode/development-backend-a-migration-01 \
  --store /tmp/opencode/development-backend-a-review-02/store
```

Both commands return0. Every real preparation build uses B's explicit private
root/output, `-j2` and shared example lock; captured apps use the shared Workbench
lock. The existing cancellation probe was reused. No production/original-review
code or historical receipt was changed.

| Corrected reviewed source | SHA256 |
| --- | --- |
| B `scripts/workbench_dev.py` | `9d91bb0390c14c649c2786abc24222c0470eea1c29fec2ff1d9e9d9ec93d38e8` |
| B `simulation/workbench_provider.py` | `8685ac3b718253e27c691bfaf8115b2e15890011895c298cf193ab0638a4aad3` |
| B `scripts/test_workbench_dev.py` | `0a0c17cb1595cc8c638f8e161da0290d8872e3053cfa9d38170785cda2da8872` |
| A supplemental migration probe | `cd0d4027dde2fe75a9aa9e0715705512246258b49f55039ad08846da26e57dca` |

**Final disposition: the prior medium closure finding is resolved. No open A
backend-review blocker remains.** C's separate combined native UI acceptance keeps
its own receipts and ownership.
