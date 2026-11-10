#!/usr/bin/env python3
"""FS0 native HTTP/PTY acceptance; stdlib only, retained evidence, no Workbench build.

Run --help for paths and scope. Real flows are strictly serial synthesis-only.
"""
import argparse
import fcntl
import json
import os
from pathlib import Path
import pty
import re
import select
import struct
import subprocess
import sys
import tempfile
import termios
import time
import traceback
import urllib.request

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'test'))
from support.screen import terminal_screen


def parse(text):
    tokens = re.findall(r'\(|\)|"(?:\\.|[^"\\])*"|[^\s()"]+', text)
    pos = 0

    def value():
        nonlocal pos
        token = tokens[pos]
        pos += 1
        if token == '(':
            result = []
            while tokens[pos] != ')':
                result.append(value())
            pos += 1
            return result
        if token.startswith('"'):
            # Sexplib uses three-digit decimal byte escapes, unlike JSON.
            token = re.sub(r'\\([0-9]{3})', lambda m: chr(int(m[1])), token)
            return json.loads(token)
        assert token != ')'
        return token

    result = value()
    assert pos == len(tokens), 'Trailing protocol data'
    return result


def sexp(value):
    if isinstance(value, list):
        return '(' + ' '.join(map(sexp, value)) + ')'
    return json.dumps(str(value), ensure_ascii=True)


def record(value):
    return dict(value)


def field(value, key):
    return record(value)[key]


def require(condition, message):
    if not condition:
        raise AssertionError(message)


class Session:
    def __init__(self, args, evidence, root):
        self.args, self.evidence, self.root = args, evidence, root
        self.process = None
        self.sequence = 0
        self.state_dir = evidence / 'state'
        self.env = dict(os.environ, XDG_STATE_HOME=str(evidence / 'client-state'),
                        OMP_NUM_THREADS='20', OPENROAD_THREADS='20', _OPENLANE_MAX_CORES='20')

    def start(self):
        discovery = self.evidence / ('discovery-' + str(time.time_ns()))
        discovery.mkdir()
        self.log = open(self.evidence / (discovery.name + '.log'), 'wb')
        self.process = subprocess.Popen([str(self.args.daemon), '--port', '0',
                                        '--discovery-dir', str(discovery), '--state-dir',
                                         str(self.state_dir)], env=self.env,
                                       stdout=self.log, stderr=subprocess.STDOUT)
        deadline = time.monotonic() + 20
        metadata = discovery / 'daemon.sexp'
        while not metadata.exists():
            require(self.process.poll() is None, 'Daemon exited; see daemon log')
            require(time.monotonic() < deadline, 'Daemon startup timeout')
            time.sleep(.05)
        self.metadata = record(parse(metadata.read_text()))
        self.url = self.metadata['endpoint']

    def stop(self):
        try:
            if self.process and self.process.poll() is None:
                self.process.terminate()
                try:
                    self.process.wait(timeout=20)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait(timeout=20)
        finally:
            # start may fail before opening the log or after spawning the daemon.
            log = getattr(self, 'log', None)
            if log is not None:
                log.close()

    def command(self, extra, label, timeout=90, success=True):
        self.sequence += 1
        stem = self.evidence / f'{self.sequence:03d}-{label}'
        argv = [str(self.args.client), '--plain', '--project-root', str(self.root),
                '--connect', self.url] + extra
        started = time.monotonic()
        result = subprocess.run(argv, env=self.env, capture_output=True, timeout=timeout)
        stem.with_suffix('.stdout').write_bytes(result.stdout)
        stem.with_suffix('.stderr').write_bytes(result.stderr)
        stem.with_suffix('.json').write_text(json.dumps(dict(argv=argv, returncode=result.returncode,
                                                          seconds=time.monotonic()-started), indent=2))
        if success:
            require(result.returncode == 0, f'{label}: exit {result.returncode}: {result.stderr.decode()} (evidence {stem})')
        return result

    def rpc(self, domain, operation='Get', wait=False, success=True):
        extra = ['--api', '--' + domain + '-operation', operation]
        if wait:
            extra += ['--wait', '--wait-timeout-seconds', str(self.args.outer_timeout)]
        result = self.command(extra, domain, timeout=self.args.outer_timeout + 30, success=success)
        response = parse(result.stdout.decode())
        if success:
            require(response[0] == 'Ok', str(response))
        return response[1]

    def mutate(self, snapshot, mutation):
        return self.rpc('workspace', f'(Mutate (expected_revision {field(snapshot, "revision")}) (mutation {mutation}))')

    def raw(self, path, data=None):
        request = urllib.request.Request(self.url + path, data=None if data is None else sexp(data).encode(),
                                         headers={'Content-Type': 'application/sexp', 'X-Workbench-Protocol': '1'})
        with urllib.request.urlopen(request, timeout=30) as response:
            text = response.read().decode()
        with open(self.evidence / 'raw-http.jsonl', 'a') as out:
            out.write(json.dumps(dict(path=path, request=data, response=text)) + '\n')
        return parse(text)


