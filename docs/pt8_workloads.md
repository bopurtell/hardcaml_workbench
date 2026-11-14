# PT.8 Workloads — launch, inspect, compare and run

For everyday FIFO **and** PT.8 development, use the
[stable combined development session](development_session.md). The feature-specific
session commands below remain a retained focused workflow, not the primary entry point.

2026-11-05. **Bounded integration accepted:** actual retained evidence and a fresh
example implementation-RTL workload were exercised through the production client.
The existing example root configuration and PT.6 session remain unchanged. This
guide opens a separate prepared PT.8 session; no additional build is required.

**Standard-flow recovery, 2026-11-05:** incorporated into the waveform-enabled
`session-waveforms-final-01` below.
The original config-only PT.8 session supported workload simulation but omitted
the source closure required by normal Plan/Preparation. The recovery session
includes an independent source snapshot, matching provider libraries and private
build/results paths. The endpoint form now prefills from advertised endpoints and
preserves quoted assignments. See [real UI recovery acceptance](standard_plan_recovery.md).

**Waveform recovery:** the initial PT.8 provider published only result-reference
JSON, not VCD. The new session captures and publishes actual six-signal VCDs and
keeps JSON workload inspection separate. Historical runs are preserved and do not
gain invented waveforms. See [final waveform acceptance](pt8_waveform_final_acceptance.md).

## What “workload” means here

**The workload is the scenario contract; stimulus is one of its components.**
It specifies input operations/data together with execution assumptions and rules,
completion, defined expected observations and measurement rules/window. The testbench
driver, assertions/reference model/checker and monitors implement those requirements;
they can remain reusable environment components rather than one monolithic object.
For UVM users, sequence items correspond to raw stimulus, and a sequence/virtual
sequence corresponds to the traffic part of a workload. The full contract also
covers rules normally distributed across test configuration, checking and monitors.

| Term | Meaning in this workflow |
| --- | --- |
| Stimulus | Raw operations, transactions and logical input data |
| Workload | The stimulus plus scenario assumptions/rules, completion, expected behavior and measurement rules |
| Test/case | A runnable configuration that executes a scenario and checks its behavior |
| Suite | A collection of selectable cases |
| Attempt | One actual execution of selected cases with concrete inputs |
| Result | Outcomes, measurements, identities and retained evidence from that execution |
| Waveform | Recorded signal activity; not the entire verification result |

```text
pt8-memory-workloads suite
├── flops256 case → fixed memory workload on the Flops implementation
└── exact256 case → same logical workload on the supported SRAM implementation
```

Conceptually a case may consume several workloads. Today these two cases each
consume one fixed workload, with multiple internal traffic phases. There is no
arbitrary N-workload composition feature or separate workload runner. Hardware
variant, concrete driver/model/image artifacts and execution identities remain
separate from the logical workload. See the
[provider terminology and contract](../../hardcaml_asic/docs/guides/variant-comparison.md#terminology-stimulus-workload-test-and-suite).

## Start the session

Terminal1:

```bash
cd /home/wayne/devel/jane/hardcaml_asic_example
opam exec --switch=5.2.0+ox -- python3 -B scripts/pt8_workbench_launch.py daemon \
  --session .dev/asic-pt8-workbench/session-waveforms-final-01
```

Leave that foreground daemon running. In Terminal2:

```bash
cd /home/wayne/devel/jane/hardcaml_asic_example
opam exec --switch=5.2.0+ox -- python3 -B scripts/pt8_workbench_launch.py client \
  --session .dev/asic-pt8-workbench/session-waveforms-final-01
```

The daemon chooses an available port and publishes it in this session's discovery
directory; the client reads that endpoint. Only one daemon should own this private
session state. The launchers use prebuilt matching Workbench binaries in
`silver/_build_pt8_workbench/default/` and private configuration, client
state and daemon state. They do not use `.dev/asic-pt6/current`, install dependencies,
restart another daemon or change the root example's FIFO/ASIC configurations.

The private workload provider is fully prebuilt. The launcher also supplies the
matching `hardcaml_asic.execution` library environment for standard-flow source
builds in the independent private example snapshot.
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

### Open the fresh waveform

For a fresh run in this capture-enabled session, select the intended attempt and
case in Testing, then focus **Artifacts**. Press **w** for the quick embedded
viewer or **Shift-W** for the dedicated Waveforms workspace. The palette also
offers **Open embedded waveform** and **Open dedicated Waveforms workspace** for
the exact VCD. A JSON cursor can resolve the same case's VCD sibling; it is never
passed to the VCD parser. JSON-only historical attempts explain that no VCD was
published, while their independent Workloads result inspection still works.

The VCD shows clock, enable, active-low write command (`rst_n`, not memory reset),
address (`ui_in`), write low byte (`uio_in`) and response (`q`). Unknown initial
memory responses remain X. At time0 the known lanes render while q's lane says
**X/Z in window; no graph**; exact X values remain visible. This is a bounded
two-state graph fallback, not full four-state plotting. Press **:** and enter
**2595000** (1ps ticks) to view the first defined response, **13C6**. No storage
array/vendor hierarchy dump is produced; each accepted capture is about64KB.

The complete new evidence closure lives under
the private session project's `.dev/asic-pt8-workbench/workloads/`, outside FS2's
disposable work directories. A reference artifact is not a copy of the complete evidence.
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
