#!/usr/bin/env python3
"""Bounded independent combined development acceptance (prebuilt native apps).

Requires a prepared PRIVATE --store and its --root; never adopts the owner's
stable store. All mutations, attempts and receipts stay under that private store.
No builds or EDA are launched by this harness. Failures retain partial evidence.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import pty
import re
import select
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time
import traceback

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, HERE / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


native = load('development_native', 'test-fs2-native.py')
fifo = load('development_fifo', 'test-fifo-testing.py')
field, require, parse, sexp = native.field, native.require, native.parse, native.sexp


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def save(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')


def validate_capture(store, root, manifest):
    """Validate the selected ownership-layout capture before starting any pair.

    Historical stores are deliberately not migrated by acceptance consumers.
    The preparation companion is the authority for the source build target.
    """
    require(manifest.get('source_layout') == 'ownership-v1',
            'ownership-v1 requires a NEW store; retain historical stores unchanged')
    require(manifest['store'] == str(store) and manifest['project_root'] == str(root)
            and root == store / 'project', 'manifest owns exact private store/root')
    generation = Path(manifest['generation'])
    require(generation.parent == store / 'generations' and generation.resolve() == generation,
            'canonical generation belongs to private store')
    require((store / 'selected').resolve() == generation and
            (store / 'manifest.json').read_bytes() == (generation / 'manifest.json').read_bytes(),
            'same selected immutable manifest')
    for base, entries in ((root, manifest['source_files']), (root, manifest['config_files']),
                          (generation, manifest['captured_files']),
                          (Path(manifest['inputs']['asic_generation']), manifest['asic_files'])):
        require(bool(entries), 'nonempty exact capture inventory')
        for name, digest in entries.items():
            path = base / name
            require(not Path(name).is_absolute() and '..' not in Path(name).parts
                    and path.resolve().is_relative_to(base), 'bounded capture inventory path ' + name)
            require(sha(path) == digest, 'exact captured bytes ' + str(path))
    asic = Path(manifest['inputs']['asic_generation'])
    require(asic.is_absolute() and asic.resolve() == asic, 'exact immutable ASIC path')
    require(sha(asic / 'receipt.json') == manifest['asic_receipt_sha256'], 'exact ASIC receipt bytes')
    # Use the immutable capture's own layout/exclusion rules, not today's owner
    # checkout or only the previously listed paths (which misses added sources).
    helper = generation / 'source/integration/workbench/workbench_provider.py'
    require(str(helper.relative_to(generation)) in manifest['captured_files'],
            'captured layout helper is hash-bound')
    probe = subprocess.run([sys.executable, '-I', '-B', '-c',
        'import json,sys; from pathlib import Path; '
        'sys.path.insert(0, str(Path(sys.argv[1]).parent)); '
        'import workbench_provider as p; '
        'print(json.dumps(dict(layout=p.SOURCE_LAYOUT, roots=list(p.SOURCE_FILES+p.SOURCE_DIRS), '
        'files=p.inventory(sys.argv[2], p.SOURCE_FILES+p.SOURCE_DIRS), '
        'closure=p.inventory(sys.argv[2], (".",)))))',
        str(helper), str(root)], capture_output=True, text=True, timeout=30)
    require(probe.returncode == 0, 'captured source inventory available: ' + probe.stderr)
    inventory = json.loads(probe.stdout)
    require(inventory['layout'] == manifest['source_layout'] and inventory['roots'] == manifest['source_roots'],
            'exact captured source layout roots')
    require(inventory['files'] == manifest['source_files'],
            'exact authored source inventory closure; no added, removed or changed files')
    require(inventory['closure'] == dict(manifest['source_files'], **manifest['config_files']),
            'exact whole-project source/config closure under captured exclusions; no additional authored roots')
    require('git_context' in manifest and manifest['max_jobs'] <= 2, 'scoped Git and max2 capture')
    context = manifest['git_context']
    require(sha(Path(context['real_git'])) == context['real_git_sha256'], 'exact scoped real Git')
    config = dict(parse((root / 'hardcaml-workbench-preparation.sexp').read_text()))
    target = config['build_target']
    require(isinstance(target, str) and not target.startswith('-') and
            not Path(target).is_absolute() and '..' not in Path(target).parts and target.endswith('.exe'),
            'explicit project-relative executable build target')
    require(str(Path(target).with_suffix('.ml')) in manifest['source_files'] and
            str(Path(target).parent / 'dune') in manifest['source_files'],
            'build target belongs to captured source inventory')
    return dict(source_layout=manifest['source_layout'], build_target=target,
                preparation_config_sha256=sha(root / 'hardcaml-workbench-preparation.sexp'),
                asic_generation=str(asic), asic_receipt_sha256=manifest['asic_receipt_sha256'])


class Session(native.Session):
    def start(self):
        self.log = (self.evidence / ('daemon-' + str(time.time_ns()) + '.log')).open('wb')
        self.process = subprocess.Popen([sys.executable, '-B', str(self.args.launcher),
            '--store', str(self.args.store), 'daemon'], env=self.env,
            stdout=self.log, stderr=subprocess.STDOUT)
        metadata = self.args.store / 'discovery/daemon.sexp'
        deadline = time.monotonic() + 20
        while True:
            require(self.process.poll() is None, 'owned launcher daemon exited; see log')
            if metadata.exists():
                current = dict(parse(metadata.read_text()))
                if int(current['pid']) == self.process.pid:
                    self.metadata, self.url = current, current['endpoint']
                    break
            require(time.monotonic() < deadline, 'owned daemon startup deadline')
            time.sleep(.05)
        opened = self.raw('/api/v1/open-project', [('instance_id', self.metadata['instance_id']),
            ('root', str(self.root)), ('environment', 'Inherit_daemon')])
        require(opened[0] == 'Ok', str(opened))
        self.project = field(field(opened[1], 'project'), 'id')


class Terminal(fifo.TestingTerminal):
    """Actual production client; force exact first palette match explicitly."""
    def __init__(self, session):
        self.session, self.data = session, bytearray()
        self.archive = bytearray()
        self.master, slave = pty.openpty()
        fcntl = fifo.fcntl
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', self.height, self.width, 0, 0))
        self.process = subprocess.Popen([sys.executable, '-B', str(session.args.launcher),
            '--store', str(session.args.store), 'client'], stdin=slave, stdout=slave, stderr=slave,
            start_new_session=True, env=dict(session.env, TERM='xterm-256color'))
        os.close(slave)

    def drain(self, seconds=.3):
        def poll(duration):
            deadline = time.monotonic() + duration
            while time.monotonic() < deadline:
                if select.select([self.master], [], [], .02)[0]:
                    try:
                        data = os.read(self.master, 65536)
                    except OSError:
                        break
                    if not data:
                        break
                    self.data.extend(data)
            require(self.process.poll() is None, 'production launcher/client exited')
        poll(seconds)
        if len(self.data) > 200000:
            self.archive.extend(self.data)
            self.data.clear()
            for width in (self.width + 1, self.width):
                fifo.fcntl.ioctl(self.master, termios.TIOCSWINSZ,
                                struct.pack('HHHH', self.height, width, 0, 0))
                os.kill(self.process.pid, signal.SIGWINCH)
                poll(.15)
                if width != self.width:
                    self.archive.extend(self.data)
                    self.data.clear()
        return native.fs0.terminal_screen(bytes(self.data), self.width, self.height)

    def close(self):
        (self.session.evidence / ('client-all-' + str(time.time_ns()) + '.ansi')).write_bytes(self.archive + self.data)
        super().close()

    def resize_wave(self, width, height):
        self.width, self.height = width, height
        fifo.fcntl.ioctl(self.master, termios.TIOCSWINSZ, struct.pack('HHHH', height, width, 0, 0))
        os.kill(self.process.pid, signal.SIGWINCH)
        self.drain(.4)

    def palette(self, title):
        for key in (b' ', b'c', b'c'):
            self.key(key)
        self.capture('palette-open-' + str(time.time_ns()), ['COMMAND PALETTE'])
        self.key(title.encode())
        self.capture('palette-query-' + str(time.time_ns()), [title[-60:]],
                     absent=['No matching commands'])
        self.key(b'\x1b[A' * 16)
        self.capture('palette-selected-' + str(time.time_ns()), ['> ' + title[:36]])
        self.key(b'\r')


def run(args):
    evidence = args.evidence
    report = dict(status='failed', eda_jobs=0, checks=[], untested=[
        'composite adversarial child discovery/delegation controls',
        'per-suite cancellation and descendant reaping',
        'prepare/repeat/refresh/rollback/active-lock controls (separate setup receipt)',
        'source build and elaboration-only emission (optional separate check)'])
    def check(ok, label):
        report['checks'].append(dict(passed=bool(ok), expectation=label))
        require(ok, label)

    for name in ('state', 'home', 'config', 'tmp'):
        (evidence / name).mkdir()
    binaries = {str(p): sha(p) for p in (args.daemon, args.client)}
    manifest = json.loads((args.store / 'manifest.json').read_bytes())
    identities = validate_capture(args.store, args.root, manifest)
    for kind in ('daemon', 'client'):
        app = manifest['apps'][kind]
        check(getattr(args, kind) == Path(app['path']) and sha(getattr(args, kind)) == app['sha256'],
              'actual launcher captured app path/hash ' + kind)
    generation = Path(manifest['generation'])
    captured = {name: sha(generation / name) for name in manifest['captured_files']}
    check(captured == manifest['captured_files'], 'complete prepared generation hash capture')
    configs = {str(p): sha(p) for p in args.root.glob('hardcaml-workbench*.sexp')}
    save(evidence / 'invocation.json', dict(argv=sys.argv, binaries=binaries,
         configs=configs, root=str(args.root), store=str(args.store), eda_jobs=0,
         identities=identities,
         manifest=str(generation / 'manifest.json'), manifest_sha256=sha(generation / 'manifest.json')))
    report.update(store=str(args.store), root=str(args.root), identities=identities,
                  manifest_sha256=sha(args.store / 'manifest.json'))
    session = Session(args, evidence, args.root)
    session.state_dir = args.store / 'state'
    session.env.update(HOME=str(evidence / 'home'), XDG_CONFIG_HOME=str(evidence / 'config'),
        TMPDIR=str(evidence / 'tmp'), OMP_NUM_THREADS='2', OPENROAD_THREADS='2',
        _OPENLANE_MAX_CORES='2', DUNEJOBS='2', PYTHONDONTWRITEBYTECODE='1')
    terminal = None
    details = []

    def artifact_bytes(detail, artifact):
        data = bytearray()
        aid, identity = field(detail, 'id'), field(artifact, 'id')
        digest = field(artifact, 'sha256')[0]
        while True:
            result = session.api(operation=['Read_artifact_bytes', ['attempt_id', aid],
                ['artifact_id', identity], ['sha256', digest], ['offset', len(data)], ['limit', 65536]])
            page = field(result, 'byte_page')[0]
            block = bytes.fromhex(field(page, 'bytes_hex'))
            check(int(field(page, 'offset')) == len(data), 'artifact page offset ' + identity)
            data.extend(block)
            require(len(data) <= 8 * 1024 * 1024, 'bounded artifact transport')
            if field(page, 'eof') == 'true':
                break
            require(block, 'artifact page advances')
        check(hashlib.sha256(data).hexdigest() == digest, 'artifact exact digest ' + identity)
        target = evidence / 'artifacts' / aid
        target.mkdir(parents=True, exist_ok=True)
        (target / re.sub(r'[^A-Za-z0-9_.-]', '_', identity)).write_bytes(data)
        return bytes(data)

    def launch_form(suite, cases, seed, parameters=(), expected='Passed'):
        before = {field(a, 'id') for a in field(session.api(), 'attempts')}
        terminal.key(b'pp' + (b'n' if suite == 'pt8-memory-workloads' else b''))
        terminal.capture('selected-catalog-' + suite, ['> ' + suite])
        terminal.palette('Simulation: Launch selected catalog subset')
        for label, value in [('CASES', ' '.join(cases)), ('SEED', seed), *[
                ('PARAMETER ' + name, value) for name, value in parameters]]:
            terminal.capture('form-' + suite + '-' + label.replace(' ', '-'), [label])
            terminal.key(b'\x15' + value.encode() + b'\r')
        terminal.capture('confirm-' + suite, ['CONFIRM', seed, *cases])
        check({field(a, 'id') for a in field(session.api(), 'attempts')} == before,
              suite + ': form does not launch before confirmation')
        terminal.key(b'\x15launch\r')
        deadline = time.monotonic() + 180
        while True:
            terminal.drain(.1)
            fresh = [a for a in field(session.api(), 'attempts') if field(a, 'id') not in before]
            if fresh:
                require(len(fresh) == 1, 'one new explicit form attempt')
                aid = field(fresh[0], 'id')
                detail = field(session.api(operation=['Observe', aid]), 'detail')[0]
                if field(detail, 'lifecycle') not in ('Queued', 'Running'):
                    break
            require(time.monotonic() < deadline, 'bounded actual simulation ' + suite)
        details.append(detail)
        save(evidence / ('attempt-' + aid + '.json'), detail)
        selected = field(field(detail, 'captured'), 'selection')
        check(field(detail, 'outcome') == expected and field(detail, 'exit_code') == ['0'],
              suite + ': semantic ' + expected + ' with successful native exit')
        check(field(selected, 'suite') == suite and set(field(selected, 'cases')) == set(cases)
              and field(selected, 'seed') == seed and dict(field(selected, 'parameters')) == dict(parameters)
              and field(selected, 'asic_inputs') == [], suite + ': exact actual UI selection')
        check(field(detail, 'project_root') == str(args.root), 'same project/root for ' + suite)
        return detail

    def open_wave(detail, case):
        suite = field(field(field(detail, 'captured'), 'selection'), 'suite')
        terminal.palette('Simulation: Reopen ' + field(detail, 'id') + ' ' + suite)
        terminal.palette('Simulation: Select case ' + case)
        wave = next(a for a in field(detail, 'artifacts')
                    if field(a, 'media_type') in ('text/vcd', 'text/x-vcd') and field(a, 'case_id') == [case])
        terminal.palette('Simulation: Open embedded waveform ' + field(wave, 'label'))
        text = terminal.capture('wave-' + suite + '-' + case, ['Waveform', 'Cursor 0 ticks'])
        check('Graph unavailable' not in text, suite + ': real VCD graph available')
        return wave, text

    def source_only_plan():
        before = session.raw('/api/v1/snapshot', [('instance_id', session.metadata['instance_id'])])
        old_jobs = {field(j, 'id') for j in field(before[1], 'jobs')}
        session.api(domain='asic', operation='Discover')
        deadline = time.monotonic() + 30
        while True:
            discovered = session.api(domain='asic')
            if field(discovered, 'flows'):
                break
            require(time.monotonic() < deadline, 'standard flow discovery deadline')
            time.sleep(.1)
        standard = next(f for f in field(discovered, 'flows') if field(f, 'id') == 'standard')
        check('balanced' in field(standard, 'profiles'), 'normal standard/balanced flow discovered')
        selected = [('flow', 'standard'), ('profile', 'balanced'), ('endpoint', 'synthesis'), ('assignments', [])]
        plan = session.api(domain='asic', operation=['Plan', selected])
        # Provider invocations are asynchronous; fence the exact selected preview.
        deadline = time.monotonic() + 30
        while not field(plan, 'preview'):
            failed = [op for op in field(plan, 'operations') if field(op, 'kind') == 'plan' and field(op, 'state') == 'failed']
            if failed:
                save(evidence / 'source-only-plan-failed.json', plan)
                raise AssertionError('source-only Plan failed: ' + sexp(failed))
            require(time.monotonic() < deadline, 'source-only Plan deadline')
            time.sleep(.1)
            plan = session.api(domain='asic')
        preview = field(plan, 'preview')[0]
        document = json.loads(field(preview, 'plan_json'))
        check(document['plan_identity'] == field(preview, 'plan_identity'), 'source-only Plan exact identity')
        staged = session.api(domain='asic', operation=['Stage_fresh', ['selection', selected],
            ['elaboration_only', 'false'], ['expected_plan_identity', []]])
        intent = field(staged, 'fresh_intent')[0]
        check(field(intent, 'elaboration_only') == 'false' and str(args.root) in field(intent, 'scope'),
              'StageFreshAvailable captures fixed editable source root')
        check(field(staged, 'workflows') == field(discovered, 'workflows') and field(staged, 'runs') == field(discovered, 'runs'),
              'normal source-only Plan/staging creates no producer workflow/run')
        preparation = session.api(domain='preparation')
        check(field(preparation, 'availability') == 'Available', 'normal source build/emission preparation is Available')
        after = session.raw('/api/v1/snapshot', [('instance_id', session.metadata['instance_id'])])
        new_jobs = [j for j in field(after[1], 'jobs') if field(j, 'id') not in old_jobs]
        check(not any('run-stage' in sexp(field(j, 'kind')) for j in new_jobs), 'source-only planning has no EDA stage job')
        save(evidence / 'source-only-plan.json', dict(preview=preview, intent=intent, preparation=preparation, jobs=new_jobs))
        if args.elaboration_only:
            staged = session.api(domain='asic', operation=['Stage_fresh', ['selection', selected],
                ['elaboration_only', 'true'], ['expected_plan_identity', []]])
            key = 'c-elaboration-' + str(time.time_ns())
            session.api(domain='asic', operation=['Launch_fresh', ['key', key],
                ['intent_id', field(field(staged, 'fresh_intent')[0], 'id')]])
            deadline = time.monotonic() + 600
            while True:
                snapshot = session.api(domain='asic')
                workflow = next((w for w in field(snapshot, 'workflows') if field(w, 'key') == key), None)
                if workflow and field(workflow, 'phase') in ('Completed', 'Failed', 'Cancelled', 'Interrupted'):
                    break
                require(time.monotonic() < deadline, 'bounded private source build/emission')
                terminal.drain(.1)
            save(evidence / 'elaboration-only-workflow.json', workflow)
            check(field(workflow, 'phase') == 'Completed' and not field(workflow, 'run')
                  and not field(workflow, 'reference'), 'actual editable source build/emission completes with no physical run')
            prepared = field(workflow, 'prepared')[0]
            check(Path(field(prepared, 'bundle_directory')).resolve().is_relative_to(args.store),
                  'actual source-emitted bundle belongs to private store')
            for name in ('build_job', 'emission_job'):
                job = field(workflow, name)[0]
                check(field(job, 'state') == 'Complete', 'actual ' + name + ' completed')
                logs = session.raw('/api/v1/read-log', [('instance_id', session.metadata['instance_id']),
                    ('job', field(job, 'id')), ('offset', 0), ('max_records', 100), ('max_bytes', 65536)])
                save(evidence / (name + '-logs.json'), dict(job=job, logs=logs))
            session.api(domain='asic', operation=['Stage_fresh', ['selection', selected],
                ['elaboration_only', 'false'], ['expected_plan_identity', []]])
            report['untested'].remove('source build and elaboration-only emission (optional separate check)')

    def workloads_handoff(pt8, references):
        for case, side in [('flops256', 'A left'), ('exact256', 'B right')]:
            terminal.palette('Simulation: Select case ' + case)
            terminal.palette('Inspect workload result (selected Testing case)')
            terminal.capture('result-handoff-' + case, ['Workloads', 'functional: pass'])
            state = field(session.api(domain='asic'), 'workloads')[0]
            selected = json.loads(field(field(state, 'selected')[0], 'json'))
            reference = references[case]
            check(selected['source_digest'] == reference['source_digest'], case + ': actual case result handoff exact source digest')
            check(any(field(entry, 'freshness') == 'Validated' and
                      field(entry, 'query') == ['Inspect', ['result', reference['result']],
                                               ['expected_digest', [reference['source_digest']]]]
                      for entry in field(state, 'entries')), case + ': native digest-pinned workload inspection')
            save(evidence / ('workload-inspect-' + case + '.json'), selected)
            terminal.palette('Workloads: Capture ' + side + ' result')
            if case == 'flops256':
                terminal.palette('Switch to Testing')
        terminal.palette('Workloads: Axis resource_policy')
        terminal.capture('workloads-comparison', ['delta(B-A)=0', 'Validated'])
        state = field(session.api(domain='asic'), 'workloads')[0]
        comparison = json.loads(field(field(state, 'selected')[0], 'json'))
        metrics = [m for m in comparison['metrics'] if m['metric_id'].startswith('workload/')]
        check(len(metrics) == 7 and all(m['comparison'] == 'comparable' and m['right_minus_left'] == 0
                                       for m in metrics), 'actual matching Flops/Exact controls: seven comparable zero deltas')
        check(comparison['left']['workload']['source_digest'] == references['flops256']['source_digest'] and
              comparison['right']['workload']['source_digest'] == references['exact256']['source_digest'],
              'comparison bound to this same actual two-case execution')
        save(evidence / 'workloads-seven-zero-deltas.json', comparison)
        terminal.palette('Switch to Testing')

    try:
        session.start()
        report['initial_attempts'] = [field(a, 'id') for a in field(session.api(), 'attempts')]
        check(Path(manifest['project_root']) == args.root, 'private prepared root owns all retained/new history')
        terminal = Terminal(session)
        terminal.capture('startup', ['connected'])
        terminal.palette('Switch to Testing')
        terminal.palette('Unzoom workspace')
        for index in range(10):
            terminal.palette('Zoom focused tile')
            text = terminal.capture('find-catalog-' + str(index), ['Space c c commands'])
            if len(text.splitlines()) > 1 and 'simulation-catalog' in text.splitlines()[1]:
                break
            terminal.palette('Unzoom workspace')
            terminal.key(b'\t')
        else:
            raise AssertionError('cannot focus actual Testing catalog')
        source_only_plan()
        discovered = session.discover()
        save(evidence / 'discovery.json', discovered)
        suites = field(field(discovered, 'discovery')[0], 'suites')
        check([field(s, 'id') for s in suites] == ['controlled-fifo', 'pt8-memory-workloads'],
              'same session discovers exact FIFO then PT8 catalog')
        terminal.capture('combined-catalog', ['controlled-fifo', 'pt8-memory-workloads'])
        passed = launch_form('controlled-fifo', ['directed', 'seeded'], '18446744073709551615',
                             [('checker', 'normal'), ('cycles', '64')])
        failed = launch_form('controlled-fifo', ['directed', 'seeded'], '18446744073709551615',
                             [('checker', 'mismatch'), ('cycles', '64')], expected='Failed')
        by_run = {}
        for label, detail in [('normal', passed), ('mismatch', failed)]:
            by_run[label] = {field(a, 'label'): artifact_bytes(detail, a) for a in field(detail, 'artifacts')}
        for case in ('directed', 'seeded'):
            check(by_run['normal'][case + '.vcd'] == by_run['mismatch'][case + '.vcd'],
                  case + ': checker mismatch preserves actual DUT waveform')
            check(b'injected true' in by_run['mismatch'][case + '.sexp'], case + ': real injected assertion report')
        fifo_wave_ready = False
        try:
            wave, text = open_wave(passed, 'seeded')
            check('clock' in text.lower() and '8 cycles' in text.lower(), 'FIFO default shows inferred multiple periods')
            terminal.key(b':40\r/outputs.occupancy\r')
            terminal.capture('fifo-pinned', ['Cursor 40 ticks', 'outputs.occupancy'])
            terminal.key(b'q')
            fifo_wave_ready = True
        except AssertionError:
            if not args.continue_after_fifo_waveform_blocker:
                raise
            terminal.save('fifo-waveform-blocker', terminal.drain(.1))
            report['blockers'] = ['FIFO embedded waveform admission/action unavailable; see fifo-waveform-blocker.txt']
            terminal.key(b'\x1b')
        pt8 = launch_form('pt8-memory-workloads', ['flops256', 'exact256'], '34097')
        references = {}
        for artifact in field(pt8, 'artifacts'):
            raw = artifact_bytes(pt8, artifact)
            if field(artifact, 'media_type') == 'application/json':
                reference = json.loads(raw)
                check(isinstance(reference, dict) and 'result' in reference,
                      'PT8 actual retained JSON result reference ' + field(artifact, 'id'))
                references[field(artifact, 'case_id')[0]] = reference
            else:
                check(b'$enddefinitions' in raw and b'#13070000' in raw,
                      'PT8 same-execution VCD retained full 13.07us')
        workloads_handoff(pt8, references)
        wave, text = open_wave(pt8, 'exact256')
        check('tb.clk' in text and ('80 ns' in text or '80000' in text), 'PT8 useful ~eight-period default')
        terminal.key(b'f')
        terminal.capture('pt8-fit-full-trace', ['13070000', 'window 0..'])
        for width, height in [(180, 55), (80, 24), (120, 40)]:
            terminal.resize_wave(width, height)
            text = terminal.capture('pt8-fit-resize-%dx%d' % (width, height), ['window 0..13070000', 'Fit full trace'])
            bounds = re.findall(r'window (\d+)\.\.(\d+)', text)
            check(bool(bounds) and all(bound == ('0', '13070000') for bound in bounds),
                  'actual PT8 Fit resize %dx%d preserves exact inclusive requested range' % (width, height))
        terminal.key(b':2595000\r/tb.q\r')
        text = terminal.capture('pt8-exact-cursor', ['Cursor 2595000 ticks', '0001001111000110'])
        check('Graph unavailable' not in text, 'PT8 exact 13C6 response at original tick 2595000')
        terminal.key(b'l')
        terminal.capture('pt8-one-tick', ['Cursor 2595001 ticks'])
        terminal.palette('Waveform: Signal values: Stacked')
        terminal.capture('pt8-stacked-preference', ['Cursor 2595001 ticks', '0001001111000110'])
        terminal.key(b'q')
        if fifo_wave_ready:
            terminal.palette('Simulation: Reopen ' + field(passed, 'id') + ' controlled-fifo')
            terminal.palette('Simulation: Select case seeded')
            terminal.palette('Simulation: Open embedded waveform ' + field(next(a for a in field(passed, 'artifacts')
                if field(a, 'media_type') in ('text/vcd', 'text/x-vcd') and field(a, 'case_id') == ['seeded']), 'label'))
            terminal.capture('fifo-pin-preserved-after-pt8', ['Cursor 40 ticks', 'outputs.occupancy'], absent=['tb.q'])
            check(True, 'FIFO investigation pins preserved without PT8 cross-case contamination')
            terminal.key(b'q')
        terminal.close(); terminal = None
        before_ids = {field(a, 'id') for a in field(session.api(), 'attempts')}
        workspace = session.api(domain='workspace')
        prefs = {str(p.relative_to(args.store)): sha(p) for p in (args.store / 'client-state').rglob('*') if p.is_file()}
        for relative in prefs:
            target = evidence / 'prefs-before' / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes((args.store / relative).read_bytes())
        old_instance = session.metadata['instance_id']
        session.stop(); session.start()
        check(session.metadata['instance_id'] != old_instance and
              {field(a, 'id') for a in field(session.api(), 'attempts')} == before_ids,
              'restart same project restores exact attempt history')
        check(session.api(domain='workspace') == workspace, 'restart durable shared workspace state')
        for detail in details:
            restored = field(session.api(operation=['Observe', field(detail, 'id')]), 'detail')[0]
            check(restored == detail, 'restart exact captured attempt/artifact metadata ' + field(detail, 'id'))
            for artifact in field(restored, 'artifacts'):
                artifact_bytes(restored, artifact)
        terminal = Terminal(session)
        terminal.capture('restarted-client', ['connected'])
        terminal.drain(1)
        for path in (args.store / 'client-state').rglob('*'):
            if path.is_file():
                target = evidence / 'prefs-after' / path.relative_to(args.store)
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(path.read_bytes())
        enrichments = []
        preferences_preserved = bool(prefs)
        for relative, digest in prefs.items():
            after_path = args.store / relative
            if sha(after_path) == digest:
                continue
            # Restore may hydrate an originally unset selected artifact. Admit only
            # an exact same-attempt/same-case retained artifact; preserve every other
            # saved navigation, Workloads pair, display and identity field verbatim.
            if not after_path.name.startswith('navigation-'):
                preferences_preserved = False
                continue
            before = dict(parse((evidence / 'prefs-before' / relative).read_text()))
            after = dict(parse(after_path.read_text()))
            enriched_workspaces = set()
            for previous in before['workspaces']:
                current = next(w for w in after['workspaces'] if field(w, 'id') == field(previous, 'id'))
                old_testing, new_testing = field(previous, 'testing'), field(current, 'testing')
                if old_testing and new_testing and not field(old_testing[0], 'artifact') and field(new_testing[0], 'artifact'):
                    selected = field(new_testing[0], 'artifact')[0]
                    expected = next((a for d in details for a in field(d, 'artifacts')
                        if field(d, 'id') == field(old_testing[0], 'attempt')[0]
                        and field(a, 'case_id') == field(old_testing[0], 'case_id')
                        and field(a, 'id') == field(selected, 'id')), None)
                    check(expected is not None and field(expected, 'sha256') == field(selected, 'sha256')
                          and field(expected, 'size') == field(selected, 'size'), 'restored navigation enrichment has exact retained same-case identity')
                    for item in old_testing[0]:
                        if item[0] == 'artifact':
                            item[1] = field(new_testing[0], 'artifact')
                    wid = field(previous, 'id')
                    enriched_workspaces.add(wid)
                    enrichments.append(dict(workspace=wid, artifact=expected))
            added = []
            for wid, artifact in after.get('testing_artifacts', []):
                if wid in enriched_workspaces:
                    expected = next(e['artifact'] for e in enrichments if e['workspace'] == wid)
                    check(artifact == expected, 'hydrated saved artifact metadata equals original native record')
                else:
                    added.append([wid, artifact])
            after['testing_artifacts'] = added
            before.setdefault('testing_artifacts', [])
            preferences_preserved &= before == after
        save(evidence / 'client-preference-restoration.json', dict(preserved=preferences_preserved,
             exact_same_case_enrichments=enrichments))
        check(preferences_preserved, 'restart retained client navigation/pair/display preferences with verified same-case hydration')
        terminal.palette('Simulation: Reopen ' + field(pt8, 'id') + ' pt8-memory-workloads')
        terminal.palette('Simulation: Select case exact256')
        terminal.palette('Simulation: Open embedded waveform ' + field(wave, 'label'))
        terminal.capture('restarted-wave-default', ['Cursor 0 ticks', '80000'])
        terminal.key(b':2595000\r/tb.q\r')
        text = terminal.capture('restarted-stacked-display', ['Cursor 2595000 ticks', '0001001111000110'])
        rows = text.splitlines()
        check(any('tb.q[15:0]' in row and '[16]' in row and index + 1 < len(rows)
                  and '= 00010011110001' in rows[index + 1] for index, row in enumerate(rows)),
              'actual restarted client restores Stacked display preference for exact retained waveform')
        check({field(a, 'id') for a in field(session.api(), 'attempts')} == before_ids,
              'restarted retained waveform/display investigation creates no simulation attempt')
        terminal.key(b'q')
        session.discover()
        terminal.palette('Simulation: Reopen ' + field(failed, 'id') + ' controlled-fifo')
        terminal.palette('Simulation: Select case seeded')
        rerun_before = {field(a, 'id') for a in field(session.api(), 'attempts')}
        terminal.palette('Simulation: Rerun case seeded (original inputs; current project)')
        deadline = time.monotonic() + 30
        while True:
            fresh = [a for a in field(session.api(), 'attempts') if field(a, 'id') not in rerun_before]
            if fresh:
                require(len(fresh) == 1, 'one actual post-restart targeted rerun')
                rerun = session.done(field(fresh[0], 'id'))
                break
            require(time.monotonic() < deadline, 'post-restart rerun launch deadline')
            terminal.drain(.1)
        selected = field(field(rerun, 'captured'), 'selection')
        parent = field(rerun, 'parent')[0]
        check(field(parent, 'attempt_id') == field(failed, 'id') and field(parent, 'job') == field(failed, 'job')
              and field(rerun, 'job') != field(failed, 'job') and field(rerun, 'outcome') == 'Failed'
              and field(rerun, 'exit_code') == ['0'] and field(selected, 'cases') == ['seeded']
              and field(selected, 'seed') == '18446744073709551615'
              and dict(field(selected, 'parameters')) == {'checker': 'mismatch', 'cycles': '64'},
              'actual post-restart targeted rerun has fresh job, exact parent/inputs and semantic checker failure')
        save(evidence / ('rerun-' + field(rerun, 'id') + '.json'), rerun)
        for artifact in field(rerun, 'artifacts'):
            artifact_bytes(rerun, artifact)
        report['post_restart_rerun'] = field(rerun, 'id')
        report.update(status='blocked' if report.get('blockers') else 'passed', attempts=[field(d, 'id') for d in details], binaries=binaries)
    except BaseException:
        report['error'] = traceback.format_exc()
        raise
    finally:
        try:
            if terminal:
                try:
                    terminal.save('last-screen', terminal.drain(.1))
                finally:
                    terminal.close()
        finally:
            if session.process:
                session.stop()
        report['configs_unchanged'] = all(sha(Path(p)) == h for p, h in configs.items())
        report['apps_unchanged'] = all(sha(Path(p)) == h for p, h in binaries.items())
        report['prepared_capture_unchanged'] = all(sha(generation / name) == digest for name, digest in captured.items())
        if not all(report[k] for k in ('configs_unchanged', 'apps_unchanged', 'prepared_capture_unchanged')):
            report['status'] = 'failed'
        try:
            report['source_and_dependency_capture_unchanged'] = (
                validate_capture(args.store, args.root, manifest) == identities)
            if not report['source_and_dependency_capture_unchanged']:
                report['status'] = 'failed'
        except BaseException:
            report['status'] = 'failed'
            report['preservation_error'] = traceback.format_exc()
        save(evidence / 'receipt.json', report)
    require(report['status'] == 'passed', 'native acceptance/preservation gates')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True, help='prepared private editable project')
    parser.add_argument('--store', type=Path, required=True, help='private store under /tmp/opencode')
    parser.add_argument('--daemon', type=Path, help='defaults to manifest captured app; explicit path must match it')
    parser.add_argument('--client', type=Path, help='defaults to manifest captured app; explicit path must match it')
    parser.add_argument('--launcher', type=Path, default=HERE.parent.parent / 'hardcaml_asic_example/scripts/workbench_dev.py')
    parser.add_argument('--evidence', type=Path)
    parser.add_argument('--elaboration-only', action='store_true', help='also run supported private source build+bundle emission; no EDA')
    parser.add_argument('--continue-after-fifo-waveform-blocker', action='store_true',
                        help='diagnostic: retain failed FIFO waveform action and continue other gates; never reports full pass')
    args = parser.parse_args()
    for name in ('root', 'store', 'launcher'):
        setattr(args, name, getattr(args, name).resolve(strict=True))
    private = Path('/tmp/opencode').resolve()
    require(args.store.is_relative_to(private) and args.store != private, 'private store must be beneath /tmp/opencode')
    require(args.root.is_relative_to(args.store), 'project must belong to private store')
    manifest = json.loads((args.store / 'manifest.json').read_bytes())
    for kind in ('daemon', 'client'):
        setattr(args, kind, (getattr(args, kind) or Path(manifest['apps'][kind]['path'])).resolve(strict=True))
    if args.evidence:
        args.evidence = args.evidence.resolve()
        require(args.evidence.is_relative_to(private), 'private evidence required')
        args.evidence.mkdir()
    else:
        args.evidence = Path(tempfile.mkdtemp(prefix='development-native-c-', dir=private))
    print('Evidence: ' + str(args.evidence), flush=True)
    os.umask(0o077)
    signal.signal(signal.SIGALRM, lambda *_: (_ for _ in ()).throw(TimeoutError('900s integration budget exhausted')))
    signal.alarm(900)
    try:
        run(args)
    finally:
        signal.alarm(0)
    print('PASS combined native development session: ' + str(args.evidence), flush=True)


if __name__ == '__main__':
    main()
