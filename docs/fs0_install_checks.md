# FS0 installed workflow checks — 2026-10-15

## Final-frontend revalidation

After the parent's synthesis-tile/header/focus updates, the following were rerun
serially under a renewed exclusive runtime/build grant:

| Command | Actual result |
| --- | --- |
| `./scripts/test-native-application.sh` | **PASS**, exit 0, including all three PTY variants and full installed lifecycle checks |
| `./scripts/capture-terminal-baseline.sh --check` | **PASS**, exit 0; `terminal baselines are up to date` |

The successful installed run used
`/tmp/hardcaml-workbench-native.pHSfgt/{prefix,outside,fixture,integrated-fixture}`,
removed by normal script cleanup. Dune build/install/exec/runtest limits remain
`-j20`. The standalone fixture script's pass below belongs to the earlier grant;
it was not rerun in this final-frontend check.

### Generation-completion diagnosis and fix

One diagnostic native run reproduced the hierarchy PTY failure before changing
the assertion. Raw terminal evidence remains in the harness output:

```text
/home/wayne/.local/share/opencode/tool-output/tool_13f59570d001Ic8R3jTX7xUJHA
```

The submission notice named
`690838-1792064116353367761-2f0f6a96-job-2`. Output showed that job moving from
Queued to completed, followed by `k` selecting that exact ID. A forced full
repaint showed the execution tile focused, job-2 selected, `STATUS: Complete`
and `Process: exited with code 0`. The old assertion nevertheless failed because
it expected a new literal `STATUS: Complete` in the post-`k` incremental bytes.
Both discovery and generation were already complete, so Notty correctly repainted
only the selected-row markers; the unchanged status line was not transmitted again.
This is an incremental-output test assumption, not an observed production bug.

Source evidence inspected without editing:

- `terminal/main.ml`, `execute_host` / `Generate_rtl`: adds the returned job to
  the snapshot before emitting `Submitted RTL as <id>`.
- `terminal/main.ml`, `project_jobs`: newest-first job order.
- `terminal/main.ml`, `browse_host`: attempt-tile-only browsing, retaining local
  cursor by job ID and resolving its position against the current list.
- `terminal/host_view.ml`, `rows`: looks up the selected job by local cursor ID
  and renders its outcome via `Presentation.job_outcome_lines`.

Only `scripts/test-terminal-resize.py` and this record were edited for this
revalidation. The script now waits for the actual submission ID before moving
selection, requests one deterministic full repaint by resizing from 120x40 to
121x40, and requires the exact submitted job's selected-row marker. It then checks
completion in that repaint plus subsequent updates. This handles an already
completed job without adding a sleep/retry mask or accepting the old discovery
job's status. Failures retain submission, selection and current repaint/update
bytes for diagnosis. CSI controls are stripped when matching notice/identity text.

The parent's dynamic Tab search (bounded at 16) and independent header-piece
checks are preserved. Generation is still launched through `g`, the submitted
attempt is selected before `h`, and all current/historical labels, child-node
navigation, collapse/expand, compact scrolling, resize/recovery and project identity
checks remain active. No production UI code or baseline capture was changed.

## Final results

Executed serially from `/home/wayne/devel/jane/silver`, under the
parent's exclusive build/runtime grant:

| Command | Actual result |
| --- | --- |
| `./scripts/test-native-application.sh` | **PASS**, exit 0; final output `Native lifecycle and installed workflow checks: passed` |
| `FIXTURE_OPAM_SWITCH=5.2.0+ox ./scripts/test-fixture.sh` | **PASS**, exit 0; fixture driver discovery and both 4-bit/8-bit RTL generation checks completed |
| `./scripts/capture-terminal-baseline.sh --check` | **PASS**, exit 0; `terminal baselines are up to date` |

All build/runtest/exec/install Dune invocations in these scripts use `-j20`.
Runtime project build/test and driver-exec invocations use the previously capped
adapters. The existing fixture `dune clean` remains a cleanup command. No dependency
installation, EDA execution or mutative Git command was performed by this task.
The native script installs Workbench itself into its owned temporary prefix.

The successful native run used
`/tmp/hardcaml-workbench-native.heL9M9/{prefix,outside,fixture,integrated-fixture}`;
the fixture run used `/tmp/hardcaml-workbench-fixture.zj99aR`. These paths were
removed by the scripts' normal cleanup and are not persistent installations.

## Updated assertions and retained coverage

Changes in this follow-up are confined to `scripts/test-terminal-resize.py`,
`scripts/test-native-application.sh`, and this new record. No main UI code or
baseline captures were changed.

- Native PTY invocations supply exact expected project names:
  `hardcaml_workbench_fixture` and `hardcaml-counter-fixture`.
- Closing connection details must restore the named project's **Overview**
  workspace, **Linked: Main**, and **run none**. A hierarchy inspector must instead
  recover its existing hierarchy view.
- The initial startup frame may include the transitional legacy project view or
  the workspace host. Verbose daemon identity must still be absent by default.
- Attached discovery is observed through the host execution tile's selected
  attempt reaching `STATUS: Complete`, without refresh/polling input while waiting.
  The command palette must then expose both exact discovered commands:
  `Generate RTL: Four-bit counter / 4-bit counter` and
  `Generate RTL: Four-bit counter / 8-bit counter`.
- RTL generation completion is observed through the selected execution attempt;
  opening its hierarchy must still show current evidence and both child instances.
  Configuration changes must switch current/historical labels. Node navigation,
  collapse/expand, and compact inspector scrolling remain asserted.
- Both the workspace/inspector and connection-details views are resized through
  `120x40`, `40x10`, `1x1`, `80x24`, `100x24`, and `80x24`. Every stage must repaint
  without client exit. Existing dimension diagnostic assertions are retained by
  exercising the connection-details renderer, which actually emits them.
- The full native script continued past all three PTY checks and passed its
  detached job/event streaming, reattachment, manifest aliases, driver refresh,
  RTL/artifact/hierarchy retrieval, invalid-input, daemon replacement/concurrency,
  and explicit-endpoint checks.

The final native output explicitly reported:

```text
Terminal resize checks: passed
Terminal resize checks: passed
Attached-client live discovery: passed
Terminal resize checks: passed
Attached-client hierarchy navigation: passed
Native lifecycle and installed workflow checks: passed
```

## Investigative failures before the successful native run

The parent originally reported the obsolete left-pane recovery assertion. After
updating it, four local native attempts failed before the final successful run:

1. Missing `dimensions width=40 height=10` diagnostic. Source inspection showed
   dimension logging belongs to `render_legacy`, not `Host_view.render`. Added a
   second resize sequence while connection details is open; retained all markers.
2. Old discovery labels `Integration: Driver` and `Four-bit counter` were absent
   from the default host. Replaced those presentation assumptions with host
   execution-state and discovered-command assertions.
3. The first replacement incorrectly required the execution body title and full
   job kind in newly received PTY bytes. Those bytes are incremental updates;
   the static title had already rendered, and the narrow tile clips the job kind.
4. A diagnostic-only rerun confirmed that same incremental-output mismatch:
   output showed the execution focus change and Running-to-Complete status, while
   the initial frame contained the title. The final assertion checks the actual
   focus/status update and verifies complete target/configuration labels through
   the palette, where they are visible.

No check was disabled to obtain the final pass. Connection-details resize coverage
was added, and discovered target/configuration checks moved to their current host
surface. These are installed Workbench/fixture checks, not real ASIC synthesis or
physical-acceptance results.
