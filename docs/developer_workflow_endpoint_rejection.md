# Interactive endpoint rejection: clear failure and retained checklist

2026-11-10. Follow-up to the [developer workflow closeout](developer_workflow_refactored_closeout.md).
Owner selected `standard / balanced / placement` in the accepted synthesis-only
store04. Build/emission completed, but the active envelope rejected the physical
recipe before stage execution. Run `9e6e0de93bd1497c88f502aa9b2d1c23` retained an
allocation/planned/failed-outcome journal with recipe synthesis → floorplan →
placement. Mandatory named-preflight inspection then masked the rejection with
`observation_unavailable`, and checklist context was lost.

## Corrected behavior

- Fresh provider metadata gates incompatible endpoints before planning/preparation,
  and again before stage allocation. Active synthesis-only profiles reject physical
  endpoints with an actionable explanation. Synthesis remains allowed;
  elaboration-only requires no provider call. Default provider behavior is unchanged.
- A complete, identity-fenced allocation/planned/failed prefix proves pre-execution
  rejection. The backend retains its primary failure and exact planned recipe,
  marking requested stages skipped/not executed. Prepared, started, incomplete,
  interrupted or mismatched evidence cannot take this path.
- Historical Refresh can recover this failed run from retained journal data without
  relaunching. Existing persisted workflow error text is not automatically rewritten.
- Checklist fallback retains the exact endpoint as unconfirmed when observations
  are missing; it does not invent a prefix. Human-readable error summaries keep raw
  diagnostics available through the detail view.

Independent review passed forced backend ASIC and terminal suites, plus an offline
probe through real captured journal → recovery → checklist → host rendering.
The recovered recipe shows synthesis/floorplan/placement skipped, later stages not
requested, and no invented duration. No real provider or EDA was run for this fix.

## Explicit adoption into the running session

The live owner session was not stopped, refreshed or modified. Existing captures
are immutable. After the owner exits the client and stops its daemon, the supported
app-only refresh preserves exact companions/provider environment and history scope.
Run from `hardcaml_asic_example`:

```bash
opam exec --switch=5.2.0+ox -- python3 -B scripts/workbench_dev.py \
  --store /tmp/opencode/developer-workflow-envelope-v1-store-04 prepare \
  --refresh --apps-only \
  --wb-build-root /home/wayne/devel/jane/hardcaml_workbench/_build_pt8_workbench \
  --expected-daemon-sha256 7ae6e0c5804ed48f51665648a6058b9fe266c39255957a7f83493fc4a86e6621 \
  --expected-client-sha256 3d4953e6d99430a05e434a7262e81c3b3dc30c8c13f38e2339de61c15c5dab24
```

Then use the same store's `daemon` and `client` subcommands and explicitly
Observe/Refresh the rejected run. Hash mismatch or source drift must be investigated,
not bypassed. The adoption command was documented, **not executed against the live
session**. Its existing accepted generation and failed-run evidence remain intact.

This update improves rejection handling; it does not enable placement. The capture
still intentionally has the synthesis-only six-task envelope. A general physical
development session needs a separately selected provider/resource configuration;
silently removing this captured limit is not part of the fix.
