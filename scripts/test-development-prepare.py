#!/usr/bin/env python3
"""Private repeat/refresh transaction controls; sequential two-job builds, EDA zero.

Run after native acceptance stops its private daemon. This intentionally edits one
OCaml source ONLY in --store/project and retains that edit and failed generations.
--initial only prepares the private store; --exercise-refresh runs full controls.
"""
import argparse
import fcntl
import hashlib
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
spec = importlib.util.spec_from_file_location('prepare_control_wire', HERE / 'test-fs2-native.py')
wire = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wire)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inventory(root):
    return {str(p.relative_to(root)): sha(p) for p in sorted(root.rglob('*')) if p.is_file()}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--store', type=Path, required=True)
    p.add_argument('--launcher', type=Path, default=HERE.parent.parent / 'hardcaml_asic_example/scripts/workbench_dev.py')
    p.add_argument('--evidence', type=Path, required=True)
    mode = p.add_mutually_exclusive_group(required=True)
    mode.add_argument('--initial', action='store_true')
    mode.add_argument('--exercise-refresh', action='store_true')
    args = p.parse_args()
    args.store, args.evidence = args.store.resolve(), args.evidence.resolve()
    private = Path('/tmp/opencode').resolve()
    assert args.store != private and args.store.is_relative_to(private)
    assert args.evidence.is_relative_to(private) and not args.evidence.is_relative_to(args.store)
    args.evidence.mkdir()
    report = dict(passed=False, eda=0, checks=[], commands=[])
    command = [sys.executable, '-B', str(args.launcher.resolve(strict=True)), '--store', str(args.store)]
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE='1', OMP_NUM_THREADS='2', OPENROAD_THREADS='2', DUNEJOBS='2')

    def check(ok, label):
        report['checks'].append(dict(passed=bool(ok), expectation=label))
        assert ok, label

    def run(label, extra, success=True, timeout=1200):
        started = time.monotonic()
        result = subprocess.run(command + extra, env=env, capture_output=True, timeout=timeout)
        (args.evidence / (label + '.stdout')).write_bytes(result.stdout)
        (args.evidence / (label + '.stderr')).write_bytes(result.stderr)
        report['commands'].append(dict(label=label, argv=command + extra,
            returncode=result.returncode, seconds=time.monotonic() - started))
        check((result.returncode == 0) == success, label + ': expected exit class')
        return result

    def selected():
        return json.loads((args.store / 'manifest.json').read_bytes())

    try:
        if args.initial:
            assert not args.store.exists(), 'initial test requires unused private store'
            run('initial-prepare', ['prepare'])
            manifest = selected()
            check(manifest['project_root'] == str(args.store / 'project'), 'initial fixed editable root')
            for kind, app in manifest['apps'].items():
                original = Path(manifest['inputs']['wb_build_root']) / 'default' / ('terminal' if kind == 'client' else kind) / 'main.exe'
                check(sha(Path(app['path'])) == app['sha256'] == sha(original), 'prepared final prebuilt app hash ' + kind)
            report['manifest'] = manifest
        else:
            manifest = selected()
            state = inventory(args.store / 'state')
            prefs = inventory(args.store / 'client-state')
            sources = {name: sha(args.store / 'project' / name) for name in manifest['source_files']}
            chosen = manifest['generation']
            # Refuse to run mutation controls against even this private live daemon.
            with (args.store / 'state/lifetime.lock').open('a+b') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                fcntl.flock(lock, fcntl.LOCK_UN)
            run('repeat-prepare', ['prepare'], timeout=60)
            check(selected()['generation'] == chosen, 'repeat prepare does not select new generation')
            check(all(sha(args.store / 'project' / name) == digest for name, digest in sources.items()), 'repeat prepare preserves complete editable source')
            source_name = next(name for name in manifest['suite_sources']['controlled-fifo']
                               if name.startswith('lib/') and name.endswith('.ml'))
            source = args.store / 'project' / source_name
            with source.open('ab') as stream:
                stream.write(b'\n(* Independent C private refresh preservation control. *)\n')
            edited = sha(source)
            run('repeat-with-source-edit', ['prepare'], timeout=60)
            check(sha(source) == edited and selected()['generation'] == chosen, 'repeat reports drift without replacing source/edit or selection')
            status = json.loads(run('status-with-source-edit', ['status'], timeout=60).stdout)
            check(source_name in status['source_drift']['controlled-fifo'], 'status explicitly flags the actual edited FIFO source as stale')
            run('invalid-prepare-option', ['prepare', '--C-invalid-flag'], success=False, timeout=30)
            check(selected()['generation'] == chosen and sha(source) == edited,
                  'invalid prepare flag rejects without changing selection or editable source')
            request = args.evidence / 'stale-request.sexp'
            events = args.evidence / 'stale-events.sexp'
            artifacts = args.evidence / 'stale-artifacts'
            artifacts.mkdir()
            request.write_text(wire.sexp([('protocol_version', 1), ('attempt_id', 'c-stale-control'), ('selection', [
                ('suite', 'controlled-fifo'), ('cases', ['directed']), ('seed', '42'),
                ('parameters', [('checker', 'normal'), ('cycles', '64')]), ('asic_inputs', [])])]))
            stale = subprocess.run(manifest['provider_command'] + ['run', '--protocol-version', '1',
                '--request', str(request), '--events', str(events), '--artifact-dir', str(artifacts)],
                env=env, capture_output=True, timeout=30)
            (args.evidence / 'stale.stderr').write_bytes(stale.stderr)
            check(stale.returncode != 0 and b'prepare --refresh' in stale.stderr and not events.exists()
                  and not list(artifacts.iterdir()), 'stale source rejected before child evidence with actionable refresh')
            run('failed-refresh', ['prepare', '--refresh', '--dune', '/bin/false'], success=False)
            check(selected()['generation'] == chosen and sha(source) == edited, 'failed source-build refresh rolls back selection and preserves source edit')
            check(inventory(args.store / 'state') == state and inventory(args.store / 'client-state') == prefs,
                  'failed refresh and repeat preserve complete state/artifacts/client prefs')
            run('explicit-refresh', ['prepare', '--refresh'])
            refreshed = selected()
            check(refreshed['generation'] != chosen and refreshed['project_root'] == manifest['project_root'], 'explicit refresh new immutable generation at same fixed root')
            check(refreshed['source_files'][source_name] == edited and sha(source) == edited, 'refresh captures actual editable source; never recopies owner checkout')
            check(inventory(args.store / 'state') == state and inventory(args.store / 'client-state') == prefs,
                  'successful refresh preserves exact durable histories/artifacts/client prefs')
            check(Path(chosen).is_dir(), 'previous generation retained')
            run('repeat-after-refresh', ['prepare'], timeout=60)
            check(selected()['generation'] == refreshed['generation'], 'repeat after refresh remains idempotent')
            # Hold precisely the daemon state lifetime lock, without a fake daemon.
            with (args.store / 'state/lifetime.lock').open('a+b') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                run('active-state-lock-refresh', ['prepare', '--refresh'], success=False, timeout=30)
            check(selected()['generation'] == refreshed['generation'] and sha(source) == edited,
                  'held state lifetime lock blocks refresh before switching or source changes')
            report.update(old_generation=chosen, new_generation=refreshed['generation'], edited_source=source_name,
                          state_files=len(state), client_pref_files=len(prefs))
        report['passed'] = True
    except BaseException:
        report['error'] = traceback.format_exc()
        raise
    finally:
        (args.evidence / 'receipt.json').write_text(json.dumps(report, indent=2) + '\n')
    print('PASS private development preparation controls: ' + str(args.evidence), flush=True)


if __name__ == '__main__':
    main()
