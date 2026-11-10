#!/usr/bin/python3
"""Backend-only read fixture: never allocates an observation or invokes tools."""
import json
import pathlib
import sys
import time

root = pathlib.Path.cwd()
args = sys.argv[1:]
with (root / "calls").open("a") as out:
    out.write(json.dumps(args) + "\n")
if args == ["--version", "--json"]:
    print(json.dumps({"cli_contract": {"version": 4, "capabilities": {
        "namedflow1": True, "resource_inspection1": not (root / "unsupported").exists()}}}))
elif args and args[0] == "resource-inspect":
    if (root / "delay").exists():
        time.sleep(0.1)
    if (root / "fail").exists():
        print("fixture source unavailable", file=sys.stderr)
        sys.exit(2)
    response = json.loads((root / "response.json").read_text())
    response["target"] = args[1]
    print(json.dumps(response, separators=(",", ":")))
    override = root / "exit-code"
    sys.exit(int(override.read_text()) if override.exists()
             else (1 if response["verdict"] == "fail" else 0))
else:
    print("unexpected provider command", file=sys.stderr)
    sys.exit(2)
