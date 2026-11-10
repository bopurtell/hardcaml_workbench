#!/usr/bin/env python3
"""Production developer acceptance, with a durable, explicit EDA activation boundary.

Run in opam switch 5.2.0+ox. Each invocation gets a NEW evidence directory.
simulations prepares/tests/readies only; synthesis requires an external allocation;
restart reopens the exact synthesis receipt on the same store, without a launch.
recapture uses an explicit reviewed app pair and the stopped-daemon launcher;
recover-collection requires that recorded transition plus collection-only admission,
and submits no implementation. Original failed evidence is never rewritten.
The native session harness is reused, including its real
FIFO/PT.8 LaunchForms, waveform, A/B comparison and simulation restart checks.
"""
import argparse
import contextlib
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import traceback

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
PRIVATE = Path('/tmp/opencode')
EXAMPLE = HERE.parent.parent / 'hardcaml_asic_example'
spec = importlib.util.spec_from_file_location('workflow_native', HERE / 'test-development-session.py')
legacy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(legacy)
resource_spec = importlib.util.spec_from_file_location('workflow_resources', HERE / 'developer-workflow-resources.py')
resources = importlib.util.module_from_spec(resource_spec)
resource_spec.loader.exec_module(resources)
recovery = legacy.load('workflow_collection_recovery', 'developer_workflow_recovery.py')
field, require, sha, sexp = legacy.field, legacy.require, legacy.sha, legacy.sexp
CHECKS = None


def require(ok, label):
    if CHECKS is not None:
        CHECKS.append(dict(passed=bool(ok), expectation=label))
    legacy.require(ok, label)


def save(path, value):
    # Every attempt is append-only; even failed receipts must never be overwritten.
    with path.open('x') as out:
        json.dump(value, out, indent=2)
        out.write('\n')


def command(evidence, name, argv, **kwargs):
    save(evidence / (name + '-command.json'), dict(argv=argv, cwd=str(kwargs.get('cwd', Path.cwd()))))
    with (evidence / (name + '.stdout')).open('xb') as out, (evidence / (name + '.stderr')).open('xb') as err:
        result = subprocess.run(argv, stdout=out, stderr=err, **kwargs)
    save(evidence / (name + '-exit.json'), dict(exit_code=result.returncode))
    require(result.returncode == 0, name + ' failed; see retained command/stdout/stderr')


def owner_snapshot(owner):
    manifest = json.loads((owner / 'manifest.json').read_text())
    paths = [owner / 'manifest.json', *list((owner / 'project').glob('hardcaml-workbench*.sexp'))]
    return dict(generation=manifest['generation'], hashes={str(p): sha(p) for p in paths},
                discovery=(owner / 'discovery/daemon.sexp').read_text()
                if (owner / 'discovery/daemon.sexp').exists() else None)


def prepare(args, evidence):
    require(not args.store.exists() and not args.store.is_symlink(), '--prepare requires a NEW private store')
    require(args.asic_generation is not None and args.sdk_prefix is not None,
            '--prepare requires explicit --asic-generation and --sdk-prefix')
    asic = args.asic_generation.absolute()
    require(asic.resolve(strict=True) == asic, 'exact immutable ASIC generation, not a selector')
    sdk = args.sdk_prefix.resolve(strict=True)
    save(evidence / 'prepare-inputs.json', dict(source_root=str(args.source_root),
        launcher=dict(path=str(args.launcher), sha256=sha(args.launcher)),
        asic_generation=str(asic), asic_receipt_sha256=sha(asic / 'receipt.json'),
        sdk_prefix=str(sdk), sdk_files={str(p.relative_to(sdk)): sha(p)
            for p in (sdk / 'lib').rglob('*') if p.is_file()}))
    build = HERE.parent / '_build_pt8_workbench'
    command(evidence, 'build-app-pair', ['flock', '/tmp/opencode/workbench-pt8-build.lock',
        'opam', 'exec', '--switch=5.2.0+ox', '--', 'dune', 'build', '--root', str(HERE.parent),
        '--build-dir', str(build), '-j2', 'daemon/main.exe', 'terminal/main.exe'], timeout=1800)
    extra = ['--synthesis-task-limit', str(args.synthesis_task_limit)] if args.synthesis_task_limit else []
    command(evidence, 'prepare', [sys.executable, '-B', str(args.launcher), '--root', str(args.source_root),
        '--store', str(args.store), 'prepare', '--asic-generation', str(asic), '--sdk-prefix', str(sdk),
        '--wb-build-root', str(build), '--git', '/usr/bin/git',
        '--expected-daemon-sha256', sha(build / 'default/daemon/main.exe'),
        '--expected-client-sha256', sha(build / 'default/terminal/main.exe'), *extra], timeout=1800)


class Terminal(legacy.Terminal):
    def palette(self, title):
        if getattr(self.session, 'inspection_only', False):
            require(not title.startswith(('Launch ', 'Plan ASIC ', 'Finalize ', 'Simulation: Launch', 'Simulation: Rerun', 'Run ')),
                    'inspection-only continuation cannot invoke a producer')
        if getattr(self.session, 'recovery_only', False):
            require(not title.startswith(('Launch ', 'Plan ASIC ', 'Finalize (accept)')),
                    'collection recovery cannot stage or submit implementation/acceptance')
            if title.startswith('Finalize '):
                require(title == self.session.collection_title, 'recovery can collect only its exact original run')
        self._launching = title == 'Launch and view planned run in captured context'
        self._collecting = title.startswith('Finalize (collect) ')
        try:
            return super().palette(title)
        finally:
            self._launching = False
            self._collecting = False

    def key(self, key):
        guard_session(self.session)
        if getattr(self, '_launching', False) and key == b'\r':
            # Check at the actual submission key, after palette navigation delays.
            self.session.launch_guard()
        with (self.session.evidence / 'pty-keys.jsonl').open('a') as out:
            out.write(json.dumps(dict(time_ns=time.time_ns(), bytes_hex=key.hex())) + '\n')
        if getattr(self, '_launching', False) and key == b'\r':
            # Mark uncertainty BEFORE the write: write/capture may fail after the
            # client consumed Enter, even if palette() never returns.
            self.session.submission_possible()
        if getattr(self, '_collecting', False) and key == b'\r' and getattr(self.session, 'recovery_only', False):
            self.session.collection_possible()
        super().key(key)

    def drain(self, seconds=.3):
        guard_session(self.session)
        result = super().drain(seconds)
        guard_session(self.session)
        return result

    def search(self, title, label):
        for key in (b' ', b'c', b'c'):
            self.key(key)
        self.key(title.encode())
        return self.capture(label, ['COMMAND PALETTE', title])


@contextlib.contextmanager
def pair(args, evidence):
    for name in ('home', 'config', 'tmp'):
        (evidence / name).mkdir()
    session = legacy.Session(args, evidence, args.root)
    session.state_dir = args.store / 'state'
    workers = '6' if args.phase in ('synthesis', 'recover-collection') else '2'
    session.env.update(HOME=str(evidence / 'home'), XDG_CONFIG_HOME=str(evidence / 'config'),
        TMPDIR=str(evidence / 'tmp'), OMP_NUM_THREADS=workers, OPENROAD_THREADS=workers,
        _OPENLANE_MAX_CORES=workers, DUNEJOBS='2', PYTHONDONTWRITEBYTECODE='1')
    terminal = None
    try:
        session.start()
        save(evidence / 'owned-daemon.json', session.metadata)
        terminal = Terminal(session)
        terminal.capture('startup', ['connected'])
        yield session, terminal
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


def guard_session(session):
    guard = getattr(session, 'resource_guard', None)
    if guard:
        guard()


def wait(session, terminal, domain, predicate, timeout=60):
    deadline = time.monotonic() + timeout
    while True:
        guard_session(session)
        snapshot = session.api(domain=domain)
        guard_session(session)
        if predicate(snapshot):
            return snapshot
        require(time.monotonic() < deadline, domain + ' deadline')
        terminal.drain(.15)


