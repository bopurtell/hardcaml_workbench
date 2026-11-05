#!/usr/bin/env python3
"""Independent coordinator audit of retained real PT8 UI acceptance; no new runs."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess


def load(path):
    return json.loads(path.read_bytes())


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--native', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    a = p.parse_args()
    a.output.mkdir(exist_ok=False)
    summary = load(a.native / 'assertions.json')
    assert summary['pass']
    assert summary['ui_form_launch_passed'] and summary['ui_artifact_handoff_expected_digest']
    for path, expected in summary['wb_binaries'].items():
        assert sha(Path(path)) == expected
    generation = Path(summary['provider_generation'])
    assert sha(generation / 'receipt.json') == summary['provider_receipt_sha256']
    reference = summary['ui_result_reference']
    result_path = Path(reference['result'])
    directory = result_path.parent
    result = load(result_path)
    simulation = load(directory / result['simulation']['path'])
    assert simulation['attempt_id'] == summary['new_simulation_attempt_id']
    assert simulation['attempt_id'] not in summary['retained_simulation_attempt_ids']
    assert simulation['attempt_id'] != summary['actual_ui_fs2_attempt']
    ledger = load(directory.parent / 'request.json')
    assert ledger['fs2_attempt_id'] == summary['actual_ui_fs2_attempt']
    assert ledger['case'] == 'exact256' and ledger['seed'] == '34097'
    assert Path(ledger['generation']) == generation
    for ref in [result[k] for k in ('simulation', 'stimulus', 'trace')] + [x['source'] for x in simulation['artifacts']]:
        path = directory / ref['path']
        assert sha(path) == ref['sha256'] and path.stat().st_size == ref['bytes']
    manifest = load(Path(result['bundle']) / 'manifest.json')
    assert manifest['identity'] == simulation['bundle_identity']
    for source in manifest['synthesis_sources']:
        assert sha(Path(result['bundle']) / source) == sha(directory / Path(source).name)
    assert 'hc_resource_7_program' in (directory / 'tt_um_pt8_workload.v').read_text()
    for artifact in simulation['artifacts']:
        if artifact['role'] == 'model':
            path = directory / artifact['source']['path']
            assert sha(path) == sha(Path(summary['session']) / 'provider/models' / path.name)
    trace = load(directory / 'trace.json')['rows']
    operations = result['workload']['operations']
    raw = [line.split()[1:] for line in (directory / 'execute/stdout.log').read_text().splitlines()
           if line.startswith('TRACE ')]
    steps = re.findall(r"step\((\d+), 1'b([01]), 1'b([01]), 8'd(\d+), 8'd(\d+)\);",
                       (directory / 'testbench.v').read_text())
    assert len(trace) == len(raw) == len(steps) == len(operations) == 1307
    memory, output, defined, reads, writes = {}, None, 0, 0, 0
    for i, (row, op, words, step) in enumerate(zip(trace, operations, raw, steps)):
        assert row['cycle'] == i == int(words[0]) == int(step[0]) and row['input'] == op
        assert (bool(int(step[1])), bool(int(step[2])), int(step[3]), int(step[4])) == (
            op['enable'], op['write'], op['address'], op['data'] & 255)
        before = output
        if op['enable']:
            if op['write']:
                memory[op['address']] = op['data']
                output = None
                writes += 1
            else:
                output = memory.get(op['address'])
                reads += 1
        assert result['workload']['expected'][i] == {'before': before, 'after': output}
        for phase, expected, word in zip(('before', 'after'), (before, output), words[1:]):
            observation = None if re.search('[xz]', word.lower()) else int(word, 16)
            assert row[phase] == observation
            if expected is not None:
                assert observation == expected
                defined += 1
    assert (reads, writes, defined) == (525, 262, 2083)
    query = subprocess.run([str(generation / 'bin/hardcaml-asic-flow'), 'workload-inspect',
                            str(result_path), '--json'], capture_output=True, timeout=180)
    assert query.returncode == 0, query.stderr
    inspection = json.loads(query.stdout)
    assert inspection['source_digest'] == reference['source_digest']
    assert inspection['binding']['bundle'] == str(Path(result['bundle']).resolve())
    comparison = load(a.native / 'ui-fresh-vs-retained-comparison.json')
    rows = [m for m in comparison['metrics'] if m['metric_id'].startswith('workload/')]
    assert len(rows) == 7 and all(m['comparison'] == 'comparable' and m['right_minus_left'] == 0 for m in rows)
    handoff_screen = (a.native / 'ui-artifact-workloads-handoff.txt').read_text()
    assert all(s in handoff_screen for s in ('Validated', 'cycles: 1307', 'numerator=787', 'denominator=1307'))
    for prefix in ('root-protected', 'installed', 'retained'):
        assert load(a.native / (prefix + '-before.json')) == load(a.native / (prefix + '-after.json'))
    (a.output / 'inspection.json').write_bytes(query.stdout)
    receipt = dict(passed=True, script_sha256=sha(Path(__file__)), native=str(a.native),
        summary_sha256=sha(a.native / 'assertions.json'), exact_raw_trace_edges=len(trace),
        source_digest=inspection['source_digest'], fs2_attempt=ledger['fs2_attempt_id'],
        simulation_attempt=simulation['attempt_id'], seven_zero_deltas=True,
        new_simulations=0, new_daemons=0, eda=0)
    (a.output / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print('Coordinator audit passed: fresh UI attempt, raw RTL trace/oracle/model closure, pinned handoff and seven zero deltas.')


if __name__ == '__main__':
    main()
