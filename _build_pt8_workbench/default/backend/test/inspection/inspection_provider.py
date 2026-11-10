#!/usr/bin/env python3
"""Synthetic read-only provider for inspection/observation race fixtures; no EDA."""
import json
import pathlib
import sys
import time

root = pathlib.Path.cwd()
args = sys.argv[1:]
with (root / "inspection-calls").open("a") as calls:
    calls.write(json.dumps(args) + "\n")

if args == ["--version", "--json"]:
    result = {"cli_contract": {"version": 4, "capabilities": {"namedflow1": True, "timing_analysis1": True}}}
elif args[:1] == ["report"]:
    result = json.loads((root / "report.json").read_text())
elif args[:1] == ["observation"]:
    cursor = int((root / "cursor").read_text())
    result = {
        "contract": "hardcaml-asic.stage-observation",
        "schema_version": 2,
        "stream_id": "run-1",
        "cursor": cursor,
    }
    if args[1] == "read-updates":
        result.update(after=int(args[args.index("--after") + 1]), events=[])
    elif args[1] == "inspect":
        result.update(
            writer_active=False,
            observation_status="final",
            state={"outcome": {"status": "completed"}},
            execution_file=(
                (root / "observed-execution").read_text()
                if (root / "observed-execution").exists()
                else str(root / "execution.json")
            ),
            methodology={
                "contract": "hardcaml-asic.historical-methodology",
                "schema_version": 1,
                "state": "recorded",
                "reference": {"attempt_id": "run-1"},
            },
        )
    else:
        raise RuntimeError("Unexpected observation command")
elif args[:1] == ["inspect"]:
    kind = "detail" if "--row-id" in args else "index"
    (root / ("started-" + kind)).write_text("ready")
    deadline = time.monotonic() + 10
    while (root / ("hold-" + kind)).exists():
        if time.monotonic() > deadline:
            raise RuntimeError("Fixture hold timed out")
        time.sleep(0.01)
    result = json.loads((root / "response.json").read_text())
    if kind == "index" and "--expected-digest" in args and not (root / "ignore-pin").exists():
        expected = args[args.index("--expected-digest") + 1]
        if expected != result.get("analysis_digest"):
            raise RuntimeError("Analysis digest fence mismatch")
    if kind == "detail":
        row = args[args.index("--row-id") + 1]
        expected = args[args.index("--expected-digest") + 1]
        if expected != result["source_digest"]:
            raise RuntimeError("Digest fence mismatch")
        result.update(row_id=row, detail="verified path detail")
else:
    raise RuntimeError("Unexpected command: " + repr(args))

print(json.dumps(result))