def stage(session, terminal, evidence):
    """The actual Plan palette command opens the production endpoint form."""
    before = session.api(domain='asic')
    terminal.palette('Discover ASIC flows and runs')
    wait(session, terminal, 'asic', lambda s: bool(field(s, 'flows')))
    terminal.palette('Switch to Overview')
    terminal.palette('Plan ASIC standard / balanced')
    terminal.capture('plan-synthesis-form', ['PLAN ENDPOINT', '> synthesis'])
    old = field(before, 'fresh_intent')
    terminal.key(b'\r')
    snapshot = wait(session, terminal, 'asic', lambda s: bool(field(s, 'fresh_intent')) and
        field(s, 'fresh_intent') != old)
    intent = field(snapshot, 'fresh_intent')[0]
    selected = dict(field(intent, 'selection'))
    require(selected == dict(flow='standard', profile='balanced', endpoint='synthesis', assignments=[]),
            'actual Plan form exact unmodified standard/balanced synthesis selection')
    require(field(intent, 'elaboration_only') == 'false', 'fresh synthesis, not elaboration-only')
    require(str(session.root) in field(intent, 'scope'), 'current private source scope')
    require(field(snapshot, 'workflows') == field(before, 'workflows') and
            field(snapshot, 'runs') == field(before, 'runs'), 'Plan allocates no workflow or run')
    terminal.capture('staged-synthesis', ['ready: Fresh input intent', 'endpoint: synthesis'])
    title = 'Launch and view planned run in captured context'
    text = terminal.search(title, 'launch-enabled-not-entered')
    rows = [r for r in text.splitlines() if '> ' in r and title + ' — synthesis' in r]
    require(len(rows) == 1 and '[' not in rows[0], 'production launch-and-view enabled')
    terminal.key(b'\x1b')
    save(evidence / 'staged-intent.json', intent)
    save(evidence / 'ready-asic.json', snapshot)
    return intent


def artifact_bytes(session, detail, artifact, target):
    data = bytearray()
    while True:
        response = session.api(operation=['Read_artifact_bytes', ['attempt_id', field(detail, 'id')],
            ['artifact_id', field(artifact, 'id')], ['sha256', field(artifact, 'sha256')[0]],
            ['offset', len(data)], ['limit', 65536]])
        page = field(response, 'byte_page')[0]
        require(int(field(page, 'offset')) == len(data), 'exact simulation page offset')
        block = bytes.fromhex(field(page, 'bytes_hex'))
        data.extend(block)
        require(len(data) <= 16 * 1024 * 1024, 'bounded simulation artifact')
        if field(page, 'eof') == 'true':
            break
        require(block, 'artifact transport advances')
    require(hashlib.sha256(data).hexdigest() == field(artifact, 'sha256')[0], 'simulation bytes exact digest')
    with target.open('xb') as out:
        out.write(data)


def simulations(args, evidence, report):
    native_evidence = args.simulation_evidence or evidence / 'native-simulations'
    if args.simulation_evidence:
        invocation = json.loads((native_evidence / 'invocation.json').read_text())
        require(invocation['store'] == str(args.store) and invocation['root'] == str(args.root),
                'reuse simulations only on their original store and source root')
        require(invocation['manifest_sha256'] == sha(Path(invocation['manifest'])), 'same simulation generation')
        require(invocation['manifest_sha256'] == sha(args.store / 'manifest.json'), 'same currently selected simulation capture')
    else:
        native_evidence.mkdir()
        native_args = argparse.Namespace(**vars(args))
        native_args.evidence = native_evidence
        native_args.elaboration_only = False
        native_args.continue_after_fifo_waveform_blocker = False
        # Instrument only this imported module's PTY class; original script stays intact.
        legacy.Terminal = Terminal
        legacy.run(native_args)
    receipt = json.loads((native_evidence / 'receipt.json').read_text())
    require(receipt['status'] == 'passed', 'all inherited actual simulation gates pass')
    report['simulation_receipt'] = str(native_evidence / 'receipt.json')
    report['attempts'] = receipt['attempts']
    readiness = evidence / 'readiness'
    readiness.mkdir()
    with pair(args, readiness) as (session, terminal):
        inspect_simulations(session, terminal, readiness, native_evidence, receipt['attempts'])
        stage(session, terminal, readiness)
        preparation = session.api(domain='preparation')
        require(field(preparation, 'availability') == 'Available', 'native preparation Available')
        save(readiness / 'preparation.json', preparation)
        final = session.api(domain='asic')
        require(not field(final, 'workflows') and not field(final, 'runs') and not field(final, 'launches'),
                'phase 1 has zero EDA workflows/runs/launch submissions')
    manifest = json.loads((args.store / 'manifest.json').read_text())
    env = dict(os.environ, **manifest['environment'])
    # Compile the companion's exact captured target before EDA activation.
    # The actual fresh workflow still executes its stock build/emission jobs later.
    command(evidence, 'prewarm-source', [str(Path(manifest['generation']) / 'tool-bin/dune'),
        'build', '--root', str(args.root), '-j2', report['identities']['build_target']],
        cwd=args.root, env=env, timeout=1800)
    command(evidence, 'scoped-source-git', [str(Path(manifest['generation']) / 'tool-bin/git'),
        '-C', str(args.root), 'rev-parse', 'HEAD'], env=env, timeout=30)
    report['simulation_receipt_sha256'] = sha(native_evidence / 'receipt.json')
    report.update(status='passed', synthesis='awaiting_explicit_allocation', eda_jobs=0,
        coverage=dict(simulation_launch='TUI/PTY LaunchForms',
            waveform_and_result_comparison='TUI/PTY; supporting exact bytes and state via API',
            source_plan_readiness='TUI/PTY endpoint form; API availability assertions',
            synthesis_launch='not_evaluated', synthesis_inspection='not_evaluated',
            synthesis_restart='not_evaluated', simulation_restart='TUI/PTY + API (inherited harness)'))


def focus(terminal, kind):
    workspace = 'Testing' if kind.startswith('simulation-') else 'Overview'
    terminal.palette('Unzoom workspace')
    for index in range(32):
        terminal.palette('Zoom focused tile')
        terminal.capture('focus-' + kind + '-' + str(time.time_ns()), [workspace])
        # Titles/frames may be hidden by retained presentation preferences. The
        # actual palette zoom is asserted through its public registry identity.
        snapshot = terminal.session.api(domain='workspace')
        if zoomed_kind(snapshot, workspace) == kind:
            return
        terminal.palette('Unzoom workspace')
        terminal.key(b'\t')
    raise AssertionError('cannot focus actual production tile ' + kind)


def zoomed_kind(snapshot, workspace_name):
    workspaces = [v for v in field(snapshot, 'workspaces') if field(v, 'name') == workspace_name]
    require(len(workspaces) == 1, 'exact named workspace for actual zoom')
    workspace = workspaces[0]
    zoomed = field(workspace, 'zoomed_tile')
    if not zoomed:
        return None
    require(len(zoomed) == 1, 'one exact zoomed tile')
    tiles = [v for v in field(snapshot, 'tiles') if field(v, 'id') == zoomed[0] and
             field(v, 'workspace') == field(workspace, 'id') and field(v, 'hidden') == 'false']
    require(len(tiles) == 1, 'zoom identifies one visible tile in this workspace')
    return field(tiles[0], 'kind')


def inspect_simulations(session, terminal, evidence, native_evidence, attempts):
    terminal.palette('Switch to Testing')
    for aid in attempts:
        detail = field(session.api(operation=['Observe', aid]), 'detail')[0]
        original = json.loads((native_evidence / ('attempt-' + aid + '.json')).read_text())
        require(detail == original, 'retained exact original simulation attempt ' + aid)
        suite = field(field(field(detail, 'captured'), 'selection'), 'suite')
        terminal.palette('Simulation: Reopen ' + aid + ' ' + suite)
        case = 'exact256' if suite == 'pt8-memory-workloads' else 'seeded'
        terminal.palette('Simulation: Select case ' + case)
        focus(terminal, 'simulation-detail')
        terminal.capture('simulation-detail-' + aid, ['Seed:', 'Parameters:', 'Process exit: 0'])
        for artifact in field(detail, 'artifacts'):
            if field(artifact, 'case_id') != [case] or not field(artifact, 'label').endswith('.sexp'):
                continue
            # FIFO reports have a general exact-byte export route, not a text viewer.
            exported_before = set(evidence.rglob('metadata.sexp'))
            terminal.palette('Simulation: Export exact bytes ' + field(artifact, 'label'))
            deadline = time.monotonic() + 20
            while True:
                metadata = [p for p in evidence.rglob('metadata.sexp') if p not in exported_before]
                if metadata:
                    require(len(metadata) == 1, 'one actual report export from production TUI')
                    exported = legacy.parse(metadata[0].read_text())
                    require(exported == artifact, 'actual exported report exact original metadata')
                    data = metadata[0].with_name('artifact.bin')
                    if data.exists():
                        require(sha(data) == field(artifact, 'sha256')[0], 'TUI report export exact bytes')
                        break
                require(time.monotonic() < deadline, 'production report export deadline')
                terminal.drain(.1)
            terminal.capture('report-export-' + aid, ['Process exit: 0'])
        focus(terminal, 'simulation-catalog')
    save(evidence / 'simulation-inspection.json', dict(attempts=attempts,
        path='TUI/PTY detail/provenance and FIFO report export; original report bytes API-verified by native harness'))


