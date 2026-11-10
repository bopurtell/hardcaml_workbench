#!/usr/bin/env python3
"""Private native HTTP + actual terminal PTY FS2 acceptance, no implicit builds.

Run inside the selected opam environment. --daemon/--client must already exist.
All provider children are PDK-free. Evidence and altered artifact copies belong
only to this test's private /tmp/opencode tree. No sibling projects are modified.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import sys
import tempfile
import time
import traceback
import urllib.error
import urllib.request

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / 'fixtures'))
from fs2_wire import sexp, record, parse
sys.path.insert(0, str(HERE.parent / 'test'))
from support.terminal import Terminal as SharedTerminal


def load_module(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


fs0 = load_module('fs0', 'test-fs0.py')
field, require = fs0.field, fs0.require


class Session(fs0.Session):
    def raw(self, path, data=None):
        request = urllib.request.Request(self.url + path, data=None if data is None else sexp(data).encode(),
            headers={'Content-Type': 'application/sexp', 'X-Workbench-Protocol': '1'})
        try:
            response = urllib.request.urlopen(request, timeout=30)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            text = response.read().decode()
            status = response.status
        with (self.evidence / 'raw-http.jsonl').open('a') as out:
            out.write(json.dumps(dict(path=path, request=data, status=status, response=text)) + '\n')
        return parse(text)

    def start(self):
        super().start()
        hello = self.raw('/api/hello')
        require('simulation' in field(hello, 'capabilities'), 'native simulation capability')
        opened = self.raw('/api/v1/open-project', [
            ('instance_id', self.metadata['instance_id']), ('root', str(self.root)),
            ('environment', 'Inherit_daemon')])
        require(opened[0] == 'Ok', str(opened))
        self.project = field(field(opened[1], 'project'), 'id')

    def api(self, domain='simulation', operation='Get', error=None):
        response = self.raw('/api/v1/' + domain, [
            ('instance_id', self.metadata['instance_id']), ('project', self.project),
            ('operation', operation)])
        if error:
            require(response[0] == 'Error' and field(response[1], 'kind') == error,
                    'Expected ' + error + ': ' + str(response))
        else:
            require(response[0] == 'Ok', str(response))
        return response[1]

    def until(self, operation, predicate, timeout=20):
        deadline = time.monotonic() + timeout
        while True:
            snap = self.api(operation=operation)
            if predicate(snap):
                return snap
            require(time.monotonic() < deadline, 'RPC polling deadline: ' + str(snap))
            time.sleep(.08)

    def discover(self):
        snap = self.api(operation='Discover')
        job = field(snap, 'discovery_job')[0]
        deadline = time.monotonic() + 20
        while True:
            response = self.raw('/api/v1/snapshot', [('instance_id', self.metadata['instance_id'])])
            require(response[0] == 'Ok', str(response))
            found = next(j for j in field(response[1], 'jobs') if field(j, 'id') == job)
            if field(found, 'state') in ('Complete', 'Failed', 'Cancelled'):
                return self.api()
            require(time.monotonic() < deadline, 'discovery job deadline')
            time.sleep(.08)

    def done(self, attempt):
        snap = self.until(['Observe', attempt], lambda s: field(field(s, 'detail')[0], 'lifecycle')
                          not in ('Queued', 'Running'))
        return field(snap, 'detail')[0]


class Terminal(SharedTerminal):
    def key(self, key):
        os.write(self.master, key)
        self.drain(.15)

    def palette(self, title):
        # Separate leader keys and acknowledge each input phase.
        self.drain(.2)
        for key in (b' ', b'c', b'c'):
            self.key(key)
        self.capture('palette-open-' + str(time.time_ns()), ['COMMAND'])
        self.key(title.encode())
        # The bounded overlay shows a cell-clipped command and the tail of a
        # long query (notably exact 64-hex simulation IDs). Fence both the
        # result's action prefix and query's identifying suffix. The caller's
        # subsequent attempt/selection/export assertions verify actual execution.
        self.capture('palette-query-' + str(time.time_ns()),
                     ['COMMAND PALETTE', title[:40], title[-60:]])
        self.key(b'\r')


def run(args):
    evidence = args.evidence
    root = evidence / 'project'; root.mkdir()
    (root / 'dune-project').write_text('(lang dune 3.22)\n(name fs2_native_acceptance)\n')
    (evidence / 'state').mkdir()
    for name in ('home', 'config', 'tmp'):
        (evidence / name).mkdir()
    control = evidence / 'control.json'
    calls = evidence / 'calls.jsonl'

    def mode(value):
        control.write_text(json.dumps(dict(mode=value)))

    def configure(real=False):
        prefix = [str(HERE.parent / 'examples/fs2_cyclesim/provider.py'), '--counter', str(args.counter), '--calls', str(calls)] if real else [
            str(HERE / 'fixtures/fs2_provider.py'), '--control', str(control), '--calls', str(calls)]
        cfg = [('schema_version', 1), ('provider_executable', sys.executable), ('provider_args', prefix),
               ('discovery_timeout_seconds', 10), ('run_timeout_seconds', 90)]
        (root / 'hardcaml-workbench-simulation.sexp').write_text(sexp(cfg))

    mode('pass'); configure()
    session = Session(args, evidence, root)
    session.env.update(HOME=str(evidence / 'home'), XDG_CONFIG_HOME=str(evidence / 'config'),
        TMPDIR=str(evidence / 'tmp'), OMP_NUM_THREADS='6', OPENROAD_THREADS='6',
        _OPENLANE_MAX_CORES='6', PYTHONDONTWRITEBYTECODE='1')
    terminal = None
    result = dict(status='failed', checks=[])

    def check(ok, message):
        result['checks'].append(dict(passed=bool(ok), expectation=message))
        require(ok, message)

    def launch(key, digest, suite='fixture', cases=('first', 'second'), params=(), seed='18446744073709551615'):
        return ['Launch', ['submission_key', key], ['discovery_digest', digest], ['selection', [
            ('suite', suite), ('cases', list(cases)), ('seed', seed), ('parameters', list(params)), ('asic_inputs', [])]]]

    def allocate(op):
        return field(session.api(operation=op), 'detail')[0]

    def export(attempt, artifact):
        data = bytearray(); offset = 0
        sha = field(artifact, 'sha256')[0]
        while True:
            op = ['Read_artifact_bytes', ['attempt_id', field(attempt, 'id')],
                  ['artifact_id', field(artifact, 'id')], ['sha256', sha], ['offset', offset], ['limit', 997]]
            snap = session.api(operation=op)
            page = field(snap, 'byte_page')[0]
            raw = bytes.fromhex(field(page, 'bytes_hex'))
            require(int(field(page, 'offset')) == offset and int(field(page, 'next_offset')) == offset + len(raw), 'byte-page offsets')
            data.extend(raw); offset += len(raw)
            if field(page, 'eof') == 'true':
                require(offset == int(field(page, 'total_size')), 'byte-page total')
                break
            require(raw, 'non-EOF page advances')
        check(hashlib.sha256(data).hexdigest() == sha, 'paged raw trace SHA256 matches catalog')
        return bytes(data)

    def call_bytes():
        return calls.read_bytes() if calls.exists() else b''

    try:
        session.start()
        check(not (root / 'hardcaml-workbench-asic.sexp').exists(), 'project-only configuration has no ASIC dependency')
        snap = session.discover(); digest = field(snap, 'discovery_digest')[0]
        op = launch('dedup', digest)
        original = allocate(op); oid = field(original, 'id')
        retry = allocate(op)
        check(field(retry, 'id') == oid and field(retry, 'job') == field(original, 'job'), 'same submission key allocates once')
        reordered = allocate(launch('dedup', digest, cases=['second', 'first']))
        check(field(reordered, 'id') == oid, 'equivalent reordered selection deduplicates after normalization')
        session.api(operation=launch('dedup', digest, seed='43'), error='Conflict')
        session.api(operation=launch('stale-digest', '0' * 64), error='Conflict')
        original = session.done(oid)
        check(field(original, 'outcome') == 'Passed' and field(original, 'exit_code') == ['0'], 'semantic pass requires successful process')
        fixture_raw = export(original, field(original, 'artifacts')[0])
        check(fixture_raw == bytes(range(256)) * 300 + b'\x00\xff\r\nFS2\n', 'multi-page binary trace preserves NUL/non-UTF8/CRLF exactly')
        check(len([json.loads(line) for line in call_bytes().splitlines() if json.loads(line)['operation'] == 'run']) == 1, 'one actual provider launch for idempotent retries')
        parent_selection = field(field(original, 'captured'), 'selection')
        rerun_op = ['Rerun', ['submission_key', 'targeted'], ['attempt_id', oid], ['cases', ['second']]]
        rerun = allocate(rerun_op)
        rerun = session.done(field(rerun, 'id'))
        selection = record(field(field(rerun, 'captured'), 'selection'))
        check(field(rerun, 'id') != oid and field(rerun, 'job') != field(original, 'job') and
              field(rerun, 'parent') == [[['attempt_id', oid], ['job', field(original, 'job')]]] and
              selection == dict(record(parent_selection), cases=['second']), 'targeted rerun has distinct attempt/job, exact immediate parent and preserved inputs')
        check(field(allocate(rerun_op), 'id') == field(rerun, 'id'), 'rerun retry deduplicates')
        for bad in ('fail', 'malformed', 'duplicate', 'truncated', 'gap', 'wrong-attempt', 'missing-finished', 'post-finished', 'nonzero', 'missing-artifact'):
            mode(bad)
            d = allocate(launch('mode-' + bad, digest)); d = session.done(field(d, 'id'))
            expected = 'Failed' if bad == 'fail' else 'Passed' if bad == 'missing-artifact' else 'Incomplete'
            check(field(d, 'outcome') == expected, bad + ': honest ' + expected + ' outcome')
            if bad == 'fail':
                check(field(d, 'exit_code') == ['0'] and any(field(c, 'status') == 'Failed' for c in field(d, 'cases')),
                      'semantic failure separate from process exit with failure report')
            if bad == 'missing-artifact':
                check(any(field(a, 'availability') != 'Available' for a in field(d, 'artifacts')), 'missing provider file is explicit')
        mode('cancel')
        active = allocate(launch('cancel', digest)); aid = field(active, 'id')
        live = session.until(['Observe', aid], lambda s: any(field(c, 'status') == 'Passed' for c in field(field(s, 'detail')[0], 'cases')))
        check(any(field(c, 'progress') for c in field(field(live, 'detail')[0], 'cases')), 'live structured indeterminate progress visible before cancellation')
        session.api(operation=['Cancel', aid]); cancelled = session.done(aid)
        check(field(cancelled, 'lifecycle') == 'Cancelled' and field(cancelled, 'outcome') == 'Incomplete' and
              [field(c, 'status') for c in field(cancelled, 'cases')] == ['Passed', 'Incomplete'], 'cancel preserves finished case and marks unfinished case incomplete')
        mode('discovery-mismatch'); session.discover()
        session.api(operation=['Rerun', ['submission_key', 'mismatch'], ['attempt_id', oid], ['cases', ['first']]], error='Invalid_request')
        check(True, 'current discovery mismatch blocks rerun')
        mode('discovery-malformed'); bad_catalog = session.discover()
        check(bool(field(bad_catalog, 'discovery_error')), 'malformed discovery is explicit')
        check(bool(field(bad_catalog, 'discovery')), 'failed refresh preserves previous catalog')
        mode('discovery-version'); bad_version = session.discover()
        check(bool(field(bad_version, 'discovery_error')), 'wrong discovery version is explicit')
        mode('cancel'); fixture_catalog = session.discover()
        interrupted = allocate(launch('interrupted', field(fixture_catalog, 'discovery_digest')[0]))
        interrupted_id = field(interrupted, 'id')
        session.until(['Observe', interrupted_id], lambda s: any(field(c, 'status') == 'Passed' for c in field(field(s, 'detail')[0], 'cases')))
        before_restart = call_bytes()
        # SIGKILL specifically tests unclean interruption; normal daemon SIGTERM
        # honestly cancels active jobs and persists Cancelled instead.
        producer = next(json.loads(line) for line in before_restart.splitlines() if
            json.loads(line)['operation'] == 'run' and
            field(json.loads(line)['request'], 'attempt_id') == interrupted_id)
        session.process.kill(); session.process.wait(timeout=10); session.stop()
        require(producer['pgid'] != os.getpgrp(), 'fixture owns a distinct supervised process group')
        try:
            os.killpg(producer['pgid'], signal.SIGKILL)
        except ProcessLookupError:
            pass
        session.start()
        interrupted = field(session.api(operation=['Observe', interrupted_id]), 'detail')[0]
        check(field(interrupted, 'lifecycle') == 'Interrupted' and field(interrupted, 'outcome') == 'Incomplete' and
              [field(c, 'status') for c in field(interrupted, 'cases')] == ['Passed', 'Incomplete'] and call_bytes() == before_restart,
              'daemon restart preserves partial results as Interrupted without replay')
        mode('pass'); configure(real=True)
        real_catalog = session.discover(); real_digest = field(real_catalog, 'discovery_digest')[0]
        params = [('cycles', '64'), ('step', '3'), ('inject_failure', 'false')]
        real = allocate(launch('real-cyclesim', real_digest, 'counter', ['wrap', 'reset', 'seeded'], params))
        real = session.done(field(real, 'id'))
        check(field(real, 'outcome') == 'Passed', 'actual Hardcaml Cyclesim passes through native daemon')
        wave = next(a for a in field(real, 'artifacts') if field(a, 'kind') == 'waveform')
        raw = export(real, wave)
        check(b'$enddefinitions' in raw and b'count' in raw, 'native raw trace is actual counter VCD')
        (evidence / 'trace.vcd').write_bytes(raw)
        real_rerun = allocate(['Rerun', ['submission_key', 'real-targeted'], ['attempt_id', field(real, 'id')], ['cases', ['seeded']]])
        real_rerun = session.done(field(real_rerun, 'id'))
        check(field(real_rerun, 'outcome') == 'Passed' and field(real_rerun, 'parent') and
              field(field(field(real_rerun, 'captured'), 'selection'), 'parameters') == field(field(field(real, 'captured'), 'selection'), 'parameters'),
              'actual targeted Cyclesim rerun retains explicit seed/parameters and parent')
        if not args.skip_pty:
            terminal = pty_acceptance(session, real, real_rerun, wave, raw, check)
            terminal.close(); terminal = None
        before = call_bytes()
        old_instance = session.metadata['instance_id']
        session.stop(); session.start()
        restored = field(session.api(operation=['Observe', oid]), 'detail')[0]
        check(session.metadata['instance_id'] != old_instance and field(restored, 'captured') == field(original, 'captured') and
              field(restored, 'outcome') == 'Passed', 'durable history reopens with original inputs after daemon restart')
        history = session.api(operation=['History', ['before', []], ['limit', 2]])
        check(len(field(history, 'attempts')) == 2 and bool(field(history, 'next_before')), 'bounded history page and continuation')
        older = session.api(operation=['History', ['before', field(history, 'next_before')], ['limit', 2]])
        check(not ({field(a, 'id') for a in field(history, 'attempts')} & {field(a, 'id') for a in field(older, 'attempts')}), 'history continuation has no duplicate attempts')
        check(field(allocate(op), 'id') == oid, 'durable key retry returns original attempt before changed catalog/config validation')
        export(real, wave)
        check(call_bytes() == before, 'restart/Get/Observe/History/artifact reads never launch fixture tools')
        # Corrupt only this daemon's private copied trace, keeping provider source intact.
        sha = field(wave, 'sha256')[0]
        stored = [p for p in session.state_dir.rglob('*.bytes') if hashlib.sha256(p.read_bytes()).hexdigest() == sha]
        require(stored, 'owned artifact copy found by byte hash')
        for path in stored:
            path.write_bytes(b'changed privately')
        read = ['Read_artifact_bytes', ['attempt_id', field(real, 'id')], ['artifact_id', field(wave, 'id')],
                ['sha256', sha], ['offset', 0], ['limit', 100]]
        session.api(operation=read, error='Conflict')
        check(True, 'changed durable artifact bytes rejected explicitly')
        for path in stored:
            path.unlink()
        session.api(operation=read, error='Not_found')
        check(True, 'missing durable artifact bytes rejected explicitly')
        before = call_bytes()
        original_records = list(session.state_dir.rglob(oid + '/record.sexp'))
        require(len(original_records) == 1, 'exact original private durable record')
        session.stop()
        original_records[0].write_text('(corrupt durable record')
        session.start()
        corrupted = session.api()
        session.api(operation=['Observe', oid], error='Not_found')
        check(bool(field(corrupted, 'history_error')) and call_bytes() == before,
              'corrupt private history record skipped with diagnostic and no provider replay')
        result.update(status='passed', real_attempt=real, trace_sha256=sha, provider_calls=len(call_bytes().splitlines()))
    except BaseException:
        result['error'] = traceback.format_exc()
        raise
    finally:
        if terminal:
            terminal.close()
        if session.process:
            session.stop()
        (evidence / 'result.json').write_text(json.dumps(result, indent=2))


def pty_acceptance(session, real, rerun, wave, raw, check):
    def mutate(mutation):
        ws = session.api(domain='workspace')
        return session.api(domain='workspace', operation=['Mutate', ['expected_revision', field(ws, 'revision')], ['mutation', mutation]])

    ws = session.api(domain='workspace')
    ws = mutate(['Create_workspace', ['window', field(field(ws, 'windows')[0], 'id')], ['name', 'FS2 acceptance'], ['context', field(ws, 'main_context')]])
    workspace = field(ws, 'workspaces')[-1]
    wid = field(workspace, 'id')
    tiles = []
    for x in (0, 60):
        ws = mutate(['Create_tile', ['workspace', wid], ['kind', 'simulation'],
                     ['geometry', [('x', x), ('y', 0), ('width', 59), ('height', 36)]]])
        tiles.append(field(field(ws, 'tiles')[-1], 'id'))
    mutate(['Set_zoom', ['workspace', wid], ['tile', [tiles[0]]]])
    viewer = session.evidence / 'record-viewer.py'
    viewer.write_text('#!' + sys.executable + '\nimport hashlib,json,pathlib,sys\np=pathlib.Path(sys.argv[1])\n' +
        'pathlib.Path(' + repr(str(session.evidence / 'viewer.json')) + ').write_text(json.dumps(dict(argv=sys.argv,path=str(p),sha256=hashlib.sha256(p.read_bytes()).hexdigest())))\n')
    viewer.chmod(0o700)
    wrapper = session.evidence / 'client-with-viewer'
    wrapper.write_text('#!' + sys.executable + '\nimport os,sys\nos.execv(' + repr(str(session.args.client)) + ', [' +
        repr(str(session.args.client)) + ', "--simulation-viewer", ' + repr(str(viewer)) + '] + sys.argv[1:])\n')
    wrapper.chmod(0o700)
    old_client = session.args.client; session.args.client = wrapper
    terminal = Terminal(session)
    session.args.client = old_client
    try:
        terminal.capture('pty-startup', ['Overview'])
        terminal.palette('Switch to FS2 acceptance')
        terminal.capture('pty-simulation', ['Structured simulation'])
        known = {field(a, 'id') for a in field(session.api(), 'attempts')}
        terminal.palette('Simulation: Launch form counter')
        for label, value in [('CASES', 'seeded'), ('SEED', '987654321'),
                             ('PARAMETER cycles', '48'), ('PARAMETER step', '7'),
                             ('PARAMETER inject_failure', 'true')]:
            terminal.capture('pty-form-' + label.replace(' ', '-'), [label])
            terminal.key(b'\x15')
            terminal.key(value.encode())
            terminal.key(b'\r')
        terminal.capture('pty-form-confirm', ['CONFIRM', '987654321', 'inject_failure'])
        terminal.key(b'\r')
        submitted = session.until('Get', lambda s: any(field(a, 'id') not in known for a in field(s, 'attempts')))
        form_attempt = next(a for a in field(submitted, 'attempts') if field(a, 'id') not in known)
        form_attempt = session.done(field(form_attempt, 'id'))
        form_selection = field(field(form_attempt, 'captured'), 'selection')
        check(field(form_attempt, 'outcome') == 'Failed' and field(form_attempt, 'exit_code') == ['0'] and
              field(form_selection, 'seed') == '987654321' and field(form_selection, 'cases') == ['seeded'] and
              dict(field(form_selection, 'parameters')) == dict(cycles='48', step='7', inject_failure='true') and
              any(field(a, 'kind') == 'failure-report' for a in field(form_attempt, 'artifacts')),
              'actual PTY launch form captures edited cases/seed/parameters and real assertion failure/report')
        terminal.capture('pty-semantic-failure', ['Failed', 'Counter reference-model mismatch'])
        terminal.palette('Simulation: Toggle stream-labelled job logs')
        terminal.capture('pty-live-job-logs', ['JOB LOG'])
        terminal.palette('Simulation: Toggle stream-labelled job logs')
        rid = field(real, 'id')
        terminal.palette('Simulation: Reopen ' + rid + ' counter')
        terminal.capture('pty-real', ['Attempt: ' + rid, 'Suite: counter', '18446744073709551615', 'Passed'])
        terminal.palette('Simulation: Select case seeded')
        terminal.capture('pty-case', ['> seeded: Passed'])
        terminal.palette('Simulation: Open external viewer ' + field(wave, 'label'))
        deadline = time.monotonic() + 20
        while not (session.evidence / 'viewer.json').exists():
            terminal.drain(.1)
            require(time.monotonic() < deadline, 'PTY actual viewer handoff deadline')
        receipt = json.loads((session.evidence / 'viewer.json').read_text())
        check(Path(receipt['path']).read_bytes() == raw and receipt['sha256'] == field(wave, 'sha256')[0], 'actual palette export launches recording viewer with byte-exact VCD')
        terminal.palette('Simulation: Rerun case seeded (original inputs; current project)')
        submitted = session.until('Get', lambda s: any(field(a, 'id') not in (rid, field(rerun, 'id')) and
            field(a, 'parent') and field(field(a, 'parent')[0], 'attempt_id') == rid for a in field(s, 'attempts')))
        child = next(a for a in field(submitted, 'attempts') if field(a, 'id') not in (rid, field(rerun, 'id')) and
            field(a, 'parent') and field(field(a, 'parent')[0], 'attempt_id') == rid)
        child = session.done(field(child, 'id'))
        check(field(child, 'outcome') == 'Passed' and
              field(field(field(child, 'captured'), 'selection'), 'cases') == ['seeded'], 'actual PTY targeted rerun submits a distinct linked checked Cyclesim attempt')
        terminal.capture('pty-rerun-complete', ['Attempt: ' + field(child, 'id'), 'Rerun of ' + rid])
        terminal.palette('Simulation: Reopen ' + rid + ' counter')
        terminal.palette('Simulation: Select case seeded')
        terminal.palette('Unzoom workspace'); terminal.key(b'\t'); terminal.palette('Zoom focused tile')
        terminal.palette('Simulation: Reopen ' + field(rerun, 'id') + ' counter')
        terminal.capture('pty-second-tile', ['Attempt: ' + field(rerun, 'id'), 'Rerun of'])
        terminal.palette('Unzoom workspace'); terminal.key(b'\t'); terminal.palette('Zoom focused tile')
        terminal.capture('pty-first-independent', ['Attempt: ' + rid, '> seeded: Passed'])
        check(True, 'two simulation tiles retain independent attempt and case selections')
        return terminal
    except BaseException:
        terminal.save('pty-failure', terminal.drain(.1)); terminal.close(); raise


def main():
    p = argparse.ArgumentParser(description=__doc__)
    build = Path('/tmp/opencode/fs2-build-provider')
    p.add_argument('--daemon', type=Path, default=build / 'native/default/daemon/main.exe')
    p.add_argument('--client', type=Path, default=build / 'native/default/terminal/main.exe')
    p.add_argument('--counter', type=Path, default=build / 'default/counter.exe')
    p.add_argument('--skip-pty', action='store_true', help='HTTP-only diagnostic; full acceptance requires PTY')
    args = p.parse_args()
    for name in ('daemon', 'client', 'counter'):
        setattr(args, name, getattr(args, name).resolve(strict=True))
    os.umask(0o077)
    args.outer_timeout = 30
    args.evidence = Path(tempfile.mkdtemp(prefix='fs2-native-', dir='/tmp/opencode'))
    print('Evidence: ' + str(args.evidence), flush=True)
    signal.signal(signal.SIGALRM, lambda *_: (_ for _ in ()).throw(TimeoutError('acceptance budget exhausted')))
    signal.alarm(300)
    try:
        run(args)
    finally:
        signal.alarm(0)
    print('PASS FS2 native HTTP' + ('' if args.skip_pty else ' + PTY'), flush=True)


if __name__ == '__main__':
    main()
