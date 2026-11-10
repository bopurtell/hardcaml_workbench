#!/usr/bin/env python3
"""A's focused production PTY replay of retained bytes; never simulates/builds.

C owns the separate combined-session integration acceptance.
"""
import argparse
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import struct
import sys
import tempfile
import termios
import time

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


replay = load('development_replay', ROOT / 'terminal/test_waveform_mixed_rows_pty.py')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('daemon', 'client', 'vcd'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--period', type=int, required=True)
    parser.add_argument('--last', type=int, required=True)
    parser.add_argument('--response', type=int)
    parser.add_argument('--binary-value')
    parser.add_argument('--media-type', default='text/vcd')
    args = parser.parse_args()
    for name in ('daemon', 'client', 'vcd'):
        setattr(args, name, getattr(args, name).resolve(strict=True))
    evidence = Path(tempfile.mkdtemp(prefix='development-waveform-a-', dir='/tmp/opencode'))
    print('Evidence: ' + str(evidence), flush=True)
    native = load('development_native', ROOT / 'scripts/test-fs2-native.py')
    field, wire = native.field, replay.wire
    for name in ('project', 'state', 'home', 'config', 'tmp'):
        (evidence / name).mkdir()
    project = evidence / 'project'
    (project / 'dune-project').write_text('(lang dune 3.22)\n(name waveform_replay)\n')
    (project / 'hardcaml-workbench-simulation.sexp').write_text(wire.sexp([
        ('schema_version', 1), ('provider_executable', sys.executable),
        ('provider_args', [str(Path(__file__).resolve()), '_provider', '--vcd', str(args.vcd), '--media-type', args.media_type]),
        ('discovery_timeout_seconds', 10), ('run_timeout_seconds', 30)]))
    session = native.Session(args, evidence, project)
    session.env.update(HOME=str(evidence / 'home'), XDG_CONFIG_HOME=str(evidence / 'config'),
        TMPDIR=str(evidence / 'tmp'), PYTHONDONTWRITEBYTECODE='1')
    checks, terminal = [], None
    original = hashlib.sha256(args.vcd.read_bytes()).hexdigest()

    class Terminal(native.Terminal):
        width, height = 120, 40

        def drain(self, seconds=.3):
            super().drain(seconds)
            return native.fs0.terminal_screen(bytes(self.data), width=self.width, height=self.height)

        def palette(self, title):
            for key in (b' ', b'c', b'c'):
                self.key(key)
            self.key(title.encode())
            self.capture('palette-' + str(time.time_ns()), ['COMMAND PALETTE', title[-60:]],
                absent=['No matching commands'])
            self.key(b'\x1b[A' * 24)
            self.key(b'\r')

        def resize(self, width):
            self.width = width
            fcntl.ioctl(self.master, termios.TIOCSWINSZ, struct.pack('HHHH', self.height, width, 0, 0))
            os.kill(self.process.pid, signal.SIGWINCH)
            self.drain(.3)

    def check(label, expected, absent=('Graph unavailable',)):
        text = terminal.capture(label, expected, absent=list(absent))
        checks.append(dict(passed=True, label=label))
        print('PASS ' + label, flush=True)
        return text

    try:
        session.start()
        catalog = session.discover()
        snapshot = session.api(operation=['Launch', ['submission_key', 'retained-replay'],
            ['discovery_digest', field(catalog, 'discovery_digest')[0]], ['selection', [
                ('suite', 'fixture'), ('cases', ['flops256']), ('seed', '34097'),
                ('parameters', []), ('asic_inputs', [])]]])
        attempt = session.done(field(field(snapshot, 'attempts')[0], 'id'))
        assert field(field(attempt, 'artifacts')[0], 'sha256') == [original]
        assert field(field(attempt, 'artifacts')[0], 'media_type') == args.media_type
        terminal = Terminal(session)
        check('startup', ['Overview'])
        terminal.palette('Switch to Testing')
        terminal.key(b'\t' * 5)
        terminal.palette('Simulation: Reopen ' + field(attempt, 'id') + ' fixture')
        terminal.palette('Simulation: Select case flops256')
        terminal.key(b'\t' * 3)
        terminal.key(b'w')
        extent = min(args.last, 8 * args.period)
        text = check('default-eight-periods', ['8 cycles', 'window 0..' + str(extent)])
        clock_row = next(line for line in text.splitlines()
            if ('clk' if args.response is not None else '-clock') in line and '|' in line and '_' in line)
        assert '|' in clock_row and '_' in clock_row, clock_row
        if args.response is not None:
            assert 'X/Z in window; no graph' in text
        terminal.key(b'f')
        check('fit-full-trace', ['Fit full trace', 'window 0..' + str(args.last), 'Compressed', '###'])
        terminal.resize(230)
        check('resize-preserves-fit', ['window 0..' + str(args.last), 'Fit full trace'])
        terminal.palette('Waveform: Default extent')
        check('palette-default', ['8 cycles', 'window 0..' + str(extent)])
        terminal.palette('Waveform: Fit full trace')
        check('palette-fit', ['Fit full trace', 'window 0..' + str(args.last)])
        if args.response is not None:
            terminal.key((':' + str(args.response) + '\r').encode())
            expected = ['Cursor ' + str(args.response) + ' ticks']
            if args.binary_value:
                terminal.key(b'j' * 5)
                expected.append(args.binary_value)
            check('exact-response', expected)
            terminal.key(b'l')
            check('one-original-tick', ['Cursor ' + str(args.response + 1) + ' ticks'])
        terminal.key(b'\x1b')
        terminal.key(b'W')
        check('dedicated-ready', ['Ready', 'Pinned:'])
        terminal.palette('Waveform: Default extent')
        check('dedicated-default', ['8 cycles', 'window 0..' + str(extent)])
        terminal.palette('Waveform: Fit full trace')
        check('dedicated-fit', ['Fit full trace', 'window 0..' + str(args.last)])
    finally:
        if terminal:
            terminal.close()
        session.stop()
        assert hashlib.sha256(args.vcd.read_bytes()).hexdigest() == original
        (evidence / 'receipt.json').write_text(json.dumps(dict(checks=checks,
            fixture=str(args.vcd), fixture_sha256=original, media_type=args.media_type, new_simulations=0,
            binaries={name: dict(path=str(getattr(args, name)), sha256=hashlib.sha256(
                getattr(args, name).read_bytes()).hexdigest()) for name in ('client', 'daemon')}), indent=2) + '\n')


if __name__ == '__main__':
    replay.provider() if len(sys.argv) > 1 and sys.argv[1] == '_provider' else main()