def write_config(root, project, provider, results, tools=None, stage_timeout=None):
    path = root / 'hardcaml-workbench-asic.sexp'
    if path.exists():
        return False
    values = [['schema_version', '1'], ['project_executable', str(project)],
              ['provider_executable', str(provider)], ['results_root', str(results)],
              ['toolchain', str(tools or root)],
              ['python', [str(tools / '.venv/bin/python')] if tools else []],
              ['support_tools', [str(tools / 'tt')] if tools else []],
              ['pdk_root', [str(tools / 'pdk')] if tools else []],
              ['stage_timeout_seconds', [str(stage_timeout)] if stage_timeout else []]]
    # Exclusive creation preserves an existing config, including concurrent creation.
    with path.open('x') as out:
        out.write(sexp(values) + '\n')
    return True


def pty_check(session):
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 120, 0, 0))
    process = subprocess.Popen([str(session.args.client), '--connect', session.url,
                                '--project-root', str(session.root)], stdin=slave, stdout=slave,
                               stderr=slave, env=dict(session.env, TERM='xterm-256color'), start_new_session=True)
    os.close(slave)
    chunks = []

    def drain(seconds):
        end = time.monotonic() + seconds
        data = b''
        while time.monotonic() < end:
            if select.select([master], [], [], .05)[0]:
                try:
                    data += os.read(master, 65536)
                except OSError:
                    break
        chunks.append(data)
        return data

    try:
        initial = drain(3)
        require(b'Overview' in initial, 'PTY did not render workspace host')
        before = session.rpc('workspace')
        for key in (b' ', b'c', b'c'):
            os.write(master, key)
            drain(.2)
        os.write(master, b'Make workspace independent')
        palette = drain(.8)
        require(b'independent' in palette.lower(), 'PTY palette did not render filtered command')
        os.write(master, b'\r')
        drain(2)
        after = session.rpc('workspace')
        require(int(field(after, 'revision')) > int(field(before, 'revision')), 'PTY Enter did not submit mutation')
        require(field(field(after, 'workspaces')[0], 'context') != field(after, 'main_context'),
                'PTY command did not make Overview independent')
        # Appearance is client-local: exercise real palette dispatch for every skin,
        # then verify its active marker and unchanged authoritative workspace state.
        appearance_before = after
        calls_path = session.root / 'calls'
        calls_before = calls_path.read_bytes() if calls_path.exists() else b''
        for label in ('A - Instrument', 'B - Structured', 'C - Minimal',
                      'D - Studio', 'E - Structured studio'):
            for key in (b' ', b'c', b'c'):
                os.write(master, key)
                drain(.1)
            os.write(master, ('Appearance: ' + label).encode())
            drain(.2)
            os.write(master, b'\r')
            drain(.3)
            for key in (b' ', b'c', b'c'):
                os.write(master, key)
                drain(.1)
            os.write(master, ('Appearance: ' + label).encode())
            selected = drain(.3)
            require((label + ' [active]').encode() in selected,
                    'Appearance selection was not applied: ' + label)
            os.write(master, b'\x1b')
            drain(.1)
        require(session.rpc('workspace') == appearance_before,
                'Appearance changed authoritative contexts/layout/pins')
        require((calls_path.read_bytes() if calls_path.exists() else b'') == calls_before,
                'Appearance dispatched provider commands')
        for key in (b'2', b'\t', b'j', b'k', b'1'):
            os.write(master, key)
            drain(.15)
        os.write(master, b'q')
        process.wait(timeout=5)
        require(process.returncode == 0, 'PTY client failed')
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=10)
        os.close(master)
        (session.evidence / 'pty.ansi').write_bytes(b''.join(chunks))