def previous(args, phase):
    require(args.previous is not None, '--previous receipt required')
    value = json.loads(args.previous.read_text())
    phases = (phase,) if isinstance(phase, str) else phase
    require(value['status'] == 'passed' and value['phase'] in phases, 'passing prerequisite phase ' + str(phase))
    require(value['store'] == str(args.store) and value['manifest_sha256'] == sha(args.store / 'manifest.json'),
            'resume exact same pinned store')
    require(value['identities'] == args.identities, 'same source layout, target and dependency receipt')
    return value


def native_prerequisite(args, prior):
    path = Path(prior['simulation_receipt'])
    raw = path.read_bytes()
    require(hashlib.sha256(raw).hexdigest() == prior['simulation_receipt_sha256'],
            'original native prerequisite receipt bytes')
    value = json.loads(raw)
    require(value['status'] == 'passed' and value['store'] == str(args.store) and
            value['root'] == str(args.root) and value['manifest_sha256'] == prior['manifest_sha256'] and
            value['identities'] == args.identities and value['attempts'] == prior['attempts'],
            'native prerequisite exact same capture and attempts')
    return value


def enforcement(args, manifest, lease):
    require('cap_receipt' in lease and 'cap_receipt_sha256' in lease,
            'separately hashed cap receipt required; lease boolean is insufficient')
    path = Path(lease['cap_receipt'])
    require(path.is_absolute() and path.resolve() == path, 'canonical cap receipt')
    require(sha(path) == lease['cap_receipt_sha256'], 'exact cap receipt bytes')
    captured = resources.capture(args.store)
    require(captured == manifest, 'resource capture equals exact acceptance manifest')
    # The resource owner validates installed transport + HostConfig + kernel
    # evidence, verifier hash, freshness, provider/SDK inventory, and opt-in.
    cap = resources.verify_cap(path, args.store, captured)
    require(sha(path) == lease['cap_receipt_sha256'], 'cap receipt unchanged during verification')
    return cap


def allocation(args, manifest, collection=None):
    allowed = args.allow_synthesis if collection is None else args.allow_collection
    require(allowed and args.allocation is not None,
            'producer phase requires its explicit allow flag AND coordinator/runtime --allocation JSON')
    value = json.loads(args.allocation.read_text())
    require(value['status'] == 'activated' and value['workers'] == 6 and value['endpoint'] == 'synthesis',
            'explicit activated six-worker synthesis-only allocation')
    require(value['store'] == str(args.store) and value['manifest_sha256'] == sha(args.store / 'manifest.json'),
            'allocation bound to exact test capture')
    require(value['expires_unix'] > time.time(), 'allocation has not expired')
    require(value['runtime_ceiling_established'] is True and value['no_competing_eda_or_builds'] is True,
            'runtime owner establishes concrete ceiling and exclusive EDA interval')
    receipt = Path(value['runtime_receipt'])
    require(receipt.is_absolute() and receipt.resolve() == receipt and receipt.name == 'ready.json',
            'runtime receipt is exact monitor ready.json')
    raw = receipt.read_bytes()
    require(hashlib.sha256(raw).hexdigest() == value['runtime_receipt_sha256'],
            'exact runtime-owner admission receipt')
    ready = json.loads(raw)
    require(ready.get('schema_version') == 2 and ready['ready'] is True and ready['pid'] == value['monitor_pid'] and
            ready['store'] == str(args.store) and ready['manifest_sha256'] == value['manifest_sha256'] and
            ready['allocation'] == value['workers'], 'monitor readiness bound to exact allocation/store')
    stop = receipt.with_name('stop-request.json')
    require(not stop.exists() and not stop.is_symlink(), 'runtime monitor has no stop request')
    pid = int(value['monitor_pid'])
    require(pid > 0, 'positive monitor PID')
    os.kill(pid, 0)
    stat = Path('/proc/%d/stat' % pid).read_text().rsplit(')', 1)[1].split()
    require(stat[0] not in ('Z', 'X', 'x') and stat[19] == str(value['monitor_start_ticks']),
            'same live runtime monitor, not zombie or reused PID')
    if 'start_ticks' in ready:
        require(str(ready['start_ticks']) == stat[19], 'ready receipt exact monitor start identity')
    require(not stop.exists() and not stop.is_symlink(), 'no stop request after monitor identity check')
    require(manifest['inputs']['asic_generation'] == value['asic_generation'], 'runtime admission exact ASIC')
    cap = enforcement(args, manifest, value)
    require(ready['runtime_ceiling_established'] is True and
            ready['asic_generation'] == value['asic_generation'] and ready['endpoint'] == 'synthesis' and
            ready['workers'] == 6 and ready['profile'] == cap['binding']['profile'] and
            ready['total_container_tasks'] == cap['binding']['total_container_tasks'] and
            ready['image'] == cap['binding']['image'] and ready['verifier_sha256'] == sha(Path(resources.__file__)) and
            ready['cap_receipt'] == value['cap_receipt'] and ready['cap_receipt_sha256'] == value['cap_receipt_sha256'] and
            ready['cap_binding'] == cap['binding'] and str(ready['monitor_start_ticks']) == stat[19],
            'schema2 observer readiness binds exact verified cap and live monitor identity')
    require(not stop.exists() and not stop.is_symlink(), 'no stop request after cap verification')
    if collection is not None:
        for record in (value, ready):
            require(record.get('operation_scope') == 'collection-only' and
                    record.get('execution_file') == collection['path'] and
                    record.get('execution_sha256') == collection['sha256'],
                    'collection-only allocation/readiness bound to exact original execution')
    return value


TERMINAL_PHASES = ('Completed', 'Failed', 'Cancelled', 'Interrupted')


def intent_workflow(snapshot, intent):
    matches = [w for w in field(snapshot, 'workflows') if field(w, 'intent') == intent]
    require(len(matches) <= 1, 'at most one exact intent-bound workflow')
    return matches[0] if matches else None


def cancel_owned(session, terminal, evidence, intent):
    # Reobserve and rebind immediately before cancelling. A previously assigned
    # workflow (or an unrelated singleton) is never cancellation authority.
    active = intent_workflow(session.api(domain='asic'), intent)
    if active is not None and field(active, 'intent') == intent and field(active, 'phase') not in TERMINAL_PHASES:
        save(evidence / 'cancel-response.json', session.api(domain='asic',
            operation=['Cancel_workflow', field(active, 'id')]))
        cancelled = wait(session, terminal, 'asic', lambda s: any(
            field(w, 'intent') == intent and field(w, 'id') == field(active, 'id') and
            field(w, 'phase') in TERMINAL_PHASES for w in field(s, 'workflows')), timeout=30)
        save(evidence / 'cancel-settled.json', cancelled)


def mark_submission(report):
    report.update(synthesis_submission_possible=True, eda_jobs=None,
        launch_path='TUI/PTY: Plan ASIC standard / balanced -> synthesis endpoint form -> Launch and view planned run in captured context')


