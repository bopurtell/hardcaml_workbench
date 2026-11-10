#!/usr/bin/env python3
"""Reuse historical independent probe helpers without editing its source/entrypoint."""
from pathlib import Path
import sys

original = Path(sys.argv[1]).read_text()
entrypoint = "\nlet () =\n  don't_wait_for (main ());\n  never_returns (Scheduler.go ())\n;;\n"
if not original.endswith(entrypoint) or original.count(entrypoint) != 1:
    raise SystemExit("Historical probe entrypoint changed; review the wrapper explicitly")
sys.stdout.write("(* Schema2 correction recheck; historical probe source is unchanged. *)\n")
sys.stdout.write(original[:-len(entrypoint)])
sys.stdout.write("\n")
sys.stdout.write(Path(sys.argv[2]).read_text())