def exercise(session, fixture):
    session.start()
    try:
        if fixture:
            result = session.command(['--action', 'test', '--wait'], 'generic-test')
            require(b': Complete' in result.stdout and
                    (session.root / '_build/default/generic-passed').read_text() == 'passed',
                    'Generic test did not succeed')
            pty_check(session)
        discover = session.rpc('asic', 'Discover', wait=True)
        require(any(field(f, 'id') == 'standard' for f in field(discover, 'flows')), 'Missing standard flow')
        session.rpc('asic', '(Describe standard)', wait=True)
        runs, summaries = [], []
        for profile in ('balanced', 'synth_delay'):
            planned = session.rpc('asic', f'(Plan ((flow standard) (profile {profile}) (endpoint synthesis) (assignments ())))', wait=True)
            preview = field(planned, 'preview')[0]
            # This client exits immediately; subsequent clients reconnect to daemon-owned work.
            launched = session.rpc('asic', f'(Run (key fs0-{profile}) (preview {sexp(preview)}))')
            deadline = time.monotonic() + min(60, session.args.outer_timeout)
            while True:
                operation = next(o for o in field(launched, 'operations') if field(o, 'key') == f'run:fs0-{profile}')
                require(field(operation, 'state') not in ('failed', 'detached'),
                        f'{profile} launch failed: {sexp(operation)}')
                allocated = [r for r in field(launched, 'runs')
                             if field(r, 'selection') and field(field(r, 'selection')[0], 'profile') == profile]
                if allocated or field(operation, 'state') == 'completed' or time.monotonic() >= deadline:
                    break
                time.sleep(.2)
                launched = session.rpc('asic')
            progress = dict(profile=profile, allocated=bool(allocated),
                            launcher_state=field(operation, 'state'), snapshot=launched)
            (session.evidence / f'{profile}-early-allocation.json').write_text(json.dumps(progress, indent=2))
            print(f'{session.evidence.name}/{profile}: allocation={bool(allocated)}, launcher={field(operation, "state")}', flush=True)
            launched = session.rpc('asic', 'Get', wait=True)
            operation = next(o for o in field(launched, 'operations') if field(o, 'key') == f'run:fs0-{profile}')
            require(field(operation, 'state') == 'completed', f'Launch did not complete: {sexp(operation)}')
            matched = [r for r in field(launched, 'runs') if field(field(r, 'selection')[0], 'profile') == profile]
            require(len(matched) == 1, 'Expected one allocated run per profile')
            run = field(matched[0], 'run')
            loaded = session.rpc('asic', f'(Load_summary {sexp(run)})', wait=True)
            summary = next(s for s in field(loaded, 'summaries') if field(s, 'run') == run)
            require(field(summary, 'completion') == 'completed', 'Incomplete synthesis')
            require(field(summary, 'acceptance') == 'not_evaluated', 'Unexpected acceptance')
            require(field(summary, 'cell_count'), 'Missing count')
            if fixture:
                require(field(summary, 'cell_count') == ['50' if profile == 'balanced' else '73'],
                        'Incorrect fixture profile count')
            runs.append(run)
            summaries.append(summary)
            duplicate = session.rpc('asic', f'(Run (key fs0-{profile}) (preview {sexp(preview)}))', wait=True)
            require(len(field(duplicate, 'runs')) == len(runs), 'Duplicate launch allocated another run')
        ws = session.rpc('workspace')
        overview, timing = field(ws, 'workspaces')[:2]
        main = field(ws, 'main_context')
        ws = session.mutate(ws, f'(Link_context (workspace {field(overview, "id")}) (context {main}))')
        ws = session.mutate(ws, f'(Link_context (workspace {field(timing, "id")}) (context {main}))')
        context = next(c for c in field(ws, 'contexts') if field(c, 'id') == main)
        ws = session.mutate(ws, f'(Select_run (workspace {field(overview, "id")}) (context {main}) (expected_selection_revision {field(context, "selection_revision")}) (run ({sexp(runs[0])})))')
        ws = session.mutate(ws, f'(Make_independent {field(timing, "id")})')
        independent = field(field(ws, 'workspaces')[1], 'context')
        ws = session.mutate(ws, f'(Select_run (workspace {field(timing, "id")}) (context {independent}) (expected_selection_revision 0) (run ({sexp(runs[1])})))')
        tile = field(field(ws, 'tiles')[0], 'id')
        ws = session.mutate(ws, f'(Set_tile_binding (tile {tile}) (binding (Pin_run {sexp(runs[0])})))')
        ws = session.mutate(ws, f'(Move_tile (tile {tile}) (workspace {field(timing, "id")}))')
        conflict = session.rpc('workspace', '(Mutate (expected_revision 0) (mutation (Make_independent workspace-4)))', success=False)
        require(field(conflict, 'kind') == 'Conflict', 'Stale workspace CAS was not rejected')
        calls = session.root / 'calls'

        def report_count():
            return sum(json.loads(line)[:1] == ['report'] for line in calls.read_text().splitlines()) if fixture else None

        before = report_count()
        for _ in range(3):
            for run in runs:
                warm = session.rpc('asic', f'(Load_summary {sexp(run)})', wait=True)
                actual = next(s for s in field(warm, 'summaries') if field(s, 'run') == run)
                require(actual == summaries[runs.index(run)], 'Warm summary changed identity/data')
        require(report_count() == before, 'Warm switching requested extra reports')
        old_instance = session.metadata['instance_id']
        session.stop()
        session.start()
        require(session.metadata['instance_id'] != old_instance, 'Restart retained daemon identity')
        require(session.rpc('workspace') == ws, 'Workspace did not restore exactly')
        for run, original in zip(runs, summaries):
            restored = session.rpc('asic', f'(Load_summary {sexp(run)})', wait=True)
            summary = next(s for s in field(restored, 'summaries') if field(s, 'run') == run)
            require(field(summary, 'freshness') == 'Cached_unverified', 'L2 falsely claims validation')
            require({k: v for k, v in summary if k != 'freshness'} == {k: v for k, v in original if k != 'freshness'}, 'L2 summary identity changed')
        require(report_count() == before, 'Restart L2 requested extra reports')
        stale = session.raw('/api/v1/workspace', [['instance_id', old_instance], ['project', 'missing'], ['operation', 'Get']])
        require(stale[0] == 'Error' and field(stale[1], 'kind') == 'Instance_changed', 'Stale instance not rejected')
        missing = session.raw('/api/v1/asic', [['instance_id', session.metadata['instance_id']], ['project', 'missing'], ['operation', 'Get']])
        require(missing[0] == 'Error' and field(missing[1], 'kind') == 'Not_found', 'Missing project not rejected')
        result = dict(status='passed', summaries=[record(s) for s in summaries],
                      report_calls_before_warm=before, report_calls_after_restart=report_count(),
                      workspace=record(ws), old_instance=old_instance, new_instance=session.metadata['instance_id'])
        (session.evidence / 'verified.json').write_text(json.dumps(result, indent=2))
        return result
    finally:
        session.stop()