def synthesis(args, evidence, report, manifest):
    prior = previous(args, 'simulations')
    native_prerequisite(args, prior)  # Before pair startup or any launch key.
    admitted = allocation(args, manifest)  # Before daemon/client or any launch key.
    save(evidence / 'allocation.json', admitted)
    report['resource_admission'] = dict(allocation_path=str(args.allocation),
        allocation_sha256=sha(args.allocation), runtime_receipt=admitted['runtime_receipt'],
        runtime_receipt_sha256=admitted['runtime_receipt_sha256'],
        cap_receipt=admitted['cap_receipt'], cap_receipt_sha256=admitted['cap_receipt_sha256'],
        resource_verifier_sha256=sha(Path(resources.__file__)),
        monitor_pid=admitted['monitor_pid'], monitor_start_ticks=admitted['monitor_start_ticks'])
    report['prerequisite'] = dict(path=str(args.previous), sha256=sha(args.previous))
    report['attempts'] = prior['attempts']
    report['simulation_receipt'] = prior['simulation_receipt']
    report['simulation_receipt_sha256'] = prior['simulation_receipt_sha256']
    active = None
    with pair(args, evidence / 'pair') as (session, terminal):
        def guard():
            current = allocation(args, manifest)
            require(current == admitted, 'allocation immutable throughout this launch')
        session.launch_guard = guard
        session.resource_guard = guard
        session.submission_possible = lambda: mark_submission(report)
        intent = stage(session, terminal, evidence)
        before = session.api(domain='asic')
        require(not field(before, 'workflows') and not field(before, 'runs') and not field(before, 'launches'),
                'one new synthesis only; existing implementation requires explicit evidence recovery')
        deadline = time.monotonic() + args.synthesis_timeout
        try:
            guard()
            # This is the ONLY synthesis submission: actual production palette Enter.
            terminal.palette('Launch and view planned run in captured context')
            report['synthesis_submission_entered'] = True
            while True:
                guard()
                snapshot = session.api(domain='asic')
                report['observed_run_count'] = len(field(snapshot, 'runs'))
                active = intent_workflow(snapshot, intent)
                if active is not None:
                    if 'workflow_id' not in report:
                        report['workflow_id'] = field(active, 'id')
                        save(evidence / 'allocated-workflow.json', active)
                    if field(active, 'phase') in TERMINAL_PHASES:
                        break
                require(time.monotonic() < deadline, 'bounded synthesis workflow deadline')
                terminal.drain(.4)
            save(evidence / 'workflow.json', active)
            save(evidence / 'completed-asic.json', snapshot)
            require(field(active, 'intent') == intent, 'exact actual TUI-staged intent consumed')
            require(field(active, 'phase') == 'Completed', 'actual fresh synthesis completed')
            require(field(active, 'run') and field(active, 'reference'), 'completed synthesis has exact run/allocation references')
            reference = field(active, 'run')[0]
            report['reference'] = reference
            report['allocation_reference'] = field(active, 'reference')[0]
            report['workflow_id'] = field(active, 'id')
            report['eda_jobs'] = 1
            verify_lineage(session, evidence, active, snapshot, report)
            inspect_synthesis(session, terminal, evidence, reference, report, collect=True)
            guard()  # Monitor covers collection/inspection, not only implementation.
        except BaseException:
            # Only the workflow created by this invocation is eligible for cancellation.
            try:
                session.resource_guard = None  # Revocation must not block cancellation/settling.
                cancel_owned(session, terminal, evidence, intent)
            except BaseException:
                save(evidence / 'cancel-error.json', dict(error=traceback.format_exc()))
            raise
    prefs = {str(p.relative_to(args.store)): sha(p) for p in
             (args.store / 'client-state').rglob('*') if p.is_file()}
    save(evidence / 'client-prefs-before-restart.json', prefs)
    report['client_prefs_before_restart'] = prefs
    report.update(status='passed', eda_jobs=1, acceptance='provider verdict only; no timing/physical/signoff claim')


def verify_lineage(session, evidence, workflow, snapshot, report, retained_jobs=None):
    prepared = field(workflow, 'prepared')[0]
    bundle = Path(field(prepared, 'bundle_directory')).resolve(strict=True)
    require(bundle.is_relative_to(session.args.store), 'fresh emitted bundle belongs to owned store')
    plan = Path(field(prepared, 'methodology_plan_path'))
    require(sha(plan) == field(prepared, 'methodology_plan_digest'), 'original emitted methodology plan bytes')
    document = json.loads(plan.read_bytes())
    require(document['plan_identity'] == field(prepared, 'plan_identity'), 'emitted plan exact identity')
    require(document['bundle_identity'] == field(prepared, 'bundle_identity'), 'emitted bundle exact identity')
    run = next(r for r in field(snapshot, 'runs') if field(r, 'run') == field(workflow, 'run')[0])
    require(field(run, 'reference') == field(workflow, 'reference')[0], 'workflow exact public allocation association')
    verify_run_selection(run, field(workflow, 'intent'))
    for name in ('build_job', 'emission_job'):
        option = field(workflow, name)
        if not option:
            require(retained_jobs is not None, 'source-job ownership unavailable; exact retained job evidence required')
            path = retained_jobs / (name + '-logs.json')
            retained = json.loads(path.read_text())
            job = retained['job']
            require(field(job, 'state') == 'Complete' and field(job, 'exit_status') == [['Exited', '0']],
                    'original completed source job receipt retained')
            save(evidence / (name + '-logs.json'), dict(retained,
                provenance=dict(path=str(path), sha256=sha(path), observation='original invocation; runtime job handle not durable')))
            continue
        job = option[0]
        require(field(job, 'state') == 'Complete', 'actual source ' + name + ' complete')
        logs = session.raw('/api/v1/read-log', [('instance_id', session.metadata['instance_id']),
            ('job', field(job, 'id')), ('offset', 0), ('max_records', 1000), ('max_bytes', 262144)])
        save(evidence / (name + '-logs.json'), dict(job=job, logs=logs))
    files = {str(p): sha(p) for p in bundle.rglob('*') if p.is_file()}
    files[str(plan)] = sha(plan)
    save(evidence / 'methodology-plan.json', document)
    execution = Path(field(run, 'execution_file')[0])
    require(execution.resolve().is_relative_to(session.args.store), 'original execution belongs to owned store')
    raw = execution.read_bytes()
    execution_doc = json.loads(raw)
    require(execution_doc['status'] == 'completed' and execution_doc['exit_code'] == 0,
            'original execution successful native status/exit')
    methodology = execution_doc['methodology']
    require(methodology['plan_identity'] == field(prepared, 'plan_identity') and
            methodology['bundle_identity'] == field(prepared, 'bundle_identity'),
            'original execution bound to exact fresh emitted bundle and plan')
    snapshot_path = Path(methodology['snapshot_path'])
    require(sha(snapshot_path) == methodology['snapshot_sha256'] and
            json.loads(snapshot_path.read_bytes()) == document, 'executed methodology snapshot equals emitted plan')
    files[str(snapshot_path)] = sha(snapshot_path)
    save(evidence / 'bundle-files.json', files)
    require(execution_doc['plan'].get('stages') == ['synthesis'] and
            execution_doc['plan'].get('initial_boundary') is None and
            all(a['boundary'] == 'synthesis' for a in execution_doc['artifacts']) and
            len(execution_doc['artifacts']) == 1, 'exact synthesis-only execution checkpoint, no P&R')
    (evidence / 'execution-original.json').write_bytes(raw)
    report['execution'] = dict(path=str(execution), sha256=hashlib.sha256(raw).hexdigest())
    report['prepared'] = prepared


def verify_run_selection(run, intent):
    option = field(run, 'selection')
    require(isinstance(option, list) and len(option) == 1 and isinstance(option[0], list),
            'run selection requires Some [record]')
    require(dict(option[0]) == dict(field(intent, 'selection')),
            'actual synthesis uses same unmodified staged selection')


