#!/usr/bin/env python3
"""Production developer acceptance, with a durable, explicit EDA activation boundary.

Run in opam switch 5.2.0+ox. Each invocation gets a NEW evidence directory.
simulations prepares/tests/readies only; synthesis requires an external allocation;
restart reopens the exact synthesis receipt on the same store, without a launch.
The historical native session harness is imported unchanged, including its real
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
OWNER_GENERATION = 'a3553c69bfb940a4bedadeb345415b01'
ASIC_GENERATION = 'ee3af8de9f83418b9afed9c67e473e3c'
spec = importlib.util.spec_from_file_location('workflow_native', HERE / 'test-development-session.py')
legacy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(legacy)
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
    require(manifest['generation_id'] == OWNER_GENERATION, 'explicit current owner generation')
    paths = [owner / 'manifest.json', *list((owner / 'project').glob('hardcaml-workbench*.sexp'))]
    return dict(generation=manifest['generation'], hashes={str(p): sha(p) for p in paths},
                discovery=(owner / 'discovery/daemon.sexp').read_text()
                if (owner / 'discovery/daemon.sexp').exists() else None)


def prepare(args, evidence):
    require(not args.store.exists(), '--prepare requires a NEW private store')
    owner = json.loads((args.owner_store / 'manifest.json').read_text())
    require(owner['generation_id'] == OWNER_GENERATION, 'owner capture identity')
    asic = Path(owner['inputs']['asic_generation'])
    require(asic.name == ASIC_GENERATION and asic.resolve() == asic, 'exact immutable ASIC generation')
    build = HERE.parent / '_build_pt8_workbench'
    command(evidence, 'build-app-pair', ['flock', '/tmp/opencode/workbench-pt8-build.lock',
        'opam', 'exec', '--switch=5.2.0+ox', '--', 'dune', 'build', '--root', str(HERE.parent),
        '--build-dir', str(build), '-j2', 'daemon/main.exe', 'terminal/main.exe'], timeout=1800)
    command(evidence, 'prepare', [sys.executable, '-B', str(args.launcher), '--store', str(args.store),
        'prepare', '--asic-generation', str(asic), '--sdk-prefix', str(Path(owner['generation']) / 'sdk'),
        '--wb-build-root', str(build), '--git', '/usr/bin/git',
        '--expected-daemon-sha256', sha(build / 'default/daemon/main.exe'),
        '--expected-client-sha256', sha(build / 'default/terminal/main.exe')], timeout=1800)


class Terminal(legacy.Terminal):
    def key(self, key):
        with (self.session.evidence / 'pty-keys.jsonl').open('a') as out:
            out.write(json.dumps(dict(time_ns=time.time_ns(), bytes_hex=key.hex())) + '\n')
        super().key(key)

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
    workers = '6' if args.phase == 'synthesis' else '2'
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
        if terminal:
            try:
                terminal.save('last-screen', terminal.drain(.1))
            finally:
                terminal.close()
        if session.process:
            session.stop()


def wait(session, terminal, domain, predicate, timeout=60):
    deadline = time.monotonic() + timeout
    while True:
        snapshot = session.api(domain=domain)
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
    # Compile the editable root's exact _build/default target before EDA activation.
    # The actual fresh workflow still executes its stock build/emission jobs later.
    command(evidence, 'prewarm-source', [str(Path(manifest['generation']) / 'tool-bin/dune'),
        'build', '--root', str(args.root), '-j2', 'bin/project.exe'],
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
    terminal.palette('Unzoom workspace')
    for index in range(32):
        terminal.palette('Zoom focused tile')
        text = terminal.capture('focus-' + kind + '-' + str(time.time_ns()), ['Space c c commands'])
        if len(text.splitlines()) > 1 and kind in text.splitlines()[1]:
            return
        terminal.palette('Unzoom workspace')
        terminal.key(b'\t')
    raise AssertionError('cannot focus actual production tile ' + kind)


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
    require(value['status'] == 'passed' and value['phase'] == phase, 'passing prerequisite phase ' + phase)
    require(value['store'] == str(args.store) and value['manifest_sha256'] == sha(args.store / 'manifest.json'),
            'resume exact same pinned store')
    return value


def allocation(args, manifest):
    require(args.allow_synthesis and args.allocation is not None,
            'synthesis requires --allow-synthesis AND coordinator/runtime --allocation JSON')
    value = json.loads(args.allocation.read_text())
    require(value['status'] == 'activated' and value['workers'] == 6 and value['endpoint'] == 'synthesis',
            'explicit activated six-worker synthesis-only allocation')
    require(value['store'] == str(args.store) and value['manifest_sha256'] == sha(args.store / 'manifest.json'),
            'allocation bound to exact test capture')
    require(value['expires_unix'] > time.time(), 'allocation has not expired')
    require(value['runtime_ceiling_established'] is True and value['no_competing_eda_or_builds'] is True,
            'runtime owner establishes concrete ceiling and exclusive EDA interval')
    receipt = Path(value['runtime_receipt'])
    require(sha(receipt) == value['runtime_receipt_sha256'], 'exact runtime-owner admission receipt')
    os.kill(int(value['monitor_pid']), 0)
    require(Path('/proc/%d/stat' % int(value['monitor_pid'])).read_text().rsplit(')', 1)[1].split()[19]
            == str(value['monitor_start_ticks']), 'same live runtime monitor, not reused PID')
    require(manifest['inputs']['asic_generation'] == value['asic_generation'], 'runtime admission exact ASIC')
    return value


def synthesis(args, evidence, report, manifest):
    prior = previous(args, 'simulations')
    admitted = allocation(args, manifest)  # Before daemon/client or any launch key.
    save(evidence / 'allocation.json', admitted)
    report['prerequisite'] = dict(path=str(args.previous), sha256=sha(args.previous))
    report['attempts'] = prior['attempts']
    report['simulation_receipt'] = prior['simulation_receipt']
    report['simulation_receipt_sha256'] = prior['simulation_receipt_sha256']
    active = None
    with pair(args, evidence / 'pair') as (session, terminal):
        intent = stage(session, terminal, evidence)
        before = session.api(domain='asic')
        require(not field(before, 'workflows') and not field(before, 'runs') and not field(before, 'launches'),
                'one new synthesis only; existing implementation requires explicit evidence recovery')
        allocation(args, manifest)
        # This is the ONLY synthesis submission: actual production palette Enter.
        terminal.palette('Launch and view planned run in captured context')
        report['synthesis_submission_entered'] = True
        report['launch_path'] = 'TUI/PTY: Plan ASIC standard / balanced -> synthesis endpoint form -> Launch and view planned run in captured context'
        deadline = time.monotonic() + args.synthesis_timeout
        try:
            while True:
                allocation(args, manifest)
                snapshot = session.api(domain='asic')
                workflows = field(snapshot, 'workflows')
                if workflows:
                    require(len(workflows) == 1, 'exactly one fresh synthesis workflow')
                    active = workflows[0]
                    if 'workflow_id' not in report:
                        report['workflow_id'] = field(active, 'id')
                        save(evidence / 'allocated-workflow.json', active)
                    if field(active, 'phase') in ('Completed', 'Failed', 'Cancelled', 'Interrupted'):
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
        except BaseException:
            # Only the workflow created by this invocation is eligible for cancellation.
            try:
                if active is None:
                    active = next((w for w in field(session.api(domain='asic'), 'workflows')
                        if field(w, 'intent') == intent), None)
                if active and field(active, 'phase') not in ('Completed', 'Failed', 'Cancelled', 'Interrupted'):
                    save(evidence / 'cancel-response.json', session.api(domain='asic',
                        operation=['Cancel_workflow', field(active, 'id')]))
                    cancelled = wait(session, terminal, 'asic', lambda s: any(
                        field(w, 'id') == field(active, 'id') and field(w, 'phase') in
                        ('Completed', 'Failed', 'Cancelled', 'Interrupted') for w in field(s, 'workflows')), timeout=30)
                    save(evidence / 'cancel-settled.json', cancelled)
            except BaseException:
                save(evidence / 'cancel-error.json', dict(error=traceback.format_exc()))
            raise
    prefs = {str(p.relative_to(args.store)): sha(p) for p in
             (args.store / 'client-state').rglob('*') if p.is_file()}
    save(evidence / 'client-prefs-before-restart.json', prefs)
    report['client_prefs_before_restart'] = prefs
    report.update(status='passed', eda_jobs=1, acceptance='provider verdict only; no timing/physical/signoff claim')


def verify_lineage(session, evidence, workflow, snapshot, report):
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
    require(dict(field(run, 'selection')) == dict(field(field(workflow, 'intent'), 'selection')),
            'actual synthesis uses same unmodified staged selection')
    for name in ('build_job', 'emission_job'):
        job = field(workflow, name)[0]
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


def inspect_synthesis(session, terminal, evidence, reference, report, collect=False):
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
        require(not field(snapshot, 'finalizations'), 'exactly one new report collection')
        terminal.palette('Finalize (collect) ' + label)
        snapshot = wait(session, terminal, 'asic', lambda s: len(field(s, 'finalizations')) == 1 and
            field(field(s, 'finalizations')[0], 'state') in ('completed', 'failed', 'cancelled', 'interrupted'), timeout=180)
        finalization = field(snapshot, 'finalizations')[0]
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
        require(field(artifact, 'terminal_attempt') == report['finalization_attempt'], 'catalog exact collection attempt')
        raw = bytearray()
        while True:
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
    terminal.capture('synthesis-checks', ['Acceptance'])
    report['inspection_path'] = 'TUI/PTY synthesis cells/metrics/evidence, reports catalog/open, checks tile; API exact reference/catalog bytes; direct original-file byte comparison'


def restart(args, evidence, report):
    prior = previous(args, 'synthesis')
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
            terminal.capture('reopened-' + aid, [suite])
            for index, artifact in enumerate(field(detail, 'artifacts')):
                artifact_bytes(session, detail, artifact, target / ('artifact-%d' % index))
            case = 'exact256' if suite == 'pt8-memory-workloads' else 'seeded'
            terminal.palette('Simulation: Select case ' + case)
            wave = next(a for a in field(detail, 'artifacts') if field(a, 'case_id') == [case]
                        and field(a, 'media_type') in ('text/vcd', 'text/x-vcd'))
            terminal.palette('Simulation: Open embedded waveform ' + field(wave, 'label'))
            terminal.capture('restarted-wave-' + aid, ['Waveform'])
            if aid == prior['attempts'][0]:
                terminal.capture('restarted-fifo-pins', ['Cursor 40 ticks', 'outputs.occupancy'])
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
        restoration='raw restored-before-refresh receipt distinguishes cached/unverified from explicit Refresh')


def main():
    global CHECKS
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument('--phase', choices=('simulations', 'synthesis', 'restart'), required=True)
    parser.add_argument('--store', type=Path, required=True)
    parser.add_argument('--prepare', action='store_true')
    parser.add_argument('--owner-store', type=Path, default=EXAMPLE / '.dev/workbench-development')
    parser.add_argument('--launcher', type=Path, default=EXAMPLE / 'scripts/workbench_dev.py')
    parser.add_argument('--evidence', type=Path)
    parser.add_argument('--previous', type=Path)
    parser.add_argument('--simulation-evidence', type=Path,
                        help='reuse passing native simulation evidence on this exact store; inspect/readiness again')
    parser.add_argument('--allow-synthesis', action='store_true')
    parser.add_argument('--allocation', type=Path)
    parser.add_argument('--synthesis-timeout', type=int, default=1800)
    args = parser.parse_args()
    args.store = args.store.absolute()
    require(args.store.is_relative_to(PRIVATE) and args.store != PRIVATE and args.store.resolve() == args.store,
            'canonical private store beneath /tmp/opencode required')
    require(not args.prepare or args.phase == 'simulations', 'prepare only before simulations')
    require(args.phase == 'synthesis' or not args.allow_synthesis, '--allow-synthesis only in synthesis phase')
    os.umask(0o077)
    evidence = args.evidence.absolute() if args.evidence else Path(tempfile.mkdtemp(
        prefix='developer-workflow-' + args.phase + '-', dir=PRIVATE))
    require(evidence.is_relative_to(PRIVATE) and evidence.resolve() == evidence, 'private canonical evidence')
    if args.evidence:
        evidence.mkdir()  # refuse reuse, even failed attempts
    args.evidence = evidence
    print('Evidence: ' + str(evidence), flush=True)
    report = dict(schema_version=1, status='failed', phase=args.phase, store=str(args.store),
                  argv=sys.argv, evidence=str(evidence), started_unix=time.time(), eda_jobs=0, checks=[])
    CHECKS = report['checks']
    def interrupted(signum, _frame):
        raise InterruptedError('harness interrupted by signal ' + str(signum))
    signal.signal(signal.SIGTERM, interrupted)
    baseline = owner_snapshot(args.owner_store)
    save(evidence / 'owner-before.json', baseline)
    manifest = None
    try:
        require(Path(os.environ.get('OPAM_SWITCH_PREFIX', '')).name == '5.2.0+ox',
                'run under opam exec --switch=5.2.0+ox')
        if args.prepare:
            prepare(args, evidence)
        args.root = args.store / 'project'
        manifest = json.loads((args.store / 'manifest.json').read_text())
        require(manifest['project_root'] == str(args.root), 'same owned project')
        require(Path(manifest['inputs']['asic_generation']).name == ASIC_GENERATION, 'pinned ASIC generation')
        require('git_context' in manifest, 'scoped native Git capture required')
        require(all(sha(args.root / name) == digest for name, digest in manifest['source_files'].items()),
                'editable source equals exact prepared capture; no silent source drift')
        report['workbench_sources'] = {str(p.relative_to(HERE.parent)): sha(p)
            for dirname in ('backend', 'daemon', 'protocol', 'provider', 'terminal', 'workspaces')
            for p in (HERE.parent / dirname).rglob('*') if p.is_file() and p.suffix in ('.ml', '.mli', '.py')}
        report['launcher'] = dict(path=str(args.launcher), sha256=sha(args.launcher))
        args.daemon, args.client = [Path(manifest['apps'][k]['path']) for k in ('daemon', 'client')]
        for k in ('daemon', 'client'):
            require(sha(getattr(args, k)) == manifest['apps'][k]['sha256'], 'captured ' + k + ' bytes')
        report.update(manifest_sha256=sha(args.store / 'manifest.json'), generation=manifest['generation'],
            source_files=manifest['source_files'], apps=manifest['apps'], inputs=manifest['inputs'],
            helper_sha256={str(p): sha(p) for p in (Path(__file__), HERE / 'test-development-session.py')})
        # A separate lifetime lock prevents concurrent acceptance phases on this store.
        with (args.store / 'acceptance.lock').open('a+b') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            if args.phase in ('synthesis', 'restart'):
                (evidence / 'pair').mkdir()
            if args.phase == 'simulations':
                simulations(args, evidence, report)
            elif args.phase == 'synthesis':
                synthesis(args, evidence, report, manifest)
            else:
                restart(args, evidence, report)
    except BaseException:
        report['status'] = 'failed'
        report['error'] = traceback.format_exc()
        raise
    finally:
        after = owner_snapshot(args.owner_store)
        save(evidence / 'owner-after.json', after)
        report['owner_manifest_configs_discovery_unchanged'] = after == baseline
        if after != baseline:
            report['status'] = 'failed'
        if manifest:
            report['private_inputs_unchanged'] = all(sha(args.root / name) == digest
                for name, digest in manifest['source_files'].items()) and all(
                sha(Path(manifest['generation']) / name) == digest
                for name, digest in manifest['captured_files'].items()) and all(
                sha(args.root / name) == digest for name, digest in manifest['config_files'].items())
            if not report['private_inputs_unchanged']:
                report['status'] = 'failed'
        report['finished_unix'] = time.time()
        save(evidence / 'receipt.json', report)
    require(report['status'] == 'passed', 'acceptance phase passed')
    print('PASS ' + args.phase + ': ' + str(evidence / 'receipt.json'), flush=True)


if __name__ == '__main__':
    main()
