#!/usr/bin/env python3
"""Independent composite discovery/routing controls; no simulation or build.

Only a private copied manifest is altered. Real child discovery is compared byte-
semantically, fake child failures exercise atomic discovery, and an exec recorder
proves untouched request/argv/PID/process group. Invalid requests use real children.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import traceback

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('development_provider_wire', HERE / 'test-fs2-native.py')
wire = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wire)


def child():
    p = argparse.ArgumentParser()
    p.add_argument('--catalog', type=Path, required=True)
    p.add_argument('--mode', required=True)
    p.add_argument('--record', type=Path, required=True)
    args, extras = p.parse_known_args(sys.argv[2:])
    if extras[0] == 'discover':
        if args.mode == 'failure':
            return 12
        if args.mode == 'oversize':
            print('x' * (1024 * 1024 + 1))
        elif args.mode == 'invalid':
            print('not-a-catalog')
        else:
            print(args.catalog.read_text())
        return 0
    req = Path(extras[extras.index('--request') + 1])
    args.record.write_text(json.dumps(dict(argv=extras, pid=os.getpid(), pgid=os.getpgrp(),
        request_sha256=hashlib.sha256(req.read_bytes()).hexdigest())))
    return 27


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--store', type=Path, required=True)
    p.add_argument('--evidence', type=Path, required=True)
    args = p.parse_args()
    store, output = args.store.resolve(strict=True), args.evidence.resolve()
    assert store.is_relative_to(Path('/tmp/opencode')) and output.is_relative_to(Path('/tmp/opencode'))
    output.mkdir()
    manifest = json.loads((store / 'manifest.json').read_bytes())
    router = manifest['provider_command'][:-2]
    assert manifest['provider_command'][-2] == '--manifest'
    current = output / 'manifest.json'
    report = dict(passed=False, simulations=0, builds=0, checks=[])

    def check(ok, label):
        report['checks'].append(dict(passed=bool(ok), expectation=label))
        assert ok, label

    def invoke(argv):
        return subprocess.run(argv, capture_output=True, timeout=30)

    def discover(config, label, success=True):
        current.write_text(json.dumps(config))
        result = invoke(router + ['--manifest', str(current), 'discover', '--protocol-version', '1'])
        (output / (label + '.stdout')).write_bytes(result.stdout)
        (output / (label + '.stderr')).write_bytes(result.stderr)
        check((result.returncode == 0) == success, label + ': expected discovery exit')
        if not success:
            check(not result.stdout, label + ': no partial catalog emitted')
        return result

    def request(label, suite='controlled-fifo', seed='42', cases=None, parameters=None):
        directory = output / label
        directory.mkdir()
        artifacts = directory / 'artifacts'
        artifacts.mkdir()
        path = directory / 'request.sexp'
        events = directory / 'events.sexp'
        selected = [('suite', suite), ('cases', cases if cases is not None else ['directed']),
            ('seed', seed), ('parameters', parameters if parameters is not None else [('checker', 'normal'), ('cycles', '64')]), ('asic_inputs', [])]
        # Deliberate whitespace differences must survive routing byte-for-byte.
        path.write_text('\n  ' + wire.sexp([('protocol_version', 1), ('attempt_id', label), ('selection', selected)]) + '\n\n')
        return path, events, artifacts, ['run', '--protocol-version', '1', '--request', str(path),
                                       '--events', str(events), '--artifact-dir', str(artifacts)]

    try:
        children = {}
        union = []
        for suite, command in manifest['provider_commands'].items():
            result = invoke(command + ['discover', '--protocol-version', '1'])
            check(result.returncode == 0, 'real child discovery ' + suite)
            (output / (suite + '.sexp')).write_bytes(result.stdout)
            children[suite] = wire.parse(result.stdout.decode())
            union.extend(wire.field(children[suite], 'suites'))
        real = discover(manifest, 'real-composite')
        check(wire.field(wire.parse(real.stdout.decode()), 'suites') == union,
              'exact FIFO-then-PT8 union preserves all seeds/cases/options/labels')
        copied = json.loads(json.dumps(manifest))
        fake_commands = {}
        record = output / 'exec-record.json'
        for suite in manifest['provider_commands']:
            fake_commands[suite] = [sys.executable, '-B', str(Path(__file__).resolve()), '_child',
                '--catalog', str(output / (suite + '.sexp')), '--mode', 'valid', '--record', str(record)]
        for mode in ('failure', 'invalid', 'oversize'):
            copied['provider_commands'] = dict(fake_commands)
            command = list(fake_commands['pt8-memory-workloads'])
            command[command.index('valid')] = mode
            copied['provider_commands']['pt8-memory-workloads'] = command
            discover(copied, mode, success=False)
        copied['provider_commands'] = dict(fake_commands)
        copied['provider_commands']['pt8-memory-workloads'] = fake_commands['controlled-fifo']
        discover(copied, 'duplicate-child-suite', success=False)
        copied['provider_commands'] = fake_commands
        current.write_text(json.dumps(copied))
        for suite in fake_commands:
            path, events, artifacts, tail = request('route-' + suite, suite=suite)
            proc = subprocess.Popen(router + ['--manifest=' + str(current), *tail], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            stdout, stderr = proc.communicate(timeout=30)
            observed = json.loads(record.read_text())
            check(proc.returncode == 27 and observed['pid'] == proc.pid and observed['pgid'] == os.getpgrp(),
                  suite + ': exec preserves PID/PGID/child exit')
            check(observed['argv'] == tail and observed['request_sha256'] == hashlib.sha256(path.read_bytes()).hexdigest(),
                  suite + ': untouched FS2 argv and request bytes')
        current.write_text(json.dumps(manifest))
        invalid = [('unknown-suite', dict(suite='unknown')),
            ('fifo-invalid-uint64', dict(seed='18446744073709551616')),
            ('fifo-duplicate-case', dict(cases=['directed', 'directed'])),
            ('pt8-invalid-seed', dict(suite='pt8-memory-workloads', seed='42', cases=['exact256'], parameters=[])),
            ('pt8-unknown-case', dict(suite='pt8-memory-workloads', seed='34097', cases=['unknown'], parameters=[]))]
        for label, values in invalid:
            path, events, artifacts, tail = request(label, **values)
            result = invoke(router + ['--manifest', str(current), *tail])
            (output / (label + '.stderr')).write_bytes(result.stderr)
            check(result.returncode != 0 and (not events.exists() or not events.read_bytes()) and not list(artifacts.iterdir()),
                  label + ': actual child rejects before evidence')
        report['passed'] = True
    except BaseException:
        report['error'] = traceback.format_exc()
        raise
    finally:
        (output / 'receipt.json').write_text(json.dumps(report, indent=2) + '\n')
    print('PASS composite controls: ' + str(output), flush=True)


if __name__ == '__main__':
    sys.exit(child() if sys.argv[1:2] == ['_child'] else main())