def inspect_synthesis(session, terminal, evidence, reference, report, collect=False, existing_finalizations=None):
    guard_session(session)
    session.api(domain='asic', operation=['Refresh', reference])
    snapshot = wait(session, terminal, 'asic', lambda s: any(field(x, 'run') == reference
        and field(x, 'freshness') == 'Validated' for x in field(s, 'summaries')), timeout=120)
    summary = next(x for x in field(snapshot, 'summaries') if field(x, 'run') == reference)
    save(evidence / 'summary-before-collection.json', summary)
    require(int(field(summary, 'cell_count')[0]) > 0 and field(summary, 'cells'), 'actual mapped synthesis cells')
    require(field(summary, 'completion') == 'completed', 'provider reports actual completed synthesis')
    label = field(reference, 'backend') + '/' + field(reference, 'id')
    terminal.palette('Switch to Overview')
    if collect:
        # Report collection is the supported non-acceptance finalization path.
        # It is not another implementation run and must not request replay/signoff.
        baseline = existing_finalizations or []
        require(field(snapshot, 'finalizations') == baseline, 'exact retained finalization baseline before one collection')
        terminal.palette('Finalize (collect) ' + label)
        def completed(s):
            fresh = recovery.fresh_collection(s, baseline, reference)
            return fresh is not None and field(fresh, 'state') in ('completed', 'failed', 'cancelled', 'interrupted')
        snapshot = wait(session, terminal, 'asic', completed, timeout=180)
        finalization = recovery.fresh_collection(snapshot, baseline, reference)
        save(evidence / 'report-collection.json', finalization)
        require(field(finalization, 'state') == 'completed' and
                field(finalization, 'acceptance_requested') == 'false', 'report collection succeeds without acceptance request')
        report['finalization_attempt'] = field(finalization, 'attempt')[0]
        session.api(domain='asic', operation=['Refresh', reference])
        snapshot = wait(session, terminal, 'asic', lambda s: any(field(x, 'run') == reference
            and field(x, 'terminal') and field(x, 'freshness') == 'Validated' for x in field(s, 'summaries')))
        summary = next(x for x in field(snapshot, 'summaries') if field(x, 'run') == reference)
    require(field(summary, 'terminal'), 'exact collected terminal reports restored/adopted')
    terminal_result = field(summary, 'terminal')[0]
    require(field(terminal_result, 'attempt') == report['finalization_attempt'], 'exact report collection attempt')
    require(field(summary, 'acceptance') == 'not_evaluated', 'synthesis without acceptance remains not_evaluated')
    report['verdicts'] = dict(completion=field(summary, 'completion'), acceptance=field(summary, 'acceptance'),
        checks=field(terminal_result, 'checks'), metrics=field(terminal_result, 'metrics'))
    save(evidence / 'summary-entry.json', summary)
    report['summary'] = summary
    # Inspection actions are separately exercised through the production UI.
    workspace = session.api(domain='workspace')
    overview = next(w for w in field(workspace, 'workspaces') if field(w, 'name') == 'Overview')
    if not any(field(t, 'kind') == 'synthesis' and field(t, 'workspace') == field(overview, 'id')
               for t in field(workspace, 'tiles')):
        terminal.palette('Add synthesis tile')
    focus(terminal, 'synthesis')
    terminal.palette('Synthesis: Browse cell table')
    terminal.capture('synthesis-cells', ['cells'])
    terminal.palette('Synthesis: Inspect metrics')
    terminal.capture('synthesis-metrics', ['Synthesis metrics', 'Acceptance'])
    terminal.palette('Synthesis: Inspect full evidence')
    terminal.capture('synthesis-evidence', ['Synthesis evidence', 'Acceptance'])
    # Reports are read through catalog IDs, never client-supplied paths.
    terminal.palette('Browse reports/artifacts ' + label)
    snapshot = wait(session, terminal, 'asic', lambda s: any(field(a, 'run') == reference
        for a in field(s, 'artifacts')))
    artifacts = [a for a in field(snapshot, 'artifacts') if field(a, 'run') == reference]
    save(evidence / 'report-catalog.json', artifacts)
    terminal.capture('report-catalog', ['REPORTS / ARTIFACTS'])
    terminal.key(b'\r')
    first = artifacts[0]
    wait(session, terminal, 'asic', lambda s: any(field(p, 'artifact_id') == field(first, 'id') and
        field(p, 'offset') == '0' for p in field(s, 'artifact_pages')))
    terminal.capture('report-open', [field(first, 'label')[:30]])
    terminal.key(b'\x1b')
    terminal.key(b'\x1b')
    output = evidence / 'reports'
    output.mkdir()
    for artifact in artifacts:
        guard_session(session)
        require(field(artifact, 'terminal_attempt') == report['finalization_attempt'], 'catalog exact collection attempt')
        raw = bytearray()
        while True:
            guard_session(session)
            offset = len(raw)
            session.api(domain='asic', operation=['Read_artifact_bytes', ['run', reference],
                ['artifact_id', field(artifact, 'id')], ['offset', offset], ['limit', 65536]])
            snapshot = wait(session, terminal, 'asic', lambda s: any(field(p, 'artifact_id') == field(artifact, 'id')
                and int(field(p, 'offset')) == offset for p in field(s, 'artifact_byte_pages')))
            page = next(p for p in field(snapshot, 'artifact_byte_pages') if field(p, 'artifact_id') == field(artifact, 'id')
                        and int(field(p, 'offset')) == offset)
            require(not field(page, 'error') and field(page, 'run') == reference and
                    field(page, 'terminal_attempt') == field(artifact, 'terminal_attempt') and
                    field(page, 'sha256') == field(artifact, 'sha256'), 'report byte page exact source identity')
            block = bytes.fromhex(field(page, 'bytes_hex'))
            raw.extend(block)
            require(len(raw) <= 64 * 1024 * 1024, 'bounded original report transport')
            if field(page, 'eof') == 'true':
                break
            require(block, 'report transport advances')
        require(len(raw) == int(field(artifact, 'size')) and
                hashlib.sha256(raw).hexdigest() == field(artifact, 'sha256'), 'report exact bytes/hash/size')
        require(Path(field(artifact, 'path')).read_bytes() == raw, 'API equals original provider report bytes (direct read)')
        (output / field(artifact, 'id')).write_bytes(raw)
    # Checks is a separate production tile; unavailable checks remain unavailable.
    if not any(field(t, 'kind') == 'checks' and field(t, 'workspace') == field(overview, 'id')
               for t in field(workspace, 'tiles')):
        terminal.palette('Add checks tile')
    focus(terminal, 'checks')
    terminal.capture('synthesis-checks', ['Evidence: validated', *[
        'Check ' + field(check, 'name') + ': ' + field(check, 'status')
        for check in field(terminal_result, 'checks')]])
    report['inspection_path'] = 'TUI/PTY synthesis cells/metrics/evidence, reports catalog/open, checks tile; API exact reference/catalog bytes; direct original-file byte comparison'


