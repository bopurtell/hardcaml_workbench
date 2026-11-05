# PT.8 Workloads — launch, inspect, compare and run

2026-11-05. **Bounded integration accepted:** actual retained evidence and a fresh
example implementation-RTL workload were exercised through the production client.
The existing example root configuration and PT.6 session remain unchanged. This
guide opens a separate prepared PT.8 session; no additional build is required.

## Start the session

Terminal1:

```bash
cd /home/wayne/devel/jane/hardcaml_asic_example
opam exec --switch=5.2.0+ox -- python3 -B scripts/pt8_workbench_launch.py daemon \
  --session .dev/asic-pt8-workbench/session-final-review-01
```

Leave that foreground daemon running. In Terminal2:

```bash
cd /home/wayne/devel/jane/hardcaml_asic_example
opam exec --switch=5.2.0+ox -- python3 -B scripts/pt8_workbench_launch.py client \
  --session .dev/asic-pt8-workbench/session-final-review-01
```

The daemon chooses an available port and publishes it in this session's discovery
directory; the client reads that endpoint. Only one daemon should own this private
session state. The launchers use prebuilt matching Workbench binaries in
`hardcaml_workbench/_build_pt8_workbench/default/` and private configuration, client
state and daemon state. They do not use `.dev/asic-pt6/current`, install dependencies,
restart another daemon or change the root example's FIFO/ASIC configurations.

The private provider is fully prebuilt. This workload path needs no inherited
`hardcaml_asic.execution` library environment to rebuild the example during a run.
The normal root example's separately configured source-build flow still needs its
own matching activation environment; see [Resources launch](resource_inspector.md).

## Inspect retained evidence first

1. Press **Space c c**, choose **Open Workloads workspace**.
2. Choose **Workloads: Import exact retained result.json** and enter:

   ```text
   /home/wayne/devel/jane/hardcaml_asic_example/acceptance/pt8-workloads/simulation-04/flops/result.json
   ```

3. After it shows **Validated**, choose **Workloads: Capture A left result**.
4. Import the second result:

   ```text
   /home/wayne/devel/jane/hardcaml_asic_example/acceptance/pt8-workloads/simulation-04/exact/result.json
   ```

5. Capture **B right result**, then choose **Workloads: Axis resource_policy** or
   **Workloads: Compare captured A / B (c)**.

Captures use the public reader's verified bundle locator, so no bundle-path entry
is needed. The pair should show seven **comparable** zero deltas:1307 cycles,
525 reads,262 writes,787 operations,2083 defined observations, latency1 and
throughput787/1307 operations/cycle. This is logical-cycle evidence, not Fmax or a
physical area/speed winner. Source/provider/simulation identities remain distinct.

Navigation: **Esc** returns to results; **j/k** select or scroll; **Enter** opens;
**d** shows provenance/controls/full identities; **r** explicitly refreshes the
exact source/pair; **/** filters and **Ctrl-U** clears. Swap sends a new ordered
provider query. Merely opening, filtering or resizing the workspace runs no tools.
Restored evidence is labelled **Cached unverified** until explicitly refreshed.

## Launch your own workload

1. From the palette choose **Workloads: Launch fresh PT.8 workload… (Testing)**.
2. Select suite **pt8-memory-workloads** and open the existing launch form.
3. Select **flops256**, **exact256**, or both positive cases.
4. Keep seed **34097** (`0x8531`), then confirm **launch**.

This is the supported fixed directed workload; the seed records its identity and
does not generate arbitrary random stimulus. Other seeds/options reject rather
than being ignored. There are no additional workload parameters or ASIC inputs.

The existing FS2 supervisor owns launch, live state, logs, cancellation, durable
history and rerun. Actual emitted implementation RTL executes under Icarus; Exact
uses both unchanged stock SRAM functional model files. No synthesis/P&R/STA starts.
Both cases run sequentially when selected together.

When the attempt completes, select the intended case in Testing and choose
**Inspect workload result (selected Testing case)**. This reads its exact
attempt/case-bound reference artifact, checks its byte digest and opens the retained
result with the expected public source digest. Capture it as A or B and compare it
explicitly with the retained result or another fresh result.

The complete new evidence closure lives under
`hardcaml_asic_example/.dev/asic-pt8-workbench/workloads/`, outside FS2's disposable
work directories. A reference artifact is not a copy of the complete evidence.
Simulation success, functional verification and performance availability are shown
separately. Readable failure/partial evidence does not become a performance pass.

## Accepted evidence and review

Private session: `session-final-review-01`. Immutable ASIC reader/producer generation:
`ee3af8de9f83418b9afed9c67e473e3c`.

Actual native HTTP/PTY acceptance:

```text
hardcaml_asic_example/.dev/asic-pt8-workbench/session-final-review-01/
  native-acceptance-bb8eac43b648403d86e6c94c5cc9dfe3/assertions.json
  final-audit-a97dcfe970a4461a8e3dec9e0ebb8cf4/
  coordinator-review-01/receipt.json
```

Acceptance used the production Testing cases→seed→confirmation form to launch a
new Exact workload, then its artifact action to open **Validated** Workloads and
compare with original Flops. It also verifies a fresh HTTP-launched pair, readable
functional failure, automatic A/B capture, wide/narrow UI and warm navigation with
no child-tool execution. Original execution provider identities were preserved.
The coordinator independently checked the fresh raw simulator output, testbench
inputs, memory oracle/counters, stock model/source closure and public result digest;
no extra simulator/daemon was launched for that audit.

[Frontend independent review](pt8_workloads_frontend_review.md) corrected four
findings: prefixed FS2 artifact matching, digest loss on reopening, highlighted-vs-
loaded capture mismatch and missing target-generation pins on comparison refresh.
Its corrected independent harness retains45 original assertions and adds33 controls;
all78 pass. Original reproductions and failed receipts remain unchanged.

[Backend independent review](pt8_workloads_backend_review.md) corrected cache-root
alias publication and restored query/document binding gaps. Descriptor-bound cache
storage and canonical binding restore pass61 independent observations, including
zero observed descriptor growth across repeated failure cases. Hash consistency is
not authenticated history or an atomic cross-file snapshot. Cache format2 restores
derived evidence as unverified; old format1 derived caches require explicit rebuild.

Focused backend63 and storage-correction30 checks, the full terminal suite/lint,
protocol/adapter/daemon regressions,51 ASIC result and49 comparison checks passed.
Coordinator broad check passed:

```bash
flock /tmp/opencode/workbench-pt8-build.lock \
  opam exec --switch=5.2.0+ox -- dune build -j6 \
  --build-dir _build_pt8_workbench @all @runtest
```

Detailed controls, limits, cache/freshness and legacy manual-capture fallback:
[UI guide](pt8_workloads_ui.md), [shared handoff](pt8_workloads_handoff.md),
[plan](pt8_workloads_plan.md), and
[example producer handoff](../../hardcaml_asic_example/docs/pt8_workbench_provider.md).
Earlier capture/compiler/harness failures remain recorded there and in their
private immutable attempts. Root configs/selected providers, installed capture,
original retained evidence/bundles and tested Workbench binaries were hash-checked
before/after native acceptance. No Git publication, existing-session restart,
Protemu work or EDA occurred. User visual acceptance is the next manual step.
