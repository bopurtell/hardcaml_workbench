#!/usr/bin/env python3
"""Independent helper checks; no frontend production edits or daemon launch."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    output = Path(tempfile.mkdtemp(prefix='pt8-endpoint-independent-', dir='/tmp/opencode'))
    paths = [ROOT / 'terminal' / name for name in ('launch_preferences.ml', 'preparation_view.ml',
        'workspace_host.ml', 'host_view.ml', 'main.ml')]
    before = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
    commands = [
        ('build', ['opam', 'exec', '--switch=5.2.0+ox', '--', 'flock',
            '/tmp/opencode/workbench-pt8-build.lock', 'dune', 'build', '-j2', '--root', str(ROOT),
            '--build-dir', '_build_pt8_workbench', 'review_pt8_endpoint_defaults/review.exe',
            'review_pt8_endpoint_defaults/grammar.exe']),
        ('matrix', [str(ROOT / '_build_pt8_workbench/default/review_pt8_endpoint_defaults/review.exe')]),
        ('spaced-assignment', [str(ROOT / '_build_pt8_workbench/default/review_pt8_endpoint_defaults/review.exe'),
            '--spaced-assignment']),
        ('grammar', [str(ROOT / '_build_pt8_workbench/default/review_pt8_endpoint_defaults/grammar.exe')])]
    results = []
    for label, argv in commands:
        result = subprocess.run(argv, cwd=ROOT, capture_output=True, timeout=600)
        (output / (label + '.stdout')).write_bytes(result.stdout)
        (output / (label + '.stderr')).write_bytes(result.stderr)
        results.append({'label': label, 'argv': argv, 'exit_code': result.returncode})
        if label == 'build' and result.returncode:
            break
    after = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
    (output / 'receipt.json').write_text(json.dumps({'commands': results, 'before': before,
        'after': after, 'production_unchanged_during_tests': before == after,
        'scope': 'independent helper/palette/row tests; no daemon or EDA'}, indent=2) + '\n')
    print(output, flush=True)
    assert len(results) == 4 and all(result['exit_code'] == 0 for result in results)
    assert before == after, 'production changed during independent review'


if __name__ == '__main__':
    main()
