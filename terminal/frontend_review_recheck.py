#!/usr/bin/env python3
"""Generate a supplemental recheck; preserve the original reviewer source/assertions.

After F2 is fixed, the original adversarial cache fixture accidentally uses the
pinned query to admit a different digest through the backend validator. Construct
that fixture under the unpinned query it describes, leaving all assertions intact.
The other-case negative must explicitly construct its intended different-case
state: select_case otherwise rejects the unavailable case and retains Flops.
"""
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
old = 'let new_asic=snapshot (Option.value_exn reopened.query) (d \'c\') "NEWER-UNPINNED-C" in'
new = 'let new_asic=snapshot (Inspect {result="/retained/shared.json";expected_digest=None}) (d \'c\') "NEWER-UNPINNED-C" in'
if source.count(old) != 1:
    raise SystemExit("Independent fixture changed: re-review instead of rewriting it implicitly")
source = source.replace(old, new, 1)
old_case = '(T.Testing_workspace.select_case state "exact256")'
new_case = '(T.Testing_workspace.set_view state { (T.Testing_workspace.view state) with case_id=Some "exact256" })'
if source.count(old_case) != 1:
    raise SystemExit("Independent case fixture changed: re-review instead of rewriting it implicitly")
sys.stdout.write("(* Supplemental recheck: original assertions, corrected cache/case fixture preconditions. *)\n")
sys.stdout.write(source.replace(old_case, new_case, 1))
