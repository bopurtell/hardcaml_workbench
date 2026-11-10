#!/usr/bin/env python3
"""Read-only independent audit of C's retained native development receipt.

No daemon, simulation, EDA or build. Checks original transport bytes and the
same-execution PT8 result closures rather than trusting a passing summary alone.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import sys

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('development_review_wire', HERE / 'test-fs2-native.py')
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)
field = native.field


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read(path):
    return json.loads(path.read_bytes())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--native', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--partial', action='store_true', help='audit completed executions in a failed/blocked native receipt; never claims native acceptance')
    args = parser.parse_args()
    source = args.native.resolve(strict=True)
    assert args.output.resolve().is_relative_to(Path('/tmp/opencode').resolve())
    args.output.mkdir()
    receipt = read(source / 'receipt.json')
    assert (receipt['status'] == 'passed' or args.partial) and receipt['configs_unchanged'] and receipt['apps_unchanged']
    assert args.partial or all(check['passed'] for check in receipt['checks'])
    invocation = read(source / 'invocation.json')
    for path, digest in invocation['binaries'].items():
        assert sha(Path(path)) == digest
    attempts = [read(path) for path in source.glob('attempt-*.json')]
    attempts.sort(key=lambda d: 2 if field(field(field(d, 'captured'), 'selection'), 'suite') == 'pt8-memory-workloads'
                  else 0 if field(d, 'outcome') == 'Passed' else 1)
    assert len(attempts) == 3
    assert {field(a, 'project_root') for a in attempts} == {invocation['root']}
    assert [field(a, 'outcome') for a in attempts] == ['Passed', 'Failed', 'Passed']
    normal, mismatch, pt8 = attempts
    exported = {}
    for attempt in attempts:
        aid = field(attempt, 'id')
        exported[aid] = {}
        for artifact in field(attempt, 'artifacts'):
            identity = field(artifact, 'id')
            path = source / 'artifacts' / aid / re.sub(r'[^A-Za-z0-9_.-]', '_', identity)
            assert sha(path) == field(artifact, 'sha256')[0]
            assert path.stat().st_size == int(field(artifact, 'size')[0])
            assert field(artifact, 'attempt_id') == aid
            exported[aid][field(artifact, 'label')] = path
    for case in ('directed', 'seeded'):
        a = exported[field(normal, 'id')]
        b = exported[field(mismatch, 'id')]
        assert a[case + '.vcd'].read_bytes() == b[case + '.vcd'].read_bytes()
        assert b'injected true' in b[case + '.sexp'].read_bytes()
    closures = []
    for artifact in field(pt8, 'artifacts'):
        if field(artifact, 'media_type') != 'application/json':
            continue
        reference = read(exported[field(pt8, 'id')][field(artifact, 'label')])
        case = field(artifact, 'case_id')[0]
        result_path = Path(reference['result'])
        result = read(result_path)
        directory = result_path.parent
        simulation = read(directory / result['simulation']['path'])
        ledger = read(directory.parent / 'request.json')
        assert ledger['fs2_attempt_id'] == field(pt8, 'id') and ledger['case'] == case
        assert ledger['seed'] == '34097'
        assert simulation['attempt_id'] != field(pt8, 'id')
        for ref in [result[k] for k in ('simulation', 'stimulus', 'trace')] + [x['source'] for x in simulation['artifacts']]:
            path = directory / ref['path']
            assert sha(path) == ref['sha256'] and path.stat().st_size == ref['bytes']
        rows = read(directory / 'trace.json')['rows']
        operations = result['workload']['operations']
        raw = [line.split()[1:] for line in (directory / 'execute/stdout.log').read_text().splitlines()
               if line.startswith('TRACE ')]
        assert len(rows) == len(raw) == len(operations) == 1307
        memory, output, reads, writes, defined = {}, None, 0, 0, 0
        for i, (row, op, words) in enumerate(zip(rows, operations, raw)):
            assert row['cycle'] == i == int(words[0]) and row['input'] == op
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
                observed = None if re.search('[xz]', word.lower()) else int(word, 16)
                assert row[phase] == observed
                if expected is not None:
                    assert observed == expected
                    defined += 1
        assert (reads, writes, defined) == (525, 262, 2083)
        closures.append(dict(case=case, result=str(result_path), simulation_attempt=simulation['attempt_id'],
                             source_digest=reference['source_digest'], trace_rows=len(rows)))
    assert {c['case'] for c in closures} == {'flops256', 'exact256'}
    comparison = read(source / 'workloads-seven-zero-deltas.json')
    metrics = [m for m in comparison['metrics'] if m['metric_id'].startswith('workload/')]
    assert len(metrics) == 7 and all(m['comparison'] == 'comparable' and m['right_minus_left'] == 0 for m in metrics)
    assert '0001001111000110' in (source / 'pt8-exact-cursor.txt').read_text()
    assert '13070000' in (source / 'pt8-fit-full-trace.txt').read_text()
    rerun_audited = None
    if receipt.get('post_restart_rerun'):
        aid = receipt['post_restart_rerun']
        rerun = read(source / ('rerun-' + aid + '.json'))
        selected = field(field(rerun, 'captured'), 'selection')
        parent = field(rerun, 'parent')[0]
        assert field(parent, 'attempt_id') == field(mismatch, 'id') and field(parent, 'job') == field(mismatch, 'job')
        assert aid not in [field(d, 'id') for d in attempts] and field(rerun, 'job') != field(mismatch, 'job')
        assert field(rerun, 'outcome') == 'Failed' and field(rerun, 'exit_code') == ['0']
        assert field(selected, 'cases') == ['seeded'] and field(selected, 'seed') == '18446744073709551615'
        assert dict(field(selected, 'parameters')) == {'checker': 'mismatch', 'cycles': '64'}
        for artifact in field(rerun, 'artifacts'):
            path = source / 'artifacts' / aid / re.sub(r'[^A-Za-z0-9_.-]', '_', field(artifact, 'id'))
            assert sha(path) == field(artifact, 'sha256')[0] and path.stat().st_size == int(field(artifact, 'size')[0])
            if field(artifact, 'label') == 'seeded.vcd':
                assert path.read_bytes() == exported[field(mismatch, 'id')]['seeded.vcd'].read_bytes()
            else:
                assert b'injected true' in path.read_bytes()
        rerun_audited = aid
    audit = dict(passed=True, native=str(source), receipt_sha256=sha(source / 'receipt.json'),
                 script_sha256=sha(Path(__file__)), same_execution_closures=closures,
                 seven_zero_deltas=True, simulations=0, eda=0, untested=receipt['untested'],
                 native_acceptance_passed=receipt['status'] == 'passed', native_status=receipt['status'],
                 native_blockers=receipt.get('blockers', []), native_error=receipt.get('error'),
                 native_failed_checks=[c for c in receipt['checks'] if not c['passed']],
                 exact_post_restart_targeted_rerun=rerun_audited)
    (args.output / 'receipt.json').write_text(json.dumps(audit, indent=2) + '\n')
    print('PASS independent native/artifact/oracle closure audit: ' + str(args.output))


if __name__ == '__main__':
    main()
