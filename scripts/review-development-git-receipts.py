#!/usr/bin/env python3
"""Verify concrete independent Git recovery receipts without rerunning probes."""
import argparse
import hashlib
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent


def load(path):
    return json.loads(path.read_bytes())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--stage', type=Path, required=True)
    parser.add_argument('--store', type=Path, required=True)
    parser.add_argument('--evidence', type=Path, required=True)
    args = parser.parse_args()
    out = args.evidence.resolve()
    assert out.is_relative_to(Path('/tmp/opencode'))
    out.mkdir()
    report = dict(checks=[], synthesis_launches=0)
    def check(ok, label):
        report['checks'].append(dict(passed=bool(ok), expectation=label))
        assert ok, label
    try:
        check(load(args.stage / 'receipt.json')['passed'], 'stage consumer receipt passed')
        operation, = (args.stage / 'scoped/stage-preflight/operations').iterdir()
        stage = load(operation / 'preflight.json')
        check(stage['ready'] and not stage['issues'], 'installed stage report ready with zero issues')
        check(load(operation / 'operation.json')['status'] == 'ready', 'durable stage operation status ready')
        check(len(stage['references']) == 7, 'all seven real collateral references checked')
        collateral, = (operation / 'collateral').iterdir()
        raw = []
        for path in sorted(collateral.glob('probe-*.json')):
            command = load(path)
            base = path.with_suffix('')
            stdout = base.with_suffix('.stdout').read_text()
            stderr = base.with_suffix('.stderr').read_text()
            argv = command['argv']
            raw.append(dict(argv=argv, stdout=stdout, stderr=stderr))
            check(not stderr, path.name + ' stderr empty')
            if 'status' in argv:
                check(stdout == '', path.name + ' exact real status stdout empty')
            elif 'rev-parse' in argv:
                key = 'support_tools_revision' if 'tt' in argv[2].split('/')[-1] or argv[2].endswith('tt-support-tools') else 'pdk_revision'
                check(stdout.strip() == stage['requested'][key], path.name + ' real revision matches requested')
        check(len(raw) == 9, 'two real revision and seven real status probe receipts')
        report['collateral_probes'] = raw
        public = load(args.stage / 'public-preflight.stdout')
        check(public['ready'] and not public['issues'], 'installed public CLI preflight report ready with zero issues')
        docker = [json.loads(line) for line in (args.stage / 'docker.jsonl').read_text().splitlines()]
        runs = [row for row in docker if row['actual'][0] == 'run']
        check(bool(runs), 'real metadata containers were executed')
        for row in runs:
            argv = row['actual']
            check('--cpus=2' in argv and argv[-1] in ('container', 'metadata-container') and '-c' in argv,
                  'actual metadata-only container is bounded to two CPUs')
            check(all(value in argv for value in ('OMP_NUM_THREADS=2', 'OPENROAD_THREADS=2', '_OPENLANE_MAX_CORES=2')),
                  'actual metadata container explicitly bounds all three thread variables to two')
            check(all(value not in argv for value in ('OMP_NUM_THREADS=6', 'OPENROAD_THREADS=6', '_OPENLANE_MAX_CORES=6')),
                  'no six-thread setting reaches actual container')
        manifest = load(args.store / 'manifest.json')
        source = Path(manifest['generation']) / 'source'
        owner = HERE.parent.parent / 'hardcaml_asic_example'
        for name in ('scripts/workbench_dev.py', 'scripts/workbench_git.py', 'simulation/workbench_provider.py'):
            check(hashlib.sha256((source / name).read_bytes()).digest() == hashlib.sha256((owner / name).read_bytes()).digest(),
                  'tested capture equals current implementation ' + name)
        report.update(passed=True, stage_report=str(operation / 'preflight.json'),
                      metadata_container_count=len(runs), generation=manifest['generation'])
    finally:
        (out / 'receipt.json').write_text(json.dumps(report, indent=2) + '\n')
    print(out / 'receipt.json')


if __name__ == '__main__':
    main()
