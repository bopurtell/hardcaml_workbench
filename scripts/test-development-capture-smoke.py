#!/usr/bin/env python3
"""Current-closure private native Discover/Plan + ordinary test smoke; EDA zero.

Only accepts a separately prepared /tmp/opencode store. Does not launch UI or
FIFO/PT8 provider simulations; never adopts the stable user's store.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import traceback

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('capture_smoke_support', HERE / 'test-development-session.py')
c = importlib.util.module_from_spec(spec)
spec.loader.exec_module(c)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--store', type=Path, required=True)
    p.add_argument('--evidence', type=Path, required=True)
    args = p.parse_args()
    args.store, args.evidence = args.store.resolve(strict=True), args.evidence.resolve()
    assert args.store.is_relative_to(Path('/tmp/opencode')) and args.evidence.is_relative_to(Path('/tmp/opencode'))
    args.evidence.mkdir()
    manifest = json.loads((args.store / 'manifest.json').read_bytes())
    args.launcher = HERE.parent.parent / 'hardcaml_asic_example/scripts/workbench_dev.py'
    args.root = Path(manifest['project_root'])
    for name in ('client', 'daemon'):
        setattr(args, name, Path(manifest['apps'][name]['path']))
    session = c.Session(args, args.evidence, args.root)
    session.state_dir = args.store / 'state'
    session.env.update(OMP_NUM_THREADS='2', OPENROAD_THREADS='2', _OPENLANE_MAX_CORES='2', PYTHONDONTWRITEBYTECODE='1')
    report = dict(passed=False, eda=0, provider_simulations=0, pty_clients=0, checks=[], store=str(args.store), generation=manifest['generation'])

    def check(ok, label):
        report['checks'].append(dict(passed=bool(ok), expectation=label))
        assert ok, label

    try:
        for kind in ('simulation', 'asic', 'preparation'):
            path = args.root / ('hardcaml-workbench-' + kind + '.sexp')
            check(path.is_file() and not path.is_symlink(), 'private current-closure regular config ' + kind)
        session.start()
        discovered = session.discover()
        check([c.field(s, 'id') for s in c.field(c.field(discovered, 'discovery')[0], 'suites')] == ['controlled-fifo', 'pt8-memory-workloads'], 'private production native Discover exact two-suite union')
        c.save(args.evidence / 'native-discovery.json', discovered)
        snapshot = session.api(domain='asic', operation='Discover')
        deadline = time.monotonic() + 30
        while not c.field(snapshot, 'flows'):
            assert time.monotonic() < deadline
            time.sleep(.1)
            snapshot = session.api(domain='asic')
        selected = [('flow', 'standard'), ('profile', 'balanced'), ('endpoint', 'synthesis'), ('assignments', [])]
        snapshot = session.api(domain='asic', operation=['Plan', selected])
        while not c.field(snapshot, 'preview'):
            assert time.monotonic() < deadline
            assert not any(c.field(op, 'state') == 'failed' for op in c.field(snapshot, 'operations'))
            time.sleep(.1)
            snapshot = session.api(domain='asic')
        preview = c.field(snapshot, 'preview')[0]
        check(json.loads(c.field(preview, 'plan_json'))['plan_identity'] == c.field(preview, 'plan_identity'), 'private current-source standard/balanced/synthesis Plan identity')
        check(not c.field(snapshot, 'runs') and not c.field(snapshot, 'workflows'), 'normal Plan submits no EDA run or workflow')
        c.save(args.evidence / 'normal-plan.json', preview)
        session.stop()
        env = dict(session.env, **manifest['environment'])
        argv = [str(Path(manifest['generation']) / 'tool-bin/dune'), 'runtest', '--root', str(args.root), '-j2', 'test', 'asic_test', 'timing']
        result = subprocess.run(argv, cwd=args.root, env=env, capture_output=True, timeout=180)
        (args.evidence / 'ordinary-tests.stdout').write_bytes(result.stdout)
        (args.evidence / 'ordinary-tests.stderr').write_bytes(result.stderr)
        c.save(args.evidence / 'ordinary-tests.command.json', dict(argv=argv, returncode=result.returncode, jobs=2, eda=0))
        check(result.returncode == 0, 'actual ordinary authored test/asic_test/timing gate passes privately at2 jobs')
        report['passed'] = True
    except BaseException:
        report['error'] = traceback.format_exc()
        raise
    finally:
        if session.process and session.process.poll() is None:
            session.stop()
        c.save(args.evidence / 'receipt.json', report)
    print('PASS private current-closure native Discover/Plan and ordinary tests: ' + str(args.evidence))


if __name__ == '__main__':
    main()
