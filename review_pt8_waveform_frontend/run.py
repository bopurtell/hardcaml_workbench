#!/usr/bin/env python3
"""Read-only production review; independent build target and immutable receipts."""
import hashlib
import json
from pathlib import Path
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[1]
OUT = Path(__file__).resolve().parent / ('evidence-' + uuid.uuid4().hex)
OUT.mkdir()
paths = [*ROOT.joinpath('terminal').glob('*.ml'), *ROOT.joinpath('terminal').glob('*.mli'),
         ROOT / 'terminal/dune', ROOT / 'terminal/test_waveform_handoff_pty.py',
         ROOT / 'terminal/workspaces/waveforms.ml']
def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()
def snapshot():
    return {str(p.relative_to(ROOT)): sha(p) for p in sorted(paths)}
def write(name, value):
    with (OUT / name).open('x') as f:
        json.dump(value, f, indent=2)
        f.write('\n')
before = snapshot()
write('source-before.json', before)
commands = [
    ['flock', '/tmp/opencode/workbench-pt8-build.lock', 'opam', 'exec', '--switch=5.2.0+ox', '--',
     'dune', 'build', '-j2', '--build-dir', '_build_pt8_workbench', 'review_pt8_waveform_frontend/review.exe',
     'review_pt8_waveform_frontend/async_review.exe'],
    [str(ROOT / '_build_pt8_workbench/default/review_pt8_waveform_frontend/review.exe')],
    [str(ROOT / '_build_pt8_workbench/default/review_pt8_waveform_frontend/async_review.exe')]]
for n, argv in enumerate(commands):
    with (OUT / f'{n}.stdout').open('xb') as out, (OUT / f'{n}.stderr').open('xb') as err:
        result = subprocess.run(argv, cwd=ROOT, stdout=out, stderr=err, timeout=240)
    write(f'{n}.command.json', {'argv': argv, 'cwd': str(ROOT), 'exit_code': result.returncode,
                              'max_jobs': 2, 'eda_allocation': 0})
    if result.returncode:
        raise RuntimeError(str(OUT))
after = snapshot()
write('source-after.json', after)
write('receipt.json', {'production_and_tests_unchanged': before == after,
    'findings': [s for s in (OUT / '1.stdout').read_text().splitlines() if s.startswith('FINDING')],
    'binaries': {str(p.relative_to(ROOT)): sha(p) for p in [
        ROOT / '_build_pt8_workbench/default/terminal/main.exe',
        ROOT / '_build_pt8_workbench/default/daemon/main.exe']}, 'eda_allocation': 0})
assert before == after
print(OUT)