def reopen_real(args):
    acceptance = args.reopen_real.resolve()
    prior = json.loads((acceptance / 'real/verified.json').read_text())
    require(prior['status'] == 'passed', 'Reopen requires successful real acceptance')
    originals = prior['summaries']
    require([s['cell_count'] for s in originals] == [['673'], ['685']], 'Unexpected real acceptance counts')
    runs = [s['run'] for s in originals]
    session = Session(args, args.evidence, args.example_root)
    session.state_dir = acceptance / 'real/state'
    require(session.state_dir.is_dir(), 'Missing accepted Workbench state')
    session.start()
    process = None
    master = None
    transcript = bytearray()
    try:
        for original, run in zip(originals, runs):
            snapshot = session.rpc('asic', f'(Load_summary {sexp(run)})', wait=True)
            summary = record(next(s for s in field(snapshot, 'summaries') if field(s, 'run') == run))
            require(summary['freshness'] == 'Cached_unverified', 'Reopen unexpectedly validated source')
            require({k: v for k, v in summary.items() if k != 'freshness'} ==
                    {k: v for k, v in original.items() if k != 'freshness'}, 'Cached identity/data changed')
        ws = session.rpc('workspace')
        main = field(ws, 'main_context')
        title = 'FS0 Real Demo ' + str(time.time_ns())
        ws = session.mutate(ws, f'(Create_workspace (window {field(field(ws, "windows")[0], "id")}) (name {sexp(title)}) (context {main}))')
        demo = field(field(ws, 'workspaces')[-1], 'id')
        ws = session.mutate(ws, f'(Create_tile (workspace {demo}) (kind synthesis) (geometry ((x 0) (y 0) (width 56) (height 14))))')
        tile = field(field(ws, 'tiles')[-1], 'id')
        ws = session.mutate(ws, f'(Set_zoom (workspace {demo}) (tile ({tile})))')

        def select_run(run):
            current = session.rpc('workspace')
            context = next(c for c in field(current, 'contexts') if field(c, 'id') == main)
            updated = session.mutate(current, f'(Select_run (workspace {demo}) (context {main}) (expected_selection_revision {field(context, "selection_revision")}) (run ({sexp(run)})))')
            require(field(next(c for c in field(updated, 'contexts') if field(c, 'id') == main), 'selected_run') == [run],
                    'Selection mutation did not persist')
            return updated

        ws = select_run(runs[0])
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 120, 0, 0))
        process = subprocess.Popen([str(args.client), '--connect', session.url, '--project-root', str(args.example_root)],
                                   stdin=slave, stdout=slave, stderr=slave,
                                   env=dict(session.env, TERM='xterm-256color'), start_new_session=True)
        os.close(slave)

        def drain(seconds):
            end = time.monotonic() + seconds
            while time.monotonic() < end:
                if select.select([master], [], [], .05)[0]:
                    try:
                        chunk = os.read(master, 65536)
                    except OSError:
                        break
                    if not chunk:
                        break
                    transcript.extend(chunk)
            require(process.poll() is None, 'Interactive client exited unexpectedly')

        def screen(label, expected, absent=()):
            deadline = time.monotonic() + 15
            while True:
                drain(.5)
                text = terminal_screen(bytes(transcript))
                if all(s in text for s in expected) and all(s not in text for s in absent):
                    break
                require(time.monotonic() < deadline, f'{label}: screen expectations failed:\n{text}')
            (args.evidence / (label + '.txt')).write_text(text)
            (args.evidence / (label + '.ansi')).write_bytes(transcript)

        drain(3)
        for key in (b' ', b'c', b'c'):
            os.write(master, key)
            drain(.2)
        os.write(master, ('Switch to ' + title).encode())
        drain(.8)
        os.write(master, b'\r')
        screen('01-balanced', ['Cell count: 673', 'Cached_unverified'], ['Cell count: 685'])
        ws = select_run(runs[1])
        screen('02-delay', ['Cell count: 685', 'Cached_unverified'], ['Cell count: 673'])
        ws = session.mutate(ws, f'(Set_tile_binding (tile {tile}) (binding (Pin_run {sexp(runs[0])})))')
        screen('03-pinned-balanced', ['Cell count: 673', 'Cached_unverified'], ['Cell count: 685'])
        ws = session.mutate(ws, f'(Create_tile (workspace {demo}) (kind synthesis) (geometry ((x 0) (y 0) (width 56) (height 14))))')
        follow = field(field(ws, 'tiles')[-1], 'id')
        ws = session.mutate(ws, f'(Set_zoom (workspace {demo}) (tile ()))')
        screen('04-pinned-and-following', ['Cell count: 673', 'Cell count: 685', 'Cached_unverified'])
        final = session.rpc('workspace')
        require(final == ws, 'Unexpected registry changes during rendering')
        pinned_tile = next(t for t in field(final, 'tiles') if field(t, 'id') == tile)
        follow_tile = next(t for t in field(final, 'tiles') if field(t, 'id') == follow)
        require(field(pinned_tile, 'binding') == ['Pin_run', runs[0]] and field(follow_tile, 'binding') == 'Follow',
                'Saved pin/follow bindings incorrect')
        os.write(master, b'q')
        process.wait(timeout=5)
        require(process.returncode == 0, 'Interactive client exit failed')
        session.stop()
        session.start()
        require(session.rpc('workspace') == final, 'Demo layout did not survive daemon restart')
        result = dict(status='passed', acceptance_root=str(acceptance), state_dir=str(session.state_dir),
                      workspace_id=demo, workspace_title=title, pinned_tile=tile, following_tile=follow,
                      cell_counts=[673, 685], summaries=originals, workspace=record(final),
                      commands='Load_summary/Get and workspace mutations only; no Observe/Refresh/Run')
        (args.evidence / 'reopen-verified.json').write_text(json.dumps(result, indent=2))
        print(f'Real cached PTY 673 -> 685; pinned 673 + following 685; layout restart: passed\nWorkspace: {title}', flush=True)
        return result
    finally:
        if process and process.poll() is None:
            process.terminate()
            process.wait(timeout=10)
        if master is not None:
            os.close(master)
        (args.evidence / 'reopen-pty.ansi').write_bytes(transcript)
        session.stop()