def restart(args, evidence, report):
    prior = previous(args, ('synthesis', 'recover-collection', 'inspect'))
    report['prerequisite'] = dict(path=str(args.previous), sha256=sha(args.previous))
    report['reference'] = prior['reference']
    report['attempts'] = prior['attempts']
    report['finalization_attempt'] = prior['finalization_attempt']
    native_evidence = Path(prior['simulation_receipt']).parent
    require(sha(Path(prior['simulation_receipt'])) == prior['simulation_receipt_sha256'], 'original simulation receipt bytes')
    require(all(sha(args.store / path) == digest for path, digest in prior['client_prefs_before_restart'].items()),
            'same-store launch/navigation/A-B/display preference files survive pair stop')
    with pair(args, evidence / 'pair') as (session, terminal):
        before = session.api(domain='asic')
        save(evidence / 'restored-before-refresh.json', before)
        require(any(field(w, 'id') == prior['workflow_id'] for w in field(before, 'workflows')),
                'same store restores exact workflow')
        require(Path(prior['execution']['path']).read_bytes() ==
                (args.previous.parent / 'execution-original.json').read_bytes(), 'restart original execution bytes unchanged')
        for path, digest in json.loads((args.previous.parent / 'bundle-files.json').read_text()).items():
            require(sha(Path(path)) == digest, 'restart original emitted bundle byte preservation')
        attempts_before = {field(a, 'id') for a in field(session.api(), 'attempts')}
        prefs_before = {str(p.relative_to(args.store)): sha(p) for p in
            (args.store / 'client-state').rglob('*') if p.is_file()}
        save(evidence / 'client-prefs-on-reopen.json', prefs_before)
        inspect_simulations(session, terminal, evidence, native_evidence, prior['attempts'])
        for aid in prior['attempts']:
            detail = field(session.api(operation=['Observe', aid]), 'detail')[0]
            target = evidence / aid
            target.mkdir()
            save(target / 'detail.json', detail)
            terminal.palette('Switch to Testing')
            suite = field(field(field(detail, 'captured'), 'selection'), 'suite')
            terminal.palette('Simulation: Reopen ' + aid + ' ' + suite)
            focus(terminal, 'simulation-detail')
            terminal.capture('reopened-' + aid, [suite])
            for index, artifact in enumerate(field(detail, 'artifacts')):
                artifact_bytes(session, detail, artifact, target / ('artifact-%d' % index))
            case = 'exact256' if suite == 'pt8-memory-workloads' else 'seeded'
            terminal.palette('Simulation: Select case ' + case)
            wave = next(a for a in field(detail, 'artifacts') if field(a, 'case_id') == [case]
                        and field(a, 'media_type') in ('text/vcd', 'text/x-vcd'))
            terminal.palette('Simulation: Open embedded waveform ' + field(wave, 'label'))
            text = terminal.capture('restarted-wave-' + aid, ['Waveform', 'Case ' + case, field(wave, 'label')])
            verify_stacked_display(text)
            if aid == prior['attempts'][0]:
                # Cursor/filter are investigation state, not a durable reopen
                # contract. Navigate explicitly after verifying restored display.
                terminal.key(b':40\r/outputs.occupancy\r')
                terminal.capture('restarted-fifo-explicit-navigation', ['Cursor 40 ticks', 'outputs.occupancy'])
            terminal.key(b'f')
            terminal.capture('restarted-fit-' + aid, ['Fit full trace'])
            terminal.key(b'q')
        require({field(a, 'id') for a in field(session.api(), 'attempts')} == attempts_before,
                'restart/reopen investigation creates no simulation attempts')
        terminal.palette('Switch to Workloads')
        terminal.palette('Workloads: Axis resource_policy')
        terminal.capture('restarted-workload-pair', ['delta(B-A)=0'])
        state = field(session.api(domain='asic'), 'workloads')[0]
        comparison = json.loads(field(field(state, 'selected')[0], 'json'))
        original_comparison = json.loads((native_evidence / 'workloads-seven-zero-deltas.json').read_text())
        require(comparison['left']['workload']['source_digest'] == original_comparison['left']['workload']['source_digest']
                and comparison['right']['workload']['source_digest'] == original_comparison['right']['workload']['source_digest'],
                'restarted A/B retains exact original Flops/Exact result digests')
        metrics = [m for m in comparison['metrics'] if m['metric_id'].startswith('workload/')]
        require(len(metrics) == 7 and all(m['comparison'] == 'comparable' and m['right_minus_left'] == 0
                                        for m in metrics), 'restarted A/B seven comparable zero deltas')
        save(evidence / 'restarted-workloads.json', comparison)
        counts = {k: len(field(before, k)) for k in ('workflows', 'runs', 'launches', 'finalizations')}
        inspect_synthesis(session, terminal, evidence, prior['reference'], report)
        after = session.api(domain='asic')
        require(all(len(field(after, k)) == v for k, v in counts.items()), 'reopen/inspection creates no implementation or collection')
        catalog = json.loads((args.previous.parent / 'report-catalog.json').read_text())
        require(catalog == json.loads((evidence / 'report-catalog.json').read_text()), 'restart exact report catalog IDs and hashes')
        for artifact in catalog:
            name = field(artifact, 'id')
            require((args.previous.parent / 'reports' / name).read_bytes() ==
                    (evidence / 'reports' / name).read_bytes(), 'restart same report bytes')
        save(evidence / 'refreshed-after-reopen.json', after)
    report.update(status='passed', eda_jobs=0,
        waveform_restoration='exact artifact and Stacked display verified; FIFO cursor/filter explicitly navigated after reopen',
        restoration='raw restored-before-refresh receipt distinguishes cached/unverified from explicit Refresh')


def verify_stacked_display(text):
    rows = text.splitlines()
    require(any('[*]' in row and index + 1 < len(rows) and
                rows[index + 1].lstrip('│| ').startswith('= ')
                for index, row in enumerate(rows)), 'reopened waveform retains Stacked display preference')


def inspection_prerequisite(args):
    require(args.previous is not None, 'inspection-only continuation requires original failed receipt')
    prior = json.loads(args.previous.read_text())
    require(prior['status'] == 'failed' and prior['phase'] == 'synthesis' and prior['eda_jobs'] == 1 and
            prior['store'] == str(args.store) and prior['manifest_sha256'] == sha(args.store / 'manifest.json') and
            prior['identities'] == args.identities, 'inspection binds failed acceptance on exact same immutable capture')
    require('finalization_attempt' in prior and 'summary' in prior,
            'inspection requires already completed collection; never produces missing reports')
    native_prerequisite(args, prior)
    require(args.producer_summary is not None and args.producer_summary_sha256 is not None,
            'exact passing producer resource summary required')
    raw = args.producer_summary.read_bytes()
    require(hashlib.sha256(raw).hexdigest() == args.producer_summary_sha256, 'original resource summary exact bytes')
    resource = json.loads(raw)
    require(resource['completed'] is True and resource['seen_flow'] is True and
            resource['runtime_ceiling_established'] is True and resource['store'] == str(args.store) and
            resource['manifest_sha256'] == prior['manifest_sha256'] and
            resource['cap_receipt_sha256'] == prior['resource_admission']['cap_receipt_sha256'],
            'passing resource summary bound to exact original synthesis/collection')
    collected = json.loads((args.previous.parent / 'report-collection.json').read_text())
    require(field(collected, 'state') == 'completed' and field(collected, 'attempt') == [prior['finalization_attempt']] and
            field(collected, 'run') == prior['reference'] and field(collected, 'acceptance_requested') == 'false',
            'exact completed production TUI collection, no acceptance')
    execution_path = Path(prior['execution']['path'])
    require(execution_path.resolve() == execution_path and execution_path.is_relative_to(args.store) and
            sha(execution_path) == prior['execution']['sha256'] and execution_path.read_bytes() ==
            (args.previous.parent / 'execution-original.json').read_bytes(), 'inspection exact original execution')
    document = json.loads(execution_path.read_bytes())
    require(document['status'] == 'completed' and document['exit_code'] == 0 and
            document['plan']['stages'] == ['synthesis'] and document['plan']['initial_boundary'] is None,
            'original synthesis succeeded without physical extension')
    original_workflow = json.loads((args.previous.parent / 'workflow.json').read_text())
    require(field(original_workflow, 'id') == prior['workflow_id'] and field(original_workflow, 'phase') == 'Completed' and
            field(original_workflow, 'run') == [prior['reference']], 'exact completed original workflow')
    recovery.verify_files(json.loads((args.previous.parent / 'bundle-files.json').read_text()), args.store)
    collection_dir = Path(prior['finalization_attempt'])
    require(collection_dir.resolve() == collection_dir and collection_dir.is_relative_to(args.store),
            'collection operation belongs to exact test store')
    operation = json.loads((collection_dir / 'operation.json').read_text())
    require(operation['status'] == 'completed' and operation['exit_code'] == 0 and operation['acceptance'] == 'not_evaluated' and
            operation['request']['accept'] is False and operation['request']['execution'] == str(execution_path),
            'original collector completed without acceptance')
    sealed = {str(p): sha(p) for p in collection_dir.rglob('*') if p.is_file()}
    for artifact in document['artifacts']:
        path = Path(artifact['path'])
        require(path.resolve().is_relative_to(args.store), 'original checkpoint belongs to test store')
        sealed.update({str(p): sha(p) for p in path.rglob('*') if p.is_file()})
    sealed[str(execution_path)] = prior['execution']['sha256']
    return prior, original_workflow, sealed


def restored_workflow_matches(current, original):
    """Completed workflows persist; daemon-owned source-job handles do not."""
    if current is None:
        return False
    before, after = dict(original), dict(current)
    for name in ('build_job', 'emission_job'):
        if after.get(name) not in ([], before.get(name)):
            return False
        before.pop(name, None)
        after.pop(name, None)
    return before == after


