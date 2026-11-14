# Cached synthesis inspection — FS1/F06 acceptance

This is **FS1's first F06 slice**, reusing FS0/F11 cached summaries and extending
the F12 table/inspector presentation. It is not a new standalone feature set or
a claim that timing/physical inspection is complete.

The later [FS1 metrics/physical extension](fs1_acceptance.md) adds `m` / **Synthesis:
Inspect metrics**, synthesis diagnostic counters and explicitly imported terminal
results. Its wire/cache additions and real physical evidence supersede the
unchanged-schema statement below for that later implementation. Cell browsing
controls and the original cached-run acceptance remain preserved.

## Use it in Workbench

Reopen the updated client, focus a synthesis tile with Tab, and optionally use
**Space c c → Zoom focused tile** for more room.

| Input | Effect |
| --- | --- |
| Enter from Summary | Open cell table |
| `j` / `k`, down / up | Select a cell row |
| `/`, text, Enter | Filter cell names (literal, case-insensitive) |
| Ctrl-U | Clear the focused filter, while editing or browsing; in the palette, clear its query |
| `s` | Cycle count descending/ascending, name ascending/descending |
| Enter in table | Inspect selected cell's full name, count and share |
| `e` | Inspect complete evidence, including full path and producer metadata |
| `j` / `k` or `[` / `]` in Details/Evidence | Scroll inspection content |
| Esc | Return from Details/Evidence to table, then from table to Summary |

The palette also provides **Synthesis: Browse cell table**, **Inspect selected
cell**, **Inspect full evidence**, **Clear cell filter**, and explicit sort choices.
Selection/filter/sort are local to each tile; pinning continues to work normally.
Changing run/result identity exits stale cell Details. Normal summaries retain
count/freshness and compact tables rather than raw JSON or full paths. Existing
wire records and persistent summary caches remain compatible; no provider upgrade
or new synthesis run is required for these controls.

Filter entry has a persistent **FILTER INPUT** footer, including when general chrome
is hidden; normal snapshot polling cannot erase that indicator. Enter/Esc finishes
entry. A filtered table shows its query and match count, and no-match output names
Ctrl-U as recovery. The query is no longer discoverable only at the clipped end of
a long pinned-run tile header.

Implementation: `protocol/synthesis.ml` is a pure typed projection over cached
`Asic.Summary`; `terminal/synthesis_view.ml` owns local inspection state and bounded
cell-width formatting. Projections and filtered rows are reused while data/filter/
sort remain unchanged. Missing/zero/invalid totals, mismatched breakdowns and integer
overflow are explicit; shares use the reported total, never a filtered subtotal.

## Run

From the Workbench repository root:

```sh
python3 scripts/test-synthesis-inspector.py
```

Requires Python 3, `strace`, existing compiled terminal/daemon executables, the
saved real Workbench state, and its example project configuration. The script
uses the `Session` and ANSI-screen emulator from `scripts/test-fs0.py`, and the
PTY/inventory helpers from `scripts/test-fs0-dashboard.py`.