def main():
    repo = Path(__file__).resolve().parent.parent
    example = repo.parent / 'hardcaml_asic_example'
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--client', type=Path, default=repo / '_build/default/terminal/main.exe')
    parser.add_argument('--daemon', type=Path, default=repo / '_build/default/daemon/main.exe')
    parser.add_argument('--evidence', type=Path, help='New directory; default unique /tmp/opencode/workbench-fs0-*')
    parser.add_argument('--real', action='store_true', help='After fixtures, run both real synthesis profiles serially')
    parser.add_argument('--reopen-real', type=Path, metavar='ACCEPTANCE_ROOT',
                        help='Reopen accepted real/state and verify cached real counts in PTY; no EDA or fixture build')
    parser.add_argument('--example-root', type=Path, default=example)
    parser.add_argument('--project', type=Path, default=example / '_build_namedflow_real/default/bin/project.exe')
    parser.add_argument('--provider', type=Path, default=Path('/tmp/opencode/namedflow-real-20261015/provider/bin/hardcaml-asic-flow'))
    parser.add_argument('--tools', type=Path, default=example / '_flow_tools')
    parser.add_argument('--outer-timeout', type=int, default=1800)
    parser.add_argument('--stage-timeout-seconds', type=int,
                        help='Opt-in for NEW config only; default () preserves prebuilt provider defaults')
    args = parser.parse_args()
    require(not (args.real and args.reopen_real), '--real and --reopen-real are mutually exclusive')
    require(0 < args.outer_timeout <= 1800, 'Outer timeout must be 1..1800')
    require(args.stage_timeout_seconds is None or args.stage_timeout_seconds > 0,
            'Stage timeout must be positive')
    if args.evidence:
        args.evidence.mkdir(parents=False, exist_ok=False)
    else:
        args.evidence = Path(tempfile.mkdtemp(prefix='workbench-fs0-', dir='/tmp/opencode'))
    print('Evidence: ' + str(args.evidence), flush=True)
    outcome = {}
    try:
        if args.reopen_real:
            outcome['reopen'] = reopen_real(args)
            return
        fixture = args.evidence / 'fixture'
        fixture.mkdir()
        root = fixture / 'project'
        root.mkdir()
        (root / 'dune-project').write_text('(lang dune 3.17)\n(name fs0_acceptance)\n')
        (root / 'dune').write_text('(rule (alias runtest) (action (progn (echo "FS0 generic fixture passed") (with-stdout-to generic-passed (echo passed)))))\n')
        provider = root / 'fake-provider'
        provider.write_bytes((repo / 'backend/test/asic/fake_provider.py').read_bytes())
        provider.chmod(0o755)
        write_config(root, provider, provider, fixture / 'results')
        outcome['fixture'] = exercise(Session(args, fixture, root), True)
        print('Fixture HTTP/PTY/cache/restart: passed', flush=True)
        if args.real:
            real = args.evidence / 'real'
            real.mkdir()
            created = write_config(args.example_root, args.project, args.provider,
                                   args.evidence / 'results', args.tools, args.stage_timeout_seconds)
            outcome['real_config_created'] = created
            outcome['real'] = exercise(Session(args, real, args.example_root), False)
            print('Real synthesis balanced + synth_delay: passed', flush=True)
    except Exception:
        outcome['error'] = traceback.format_exc()
        raise
    finally:
        (args.evidence / 'outcome.json').write_text(json.dumps(outcome, indent=2))


if __name__ == '__main__':
    main()