def inspect_completed(args, evidence, report):
    prior, original_workflow, sealed = inspection_prerequisite(args)
    save(evidence / 'original-producer-files.json', sealed)
    report.update(producer_receipt=dict(path=str(args.previous), sha256=sha(args.previous)),
        producer_resource_summary=dict(path=str(args.producer_summary), sha256=sha(args.producer_summary)),
        attempts=prior['attempts'], simulation_receipt=prior['simulation_receipt'],
        simulation_receipt_sha256=prior['simulation_receipt_sha256'],
        reference=prior['reference'], allocation_reference=prior['allocation_reference'],
        workflow_id=prior['workflow_id'], finalization_attempt=prior['finalization_attempt'])
    with pair(args, evidence / 'pair') as (session, terminal):
        session.inspection_only = True
        before = session.api(domain='asic')
        save(evidence / 'restored-before-inspection.json', before)
        workflow = intent_workflow(before, field(original_workflow, 'intent'))
        require(restored_workflow_matches(workflow, original_workflow),
                'same completed workflow; only non-durable source-job handles may be absent')
        identities = recovery.implementation_ids(before)
        finalizations = field(before, 'finalizations')
        simulations_before = {field(v, 'id') for v in field(session.api(), 'attempts')}
        for name in ('build_job', 'emission_job'):
            original = field(original_workflow, name)
            require(len(original) == 1 and json.loads((args.previous.parent / (name + '-logs.json')).read_text())['job'] == original[0],
                    'retained source-job evidence matches original workflow')
        verify_lineage(session, evidence, workflow, before, report, retained_jobs=args.previous.parent)
        require(report['execution'] == prior['execution'], 'inspection preserves exact original execution reference')
        inspect_synthesis(session, terminal, evidence, prior['reference'], report, collect=False)
        after = session.api(domain='asic')
        require(recovery.implementation_ids(after) == identities and field(after, 'finalizations') == finalizations,
                'inspection-only continuation creates no implementation or collection')
        require({field(v, 'id') for v in field(session.api(), 'attempts')} == simulations_before,
                'inspection-only continuation creates no simulation attempts')
        save(evidence / 'after-inspection.json', after)
    recovery.verify_files(sealed, args.store)
    prefs = {str(p.relative_to(args.store)): sha(p) for p in (args.store / 'client-state').rglob('*') if p.is_file()}
    save(evidence / 'client-prefs-before-restart.json', prefs)
    report.update(status='passed', eda_jobs=0, collection_jobs=0, client_prefs_before_restart=prefs,
        provenance='read-only production TUI/API inspection of exact retained successful synthesis and collection; original failed receipt retained')


def recapture(args, evidence, report, manifest):
    """Only the supported stopped-daemon launcher may publish a new app capture."""
    inputs = recovery.load_inputs(args.recovery_inputs, args.store)
    failed, old = inputs['failed'], inputs['old_manifest']
    require(manifest == old and sha(args.store / 'manifest.json') == failed['manifest_sha256'],
            'recapture starts from exact failed acceptance generation')
    before = recovery.history_files(args.store)
    immutable = recovery.immutable_files(old)
    save(evidence / 'history-before.json', before)
    save(evidence / 'immutable-before.json', immutable)
    descriptor = inputs['descriptor']
    command(evidence, 'refresh-app-capture', [sys.executable, '-B', str(args.launcher),
        '--root', str(args.source_root), '--store', str(args.store), 'prepare', '--refresh', '--apps-only',
        '--synthesis-task-limit', '6', '--wb-build-root', descriptor['wb_build_root'],
        '--expected-daemon-sha256', descriptor['new_apps']['daemon']['sha256'],
        '--expected-client-sha256', descriptor['new_apps']['client']['sha256']], timeout=1800)
    new = json.loads((args.store / 'manifest.json').read_text())
    recovery.validate_transition(old, new, args.store)
    identities = legacy.validate_capture(args.store, args.root, new)
    require(recovery.history_files(args.store) == before, 'refresh leaves all history/preferences/results byte-identical')
    recovery.verify_files(immutable, args.store)
    require(sha(args.recovery_inputs) == inputs['descriptor_sha256'], 'recovery descriptor unchanged during refresh')
    for key in ('daemon', 'client'):
        require(new['apps'][key]['sha256'] == descriptor['new_apps'][key]['sha256'], 'exact reviewed replacement ' + key)
    transition = dict(recovery_inputs=inputs['descriptor_path'], recovery_inputs_sha256=inputs['descriptor_sha256'],
        old_manifest=dict(path=inputs['old_manifest_path'], sha256=failed['manifest_sha256']),
        new_manifest=dict(path=str(Path(new['generation']) / 'manifest.json'), sha256=sha(args.store / 'manifest.json')),
        history_files=before, immutable_files=immutable,
        original_failure=descriptor['failed_receipt'], original_resource_summary=descriptor['resource_summary'])
    save(evidence / 'transition.json', transition)
    args.identities = identities
    report.update(status='passed', eda_jobs=0, identities=identities, generation=new['generation'],
        manifest_sha256=sha(args.store / 'manifest.json'), apps=new['apps'], inputs=new['inputs'],
        source_files=new['source_files'], transition=dict(path=str(evidence / 'transition.json'),
            sha256=sha(evidence / 'transition.json')), original_failed_receipt=descriptor['failed_receipt'],
        history_and_old_capture_unchanged=True, preparation_only=True)
    return new


def recovery_prerequisite(args, manifest):
    prior = previous(args, 'recapture')
    _, transition = recovery.bound_json(prior['transition'], 'app recapture transition')
    path = Path(transition['recovery_inputs'])
    require(sha(path) == transition['recovery_inputs_sha256'], 'exact authorized recovery descriptor')
    inputs = recovery.load_inputs(path, args.store, check_app_sources=False)
    require(inputs['descriptor_sha256'] == transition['recovery_inputs_sha256'], 'descriptor bytes match recorded transition')
    recovery.validate_transition(inputs['old_manifest'], manifest, args.store)
    require(transition['old_manifest']['sha256'] == inputs['failed']['manifest_sha256'] and
            transition['new_manifest']['sha256'] == sha(args.store / 'manifest.json') and
            transition['new_manifest']['path'] == str(Path(manifest['generation']) / 'manifest.json'),
            'exact old/new generation transition; ordinary phase binding remains strict')
    recovery.verify_files(transition['immutable_files'], args.store)
    require(recovery.history_files(args.store) == transition['history_files'],
            'history/preferences/results unchanged since stopped-daemon recapture')
    for key in ('daemon', 'client'):
        require(manifest['apps'][key]['sha256'] == inputs['descriptor']['new_apps'][key]['sha256'],
                'recovery uses reviewed captured ' + key)
    return prior, inputs


def recover_collection(args, evidence, report, manifest):
    prior, inputs = recovery_prerequisite(args, manifest)
    failed = inputs['failed']
    admitted = allocation(args, manifest, collection=failed['execution'])
    save(evidence / 'allocation.json', admitted)
    report.update(prerequisite=dict(path=str(args.previous), sha256=sha(args.previous)),
        original_failed_receipt=inputs['descriptor']['failed_receipt'], transition=prior['transition'],
        original_resource_summary=inputs['descriptor']['resource_summary'],
        attempts=failed['attempts'], simulation_receipt=failed['simulation_receipt'],
        simulation_receipt_sha256=failed['simulation_receipt_sha256'],
        simulation_prerequisite_manifest_sha256=failed['manifest_sha256'], reference=failed['reference'],
        workflow_id=failed['workflow_id'], allocation_reference=failed['allocation_reference'],
        resource_admission=dict(allocation_path=str(args.allocation), allocation_sha256=sha(args.allocation),
            runtime_receipt=admitted['runtime_receipt'], runtime_receipt_sha256=admitted['runtime_receipt_sha256'],
            cap_receipt=admitted['cap_receipt'], cap_receipt_sha256=admitted['cap_receipt_sha256']))
    with pair(args, evidence / 'pair') as (session, terminal):
        def guard():
            require(allocation(args, manifest, collection=failed['execution']) == admitted,
                    'immutable collection-only admission throughout recovery')
        session.resource_guard = guard
        session.recovery_only = True
        session.collection_title = 'Finalize (collect) ' + field(failed['reference'], 'backend') + '/' + field(failed['reference'], 'id')
        session.collection_possible = lambda: report.update(collection_submission_possible=True, collection_jobs=None)
        before = session.api(domain='asic')
        save(evidence / 'history-before-recovery.json', before)
        active = intent_workflow(before, field(inputs['workflow'], 'intent'))
        require(active == inputs['workflow'], 'restored exact original completed workflow before inspection')
        baseline = field(before, 'finalizations')
        require(baseline == [inputs['collection']], 'only the original unallocated failed collection exists')
        identities = recovery.implementation_ids(before)
        simulations_before = {field(v, 'id') for v in field(session.api(), 'attempts')}
        verify_lineage(session, evidence, active, before, report)
        require(report['execution'] == failed['execution'], 'recovery inspects exact original execution; no reimplementation')
        inspect_synthesis(session, terminal, evidence, failed['reference'], report, collect=True,
                          existing_finalizations=baseline)
        guard()
        after = session.api(domain='asic')
        require(recovery.implementation_ids(after) == identities, 'collection recovery creates no workflow/run/launch')
        require({field(v, 'id') for v in field(session.api(), 'attempts')} == simulations_before,
                'collection recovery creates no simulation attempts')
        recovery.fresh_collection(after, baseline, failed['reference'])
        recovery.verify_files(inputs['outputs'], args.store)
        require(sha(Path(failed['execution']['path'])) == failed['execution']['sha256'], 'original execution unchanged after collection')
        save(evidence / 'history-after-recovery.json', after)
    prefs = {str(p.relative_to(args.store)): sha(p) for p in (args.store / 'client-state').rglob('*') if p.is_file()}
    save(evidence / 'client-prefs-before-restart.json', prefs)
    report.update(status='passed', eda_jobs=0, collection_jobs=1, client_prefs_before_restart=prefs,
        coverage='TUI/PTY exact original run Finalize (collect), inspection/reports/checks; no implementation launch')