**Historical replay prerequisite:** the saved state is keyed to its original
project/environment/configuration identity. The current example selects the
upgraded FS1 provider, so copying old state files alone does not make the old
registry visible. Preserve the original state and use matching configuration in
an isolated replay; do not revert the owner's live project configuration just
to reproduce this historical test. For current manual use, follow the
[FS1 example instructions](../README.md#open-the-completed-fs1-example).

Optional paths:

```sh
python3 scripts/test-synthesis-inspector.py \
  --source-state /tmp/opencode/workbench-fs0-91em64rl/real/state \
  --example-root /home/wayne/devel/jane/hardcaml_asic_example \
  --client /home/wayne/devel/jane/silver/_build/default/terminal/main.exe \
  --daemon /home/wayne/devel/jane/silver/_build/default/daemon/main.exe
```

Each invocation creates a new `/tmp/opencode/workbench-synthesis-inspector-*`
directory, copies only saved Workbench `asic-*.sexp` and `workspace-*.sexp`
files there, and starts its own daemon with that copied state. Client state is
also redirected into the scratch directory. The original saved state, example
configuration, and provider results are read-only inputs.

The only ASIC RPC operations issued explicitly are `Get` and initial
`Load_summary` for existing runs. Workspace RPC mutations change copied
bindings, selections, and zoom state. There are no Refresh, Observe, Discover,
Plan, Run, EDA, or build requests. Startup project metadata discovery may invoke
`dune describe`; the acceptance script does not invoke a Dune build.

## Controls and acceptance coverage

The test drives an actual 120×40 PTY and reconstructs the current screen from
ANSI output, rather than matching old strings in a terminal transcript.

1. Render the full Overview grid, switch to the saved two-synthesis-tile
   workspace, and zoom the first tile. Check real cached totals **685** and
   **673**, with `Cached_unverified` freshness.
2. Enter from Summary into Cells. Verify default count-descending order and
   cached source counts. Cycle `s` through count ascending, name ascending,
   name descending, and count descending; check visible row order in each.
3. Check `j`/`k` selection and equivalent down/up arrow behavior.
4. Apply `/mux2` and finish with Enter. The literal suffix matches
   `sg13cmos5l_mux2_1`, count **128**. Enter opens Details showing the full name,
   count, reported total **685**, and **18.69% of reported total**. Filtering
   must not change the share denominator.
5. Press `e` and scroll Evidence with `j`. Across the retained reconstructed
   screens, assert the **complete exact execution-file path** and **complete
   exact producer JSON** from the cached summary. Esc returns to Cells.
   Ordinary Summary/Cells screens must hide the raw producer and provider path.
6. Use palette commands `Synthesis: Clear cell filter` and
   `Synthesis: Sort name ascending`. Check the resulting table order. Filter
   with `mux2.*`: because filtering is literal, this has no match. Enter must
   not expose stale cell Details; exercise Esc, clear, and browse again.
7. Inspect `sg13cmos5l_a22oi_1` for run A (total **685**, cell count **58**),
   then change the shared context to run B through RPC while Details is open.
   The view must return to Cells with the new run label and count **56**,
   without old Details, share, or reported total. Re-enter Details and check
   total **673**, count **56**, and **8.32% of reported total**.
8. Unzoom and focus the second tile. It retains its independent Summary mode,
   unfiltered data, and default sort, while the first retains its filtered,
   name-sorted Cells view. Enter on the second tile demonstrates both sort
   states side by side.
9. Pin the first tile to A while the second follows shared context B. Restore
   Summary views and assert **685 on the left**, **673 on the right**, with
   explicit PIN/FOLLOW bindings.

Provider isolation is checked independently of the visible UI:

- Compare run, operation, and cached-summary snapshots before/after inspection.
- Trace the private daemon and descendants using `strace -D -f` with file and
  process syscalls. After the initial cached load and client metadata settle,
  assert no `execve`/`execveat` and no provider-results-root access. This also
  catches report file opens that do not allocate operations.
- Check the full daemon trace for provider-executable launches.
- Compare before/after inventories of the source state, configuration, provider
  executable, and entire results root. Inventories include size, mtime, ctime,
  and content hashes for JSON/sexp inputs and explicitly watched files.

## Retained evidence

The script prints its evidence directory immediately. It retains:

| Artifact | Contents |
| --- | --- |
| `result.json` | Overall status, assertions, traceback on failure, input-inventory equality, trace baseline offset |
| `commands.json` | Daemon and PTY argv, tracing wrapper, environment overrides, terminal dimensions |
| `keys.jsonl` | Timestamped exact PTY input bytes as hex and escaped text, including palette commands |
| Numbered RPC `.json`, `.stdout`, `.stderr` | Exact client argv, exit status, duration, and raw protocol responses |
| Numbered screen `.txt`, `.ansi` | Reconstructed current screens and cumulative raw ANSI at each checkpoint, including every Evidence scroll |
| `pty.ansi` | Complete PTY transcript |
| `daemon.strace`, `post-cache.strace` | Full daemon/descendant syscall trace and the post-cache acceptance interval |
| `discovery-*.log`, `discovery-*/daemon.sexp` | Private daemon stdout/stderr and discovery metadata |
| `files-before.json`, `files-after.json` | Original-input/provider inventories |
| `state/`, `client-state/` | Private copied/mutated Workbench state and client-local state |

Assertions fail without relaxing expected behavior, retain evidence, and stop
the private terminal/daemon. A failure should be reported with its evidence
directory and failing screen/trace for a parent implementation fix.

## Actual result

**PASS**, 2026-10-15, against the existing compiled binaries:

```text
$ python3 scripts/test-synthesis-inspector.py
Evidence: /tmp/opencode/workbench-synthesis-inspector-pmzn1twc
PASS: FS1/F06 cached synthesis inspector
```

All behavioral and isolation assertions passed, including the differing-cell
run switch (58→56), exact scrolled producer evidence, independent tile state,
and pinned/following totals. Original input/provider inventories were identical.
No implementation issues requiring a parent fix were observed in this run.

## Apparent crash / hidden-filter followup

2026-10-15: after the owner's apparent-crash report, both live processes were still
running and the daemon's hello endpoint responded. The client pane displayed an
empty filtered synthesis table; no process exception was captured. This does not
rule out an earlier unrecorded crash, but exposed a concrete input-state visibility
problem: filter capture and its query could be hidden by a long pinned header and
transient notices were cleared by polling.

Added the persistent editing indicator, query/match-count row and Ctrl-U recovery.
Unit tests cover recovery without changing registry/other-tile filters and the
indicator surviving polling with chrome hidden. Updated actual PTY acceptance
pauses through polling during a zero-match filter, exits entry, clears with Ctrl-U,
and continues sorting/detail/run-switch tests. Passed:
`/tmp/opencode/workbench-synthesis-inspector-u_665e0q/`.
The live user's client/daemon were not stopped or sent keys; tests use private copies.

### Confirmed input hang and interrupt-priority fix

The owner's followup clarified that the entire client ignored keys, including Ctrl-C.
The earlier liveness observation was insufficient. tmux was not in copy mode and
input was enabled; both terminal layers had software flow control disabled. The
inner terminal was in raw `-isig` mode: Ctrl-C arrives as input, not an OS-generated
SIGINT. The host handled modal/paste capture before the legacy Ctrl-C exit fallback,
so those paths swallowed the client's emergency exit.

`scripts/test-terminal-interrupt.py` reproduced the defect through raw PTY `0x03`:
normal/completed-paste cases exited, but filter, palette and unfinished-paste cases
hung for the test deadline. Before evidence:
`/tmp/opencode/workbench-terminal-interrupt-lrfl45ig/`.

The top-level input handler now processes Ctrl-C before any host/modal/paste path.
An unfinished paste also has a persistent capture indicator; pasted ordinary
commands remain suppressed. After evidence:
`/tmp/opencode/workbench-terminal-interrupt-t8v1fn0o/` — all five cases pass, restore
ISIG/ECHO/ICANON and leave the test daemon alive with no submitted jobs/artifacts.
Terminal tests, build, format and lint passed.

Recovery stopped only the owner's unresponsive client with external SIGTERM; the
original daemon remained running. A new client uses the rebuilt handler and can
attach to the same persisted session. No provider work or saved results were removed.
