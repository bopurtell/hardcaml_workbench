#!/usr/bin/env python3
"""Held read-only summary refresh; no flow execution or EDA tools."""
import json
import pathlib
import sys
import time

root = pathlib.Path.cwd()
if sys.argv[1:] == ["--version", "--json"]:
    print(json.dumps({"cli_contract": {"version": 4, "capabilities": {"namedflow1": True}}}))
elif sys.argv[1:2] == ["observation"]:
    (root / "started").write_text("ready")
    deadline = time.monotonic() + 10
    while (root / "hold").exists():
        if time.monotonic() > deadline:
            raise RuntimeError("Fixture hold timed out")
        time.sleep(0.01)
    sys.exit("WB003 held summary provider failed")
else:
    raise RuntimeError("Unexpected command: " + repr(sys.argv[1:]))
