#!/usr/bin/env python3
"""Private production daemon/PTY handoff checks; no build or simulator invocation."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import time

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


wire = load('handoff_wire', ROOT / 'scripts/fixtures/fs2_wire.py')


def provider():
    p = argparse.ArgumentParser()
    p.add_argument('operation')
    p.add_argument('--protocol-version')
    p.add_argument('--request', type=Path)
    p.add_argument('--events', type=Path)
    p.add_argument('--artifact-dir', type=Path)
    a = p.parse_args(sys.argv[2:])
    if a.operation == 'discover':
        print(wire.sexp(wire.catalog(cases=['flops256', 'exact256'])))
        return
    request = dict(wire.parse(a.request.read_text()))
    selection = dict(request['selection'])
    writer = wire.EventWriter(a.events, request['attempt_id'])
    writer.emit('Started')
    for case in selection['cases']:
        writer.emit(['Case_started', case])
        path = a.artifact_dir / (case + '.json')
        path.write_text(json.dumps(dict(contract='hardcaml-workbench.pt8-result-reference',
            schema_version=1, result='/retained/' + case + '/result.json', source_digest='a' * 64)))
        writer.artifact(case + '-result-reference', case, 'json', 'application/json', path.name)
        # JSON-only run, then mixed artifacts with distinct case-specific signal names.
        if selection['seed'] == '2':
            path = a.artifact_dir / (case + '.vcd')
            path.write_text('$timescale 1 ns $end\n$scope module ' + case +
                ' $end\n$var wire 1 ! clk $end\n$upscope $end\n$enddefinitions $end\n#0\n0!\n#5\n1!\n#10\n0!\n')
            writer.artifact(case + '-waveform', case, 'trace', 'text/vcd', path.name)
        writer.finish_case(case)
    writer.emit(['Finished', 'Passed'])


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--daemon', type=Path, required=True)
    p.add_argument('--client', type=Path, required=True)
    args = p.parse_args()
    args.daemon, args.client = args.daemon.resolve(), args.client.resolve()
    evidence = Path(tempfile.mkdtemp(prefix='pt8-waveform-pty-', dir='/tmp/opencode'))
    print('Evidence: ' + str(evidence), flush=True)
    native = load('handoff_native', ROOT / 'scripts/test-fs2-native.py')
    embedded = load('handoff_embedded', ROOT / 'scripts/test-embedded-waveform.py')
    field = native.field
    for name in ('project', 'state', 'home', 'config', 'tmp'):
        (evidence / name).mkdir()
    root = evidence / 'project'
    (root / 'dune-project').write_text('(lang dune 3.22)\n(name handoff)\n')
    (root / 'hardcaml-workbench-simulation.sexp').write_text(wire.sexp([
        ('schema_version', 1), ('provider_executable', sys.executable),
        ('provider_args', [str(Path(__file__).resolve()), '_provider']),
        ('discovery_timeout_seconds', 10), ('run_timeout_seconds', 30)]))
    session = native.Session(args, evidence, root)
    session.env.update(HOME=str(evidence / 'home'), XDG_CONFIG_HOME=str(evidence / 'config'),
        TMPDIR=str(evidence / 'tmp'), PYTHONDONTWRITEBYTECODE='1')
    terminal = proxy = None
    checks = []

    class Terminal(native.Terminal):
        width, height = 160, 50

        def palette(self, title):
            for key in (b' ', b'c', b'c'):
                self.key(key)
            self.key(title.encode())
            self.capture('query-' + str(time.time_ns()), ['COMMAND PALETTE', title[-60:]],
                absent=['No matching commands'])
            self.key(b'\x1b[A' * 24)
            self.key(b'\r')

    def check(value, label):
        checks.append(dict(passed=bool(value), expectation=label))
        if not value:
            raise AssertionError(label)
        print('PASS ' + label, flush=True)

    try:
        session.start()
        catalog = session.discover()
        attempts = []
        for seed in ('1', '2'):
            snap = session.api(operation=['Launch', ['submission_key', 'seed-' + seed],
                ['discovery_digest', field(catalog, 'discovery_digest')[0]], ['selection', [
                    ('suite', 'fixture'), ('cases', ['flops256', 'exact256']), ('seed', seed),
                    ('parameters', []), ('asic_inputs', [])]]])
            attempts.append(session.done(field(field(snap, 'attempts')[0], 'id')))
        proxy = embedded.DelayedBytesProxy(session.url, evidence)
        session.url = proxy.url
        terminal = Terminal(session)
        terminal.capture('startup', ['Overview'])
        terminal.palette('Switch to Testing')
        for _ in range(5):
            terminal.key(b'\t')

        def reopen(attempt):
            terminal.palette('Simulation: Reopen ' + field(attempt, 'id') + ' fixture')
            terminal.palette('Simulation: Select case flops256')

        reopen(attempts[0])
        for _ in range(3):
            terminal.key(b'\t')
        terminal.key(b'w')
        terminal.capture('json-only-no-vcd', ['No available supported VCD'],
            absent=['Embedded viewer supports VCD only', 'Captured waveform identity'])
        check(not proxy.records, 'JSON-only w does not fetch/pin a JSON waveform')
        # Workload inspection stays discoverable without executing nonexistent retained paths.
        for key in (b' ', b'c', b'c'):
            terminal.key(key)
        terminal.key(b'Inspect workload result (selected Testing case)')
        terminal.capture('json-inspect-action', ['Inspect workload result'], absent=['No matching commands'])
        terminal.key(b'\x1b')
        check(True, 'JSON-only case retains Inspect workload result action')
        reopen(attempts[1])
        terminal.key(b'w')
        terminal.capture('mixed-flops-quick', ['flops256.clk', 'Cursor'], absent=['exact256.clk'])
        check(all('flops256-waveform' in r['request']['artifact_id'] for r in proxy.records),
            'mixed w fetches only exact selected flops waveform')
        terminal.key(b'\x1b')
        terminal.palette('Simulation: Select case exact256')
        gate = proxy.arm('late-exact-quick')
        terminal.key(b'w')
        check(gate['ready'].wait(10), 'held exact-case waveform byte reply reached transport')
        terminal.key(b'\x1b')
        terminal.palette('Simulation: Select case flops256')
        terminal.key(b'W')
        terminal.capture('flops-workspace', ['Signals', 'Waves', 'Pinned: flops256-waveform'],
            absent=['exact256-waveform'])
        gate['release'].set()
        time.sleep(.3)
        terminal.capture('late-exact-fenced', ['Pinned: flops256-waveform'], absent=['exact256-waveform'])
        check(True, 'late exact-case reply cannot replace flops workspace pin/model')
        for key in (b' ', b'c', b'c'):
            terminal.key(key)
        terminal.key(b'Waveform: Select VCD exact256-waveform')
        terminal.capture('picker-cross-case-absent', ['No matching commands'])
        terminal.key(b'\x1b')
        check(True, 'pinned case picker excludes another case VCD')
        check(all(r['request']['artifact_id'].endswith('-waveform') for r in proxy.records),
            'production byte requests never target result-reference JSON')
    finally:
        if terminal:
            terminal.close()
        if proxy:
            proxy.close()
        session.stop()
        (evidence / 'checks.json').write_text(json.dumps(checks, indent=2) + '\n')
        (evidence / 'binaries.json').write_text(json.dumps({name: dict(path=str(getattr(args, name)),
            sha256=hashlib.sha256(getattr(args, name).read_bytes()).hexdigest())
            for name in ('client', 'daemon')}, indent=2) + '\n')


if __name__ == '__main__':
    provider() if len(sys.argv) > 1 and sys.argv[1] == '_provider' else main()