def main():
    global CHECKS
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument('--phase', choices=('simulations', 'synthesis', 'inspect', 'recapture', 'recover-collection', 'restart'), required=True)
    parser.add_argument('--store', type=Path, required=True)
    parser.add_argument('--prepare', action='store_true')
    parser.add_argument('--owner-store', type=Path, default=EXAMPLE / '.dev/workbench-development')
    parser.add_argument('--launcher', type=Path, default=EXAMPLE / 'scripts/workbench_dev.py')
    parser.add_argument('--source-root', type=Path, default=EXAMPLE,
                        help='exact source checkout passed to new-store preparation')
    parser.add_argument('--asic-generation', type=Path, help='explicit immutable dependency; required for prepare')
    parser.add_argument('--sdk-prefix', type=Path, help='explicit SDK input; required for prepare')
    parser.add_argument('--build-target', help='optional expected target; must equal captured preparation companion')
    parser.add_argument('--synthesis-task-limit', type=int, choices=(6,),
                        help='explicit opt-in passed through to future new-store preparation')
    parser.add_argument('--evidence', type=Path)
    parser.add_argument('--previous', type=Path)
    parser.add_argument('--producer-summary', type=Path, help='passing original resource summary for inspection-only continuation')
    parser.add_argument('--producer-summary-sha256', help='exact original resource summary hash')
    parser.add_argument('--simulation-evidence', type=Path,
                        help='reuse passing native simulation evidence on this exact store; inspect/readiness again')
    parser.add_argument('--allow-synthesis', action='store_true')
    parser.add_argument('--allow-collection', action='store_true', help='explicit producer admission for recovery only')
    parser.add_argument('--recovery-inputs', type=Path, help='hash-bound failed-run proof and reviewed replacement app pair')
    parser.add_argument('--allocation', type=Path)
    parser.add_argument('--synthesis-timeout', type=int, default=1800)
    args = parser.parse_args()
    args.source_root = args.source_root.resolve(strict=True)
    args.launcher = args.launcher.resolve(strict=True)
    args.store = args.store.absolute()
    require(args.store.is_relative_to(PRIVATE) and args.store != PRIVATE and args.store.resolve() == args.store,
            'canonical private store beneath /tmp/opencode required')
    require(not args.prepare or args.phase == 'simulations', 'prepare only before simulations')
    require(args.phase == 'synthesis' or not args.allow_synthesis, '--allow-synthesis only in synthesis phase')
    require(args.phase == 'recover-collection' or not args.allow_collection, '--allow-collection only in recovery phase')
    require(args.phase == 'recapture' or args.recovery_inputs is None, '--recovery-inputs only when recording recapture')
    os.umask(0o077)
    evidence = args.evidence.absolute() if args.evidence else Path(tempfile.mkdtemp(
        prefix='developer-workflow-' + args.phase + '-', dir=PRIVATE))
    require(evidence.is_relative_to(PRIVATE) and evidence.resolve() == evidence, 'private canonical evidence')
    if args.evidence:
        evidence.mkdir()  # refuse reuse, even failed attempts
    args.evidence = evidence
    print('Evidence: ' + str(evidence), flush=True)
    report = dict(schema_version=2, status='failed', phase=args.phase, store=str(args.store),
                  argv=sys.argv, evidence=str(evidence), started_unix=time.time(), eda_jobs=0, checks=[])
    CHECKS = report['checks']
    def interrupted(signum, _frame):
        raise InterruptedError('harness interrupted by signal ' + str(signum))
    signal.signal(signal.SIGTERM, interrupted)
    baseline = None
    manifest = None
    try:
        baseline = owner_snapshot(args.owner_store)
        save(evidence / 'owner-before.json', baseline)
        require(Path(os.environ.get('OPAM_SWITCH_PREFIX', '')).name == '5.2.0+ox',
                'run under opam exec --switch=5.2.0+ox')
        if args.prepare:
            prepare(args, evidence)
        args.root = args.store / 'project'
        manifest = json.loads((args.store / 'manifest.json').read_text())
        args.identities = legacy.validate_capture(args.store, args.root, manifest)
        report['identities'] = args.identities
        require(args.build_target is None or args.build_target == args.identities['build_target'],
                'explicit expected build target equals captured companion')
        require(args.asic_generation is None or str(args.asic_generation.absolute()) ==
                manifest['inputs']['asic_generation'], 'explicit ASIC input matches selected capture')
        require(args.sdk_prefix is None or str(args.sdk_prefix.resolve(strict=True)) ==
                manifest['inputs']['sdk_prefix'], 'explicit SDK input matches selected capture')
        require(args.synthesis_task_limit is None or
                manifest['environment'].get('HARDCAML_ASIC_SYNTHESIS_TASK_LIMIT') == str(args.synthesis_task_limit),
                'explicit task-limit opt-in matches selected capture')
        report['workbench_sources'] = {str(p.relative_to(HERE.parent)): sha(p)
            for dirname in ('backend', 'daemon', 'protocol', 'provider', 'terminal', 'workspaces')
            for p in (HERE.parent / dirname).rglob('*') if p.is_file() and p.suffix in ('.ml', '.mli', '.py')}
        report['launcher'] = dict(path=str(args.launcher), sha256=sha(args.launcher))
        args.daemon, args.client = [Path(manifest['apps'][k]['path']) for k in ('daemon', 'client')]
        for k in ('daemon', 'client'):
            require(sha(getattr(args, k)) == manifest['apps'][k]['sha256'], 'captured ' + k + ' bytes')
        report.update(manifest_sha256=sha(args.store / 'manifest.json'), generation=manifest['generation'],
            source_files=manifest['source_files'], apps=manifest['apps'], inputs=manifest['inputs'],
            helper_sha256={str(p): sha(p) for p in
                (Path(__file__), HERE / 'test-development-session.py', HERE / 'developer-workflow-resources.py',
                 HERE / 'developer_workflow_recovery.py')})
        # A separate lifetime lock prevents concurrent acceptance phases on this store.
        with (args.store / 'acceptance.lock').open('a+b') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            if args.phase in ('synthesis', 'inspect', 'recover-collection', 'restart'):
                (evidence / 'pair').mkdir()
            if args.phase == 'simulations':
                simulations(args, evidence, report)
            elif args.phase == 'synthesis':
                synthesis(args, evidence, report, manifest)
            elif args.phase == 'inspect':
                inspect_completed(args, evidence, report)
            elif args.phase == 'recapture':
                manifest = recapture(args, evidence, report, manifest)
            elif args.phase == 'recover-collection':
                recover_collection(args, evidence, report, manifest)
            else:
                restart(args, evidence, report)
    except BaseException:
        report['status'] = 'failed'
        report['error'] = traceback.format_exc()
        raise
    finally:
        try:
            if baseline is not None:
                after = owner_snapshot(args.owner_store)
                save(evidence / 'owner-after.json', after)
                report['owner_manifest_configs_discovery_unchanged'] = after == baseline
                if after != baseline:
                    report['status'] = 'failed'
            if manifest:
                report['private_inputs_unchanged'] = (legacy.validate_capture(
                    args.store, args.root, manifest) == report.get('identities'))
                if not report['private_inputs_unchanged']:
                    report['status'] = 'failed'
        except BaseException:
            report['preservation_error'] = traceback.format_exc()
            report['status'] = 'failed'
        finally:
            report['finished_unix'] = time.time()
            save(evidence / 'receipt.json', report)
    require(report['status'] == 'passed', 'acceptance phase passed')
    print('PASS ' + args.phase + ': ' + str(evidence / 'receipt.json'), flush=True)


if __name__ == '__main__':
    main()
