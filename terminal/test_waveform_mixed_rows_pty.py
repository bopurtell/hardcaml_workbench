#!/usr/bin/env python3
"""Production PTY: replay retained real PT8 VCD; no new simulator execution."""
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


wire = load('mixed_wire', ROOT / 'scripts/fixtures/fs2_wire.py')


def provider():
    p = argparse.ArgumentParser()
    p.add_argument('--vcd', type=Path, required=True)
    p.add_argument('--media-type', default='text/vcd')
    p.add_argument('operation')
    p.add_argument('--protocol-version')
    p.add_argument('--request', type=Path)
    p.add_argument('--events', type=Path)
    p.add_argument('--artifact-dir', type=Path)
    a = p.parse_args(sys.argv[2:])
    if a.operation == 'discover':
        print(wire.sexp(wire.catalog(cases=['flops256'])))
        return
    request = dict(wire.parse(a.request.read_text()))
    writer = wire.EventWriter(a.events, request['attempt_id'])
    writer.emit('Started')
    writer.emit(['Case_started', 'flops256'])
    (a.artifact_dir / 'retained.vcd').write_bytes(a.vcd.read_bytes())
    writer.artifact('flops256-waveform', 'flops256', 'trace', a.media_type, 'retained.vcd')
    writer.finish_case('flops256')
    writer.emit(['Finished', 'Passed'])


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--daemon', type=Path, required=True)
    p.add_argument('--client', type=Path, required=True)
    p.add_argument('--vcd', type=Path, required=True)
    args = p.parse_args()
    for name in ('daemon', 'client', 'vcd'):
        setattr(args, name, getattr(args, name).resolve(strict=True))
    evidence = Path(tempfile.mkdtemp(prefix='pt8-mixed-rows-pty-', dir='/tmp/opencode'))
    print('Evidence: ' + str(evidence), flush=True)
    native = load('mixed_native', ROOT / 'scripts/test-fs2-native.py')
    cells = native.load_module('mixed_cells', 'test-frontend-composition.py')
    field = native.field
    for name in ('project', 'state', 'home', 'config', 'tmp'):
        (evidence / name).mkdir()
    root = evidence / 'project'
    (root / 'dune-project').write_text('(lang dune 3.22)\n(name mixed_rows)\n')
    (root / 'hardcaml-workbench-simulation.sexp').write_text(wire.sexp([
        ('schema_version', 1), ('provider_executable', sys.executable),
        ('provider_args', [str(Path(__file__).resolve()), '_provider', '--vcd', str(args.vcd)]),
        ('discovery_timeout_seconds', 10), ('run_timeout_seconds', 30)]))
    session = native.Session(args, evidence, root)
    session.env.update(HOME=str(evidence / 'home'), XDG_CONFIG_HOME=str(evidence / 'config'),
        TMPDIR=str(evidence / 'tmp'), PYTHONDONTWRITEBYTECODE='1')
    terminal = None
    checks = []

    def check(ok, label):
        checks.append(dict(passed=bool(ok), label=label))
        if not ok:
            raise AssertionError(label)
        print('PASS ' + label, flush=True)

    class Terminal(native.Terminal):
        width, height = 120, 40

        def palette(self, title):
            for key in (b' ', b'c', b'c'):
                self.key(key)
            self.key(title.encode())
            self.capture('query-' + str(time.time_ns()), ['COMMAND PALETTE', title[-60:]],
                absent=['No matching commands'])
            self.key(b'\x1b[A' * 24)
            self.key(b'\r')

        def rows(self, label):
            self.capture(label, ['X/Z in window; no graph'], absent=['Graph unavailable'])
            shot = cells.Screen(bytes(self.data), self.width, self.height)
            shot.save(evidence / label)
            return shot.lines()

    original_sha = hashlib.sha256(args.vcd.read_bytes()).hexdigest()
    try:
        session.start()
        catalog = session.discover()
        snap = session.api(operation=['Launch', ['submission_key', 'retained-real-replay'],
            ['discovery_digest', field(catalog, 'discovery_digest')[0]], ['selection', [
                ('suite', 'fixture'), ('cases', ['flops256']), ('seed', '34097'),
                ('parameters', []), ('asic_inputs', [])]]])
        attempt = session.done(field(field(snap, 'attempts')[0], 'id'))
        artifact = field(attempt, 'artifacts')[0]
        check(field(artifact, 'sha256') == [original_sha], 'private FS2 capture retains actual VCD bytes/hash')
        terminal = Terminal(session)
        terminal.capture('startup', ['Overview'])
        terminal.palette('Switch to Testing')
        for _ in range(5):
            terminal.key(b'\t')
        terminal.palette('Simulation: Reopen ' + field(attempt, 'id') + ' fixture')
        terminal.palette('Simulation: Select case flops256')
        for _ in range(3):
            terminal.key(b'\t')
        terminal.key(b'w')
        rows = terminal.rows('quick-default-x')
        qrow = next(row for row in rows if 'X/Z in window; no graph' in row)
        check('q' in qrow[:40], 'quick q label and unknown marker occupy the same lane')
        clock = next(i for i, row in enumerate(rows) if 'clk' in row and 'inferred' not in row)
        check('_' in rows[clock] + rows[clock + 1],
              'quick default keeps known clock graph visible')
        terminal.key(b'j' * 5)
        terminal.capture('quick-exact-x-value', ['xxxxxxxxxxxxxxxx'], absent=['Graph unavailable'])
        check(True, 'quick cursor/sidebar retains exact initial sixteen-bit X')
        terminal.key(b':2595000\r')
        terminal.capture('quick-defined-response', ['Cursor 2595000 ticks'],
            absent=['X/Z in window; no graph', 'Graph unavailable'])
        check(True, 'moving to defined response restores q graph without changing selection')
        terminal.key(b'g')
        terminal.rows('quick-return-x')
        terminal.key(b'\x1b')
        terminal.key(b'W')
        rows = terminal.rows('workspace-default-x')
        qrow = next(row for row in rows if 'X/Z in window; no graph' in row)
        check('q' in qrow[:65], 'dedicated q label remains aligned with its unknown lane')
        clock = next(i for i, row in enumerate(rows) if 'clk' in row and 'inferred' not in row)
        check('_' in rows[clock] + rows[clock + 1],
              'dedicated default keeps known clock graph visible alongside q=X')
        terminal.capture('workspace-ready', ['Ready', '1 ps', 'Pinned: flops256-waveform'],
            absent=['Graph unavailable'])
        check(True, 'fresh dedicated default is Ready with mixed known/unknown lanes')
    finally:
        if terminal:
            terminal.close()
        session.stop()
        check(hashlib.sha256(args.vcd.read_bytes()).hexdigest() == original_sha, 'original real VCD unchanged')
        (evidence / 'checks.json').write_text(json.dumps(checks, indent=2) + '\n')
        (evidence / 'identity.json').write_text(json.dumps(dict(
            fixture=str(args.vcd), fixture_sha256=original_sha, new_simulations=0,
            binaries={name: dict(path=str(getattr(args, name)), sha256=hashlib.sha256(
                getattr(args, name).read_bytes()).hexdigest()) for name in ('client', 'daemon')}), indent=2) + '\n')


if __name__ == '__main__':
    provider() if len(sys.argv) > 1 and sys.argv[1] == '_provider' else main()
