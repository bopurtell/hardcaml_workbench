#!/usr/bin/python3
"""Independent disposable workload-reader boundary fixture (no simulation/EDA)."""
import json
import os
from pathlib import Path
import sys
import time

root = Path.cwd()
args = sys.argv[1:]
with (root / "calls.jsonl").open("a") as out:
    out.write(json.dumps({"argv": args, "pid": os.getpid()}) + "\n")
if args == ["--version", "--json"]:
    if (root / "metadata-oversize").exists():
        sys.stdout.write(" " * (1048576 + 1))
        sys.exit(0)
    caps = {"namedflow1": True, "workload_inspection1": True,
            "variant_comparison1": True, "workload_comparison1": True}
    if (root / "caps.json").exists():
        caps.update(json.loads((root / "caps.json").read_text()))
    print(json.dumps({"cli_contract": {"version": 4, "capabilities": caps}}))
    sys.exit(0)
if (root / "gate").exists():
    (root / "entered").write_text(str(os.getpid()))
    end = time.monotonic() + 15
    while (root / "gate").exists() and time.monotonic() < end:
        time.sleep(.005)
if (root / "exit-code").exists():
    code = int((root / "exit-code").read_text())
    if code:
        print("independent-reader-failure", file=sys.stderr)
        sys.exit(code)
mode = (root / "mode").read_text() if (root / "mode").exists() else "normal"
if mode == "oversized-lines":
    for _ in range(1030):
        sys.stdout.write(" " * 1024 + "\n")
elif mode == "oversized-record":
    sys.stdout.write(" " * (1048576 + 1))
elif mode == "stderr-pressure":
    sys.stderr.write("!" * (2 * 1048576))
    sys.stdout.write((root / "response.json").read_text())
elif mode == "boundary":
    raw = (root / "response.json").read_bytes()
    sys.stdout.buffer.write(raw + b" " * (1048576 - len(raw)))
else:
    sys.stdout.write((root / "response.json").read_text())
