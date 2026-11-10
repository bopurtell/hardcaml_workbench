#!/usr/bin/env python3
"""Real-session production PTY acceptance: stage and inspect launch availability only.

Uses a new daemon/state/preferences under /tmp/opencode, with the recovery project's
real immutable configuration and driver. Never submits any launch action.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import sys
import tempfile
import time

sys.dont_write_bytecode = True
from test_endpoint_prompt_native import ROOT, module


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--real-session', type=Path, required=True)
    parser.add_argument('--client', type=Path, default=ROOT / '_build_pt8_workbench/default/terminal/main.exe')
    parser.add_argument('--daemon', type=Path, default=ROOT / '_build_pt8_workbench/default/daemon/main.exe')
    args = parser.parse_args()
    recovery = args.real_session.resolve(strict=True)
    manifest = json.loads((recovery / 'manifest.json').read_text())
    project = Path(manifest['project_root']).resolve(strict=True)
    assert project == Path(manifest['private_source_root']).resolve(strict=True)
    assert project.is_relative_to(recovery)
    args.client, args.daemon = args.client.resolve(strict=True), args.daemon.resolve(strict=True)
    binary = args.daemon
    base = Path(tempfile.mkdtemp(prefix='standard-plan-recovery-pty-', dir='/tmp/opencode'))
    args.evidence, args.example_root = base, base
    args.outer_timeout, args.stage_timeout_seconds = 30, None
    # Reuse the native HTTP session/emulator helpers, then select the actual project.
    resources = module('recovery_resources', ROOT / 'scripts/test-resource-inspector.py')
    dashboard = module('recovery_dashboard', ROOT / 'scripts/test-fs0-dashboard.py')
    fs0, session = resources.native_setup(args, base, recovery / 'provider/project.exe')
    session.root = project
    generation = Path(manifest['generation'])
    session.env.update(
        OCAMLPATH=str(generation / 'lib'), HARDCAML_ASIC_GENERATION=str(generation),
        PT8_REAL_DUNE=manifest['real_dune'], PT8_PROJECT_ROOT=str(project),
        PATH=str(recovery / 'tool-bin') + ':' + str(generation / 'bin') + ':' + os.environ['PATH'],
        OMP_NUM_THREADS='2', OPENROAD_THREADS='2', _OPENLANE_MAX_CORES='2')
    wrapper = base / 'trace-daemon'
    wrapper.write_text('#!' + sys.executable + '\nimport os,sys\nos.setsid()\nos.execvp("strace", '
                       + repr(['strace', '-f', '-s', '4096', '-e', 'trace=process', '-o',
                               str(base / 'process.strace'), '--', str(binary)])
                       + ' + sys.argv[1:])\n')
    wrapper.chmod(0o700)
    args.daemon = wrapper
    watched = [project / name for name in manifest['source_snapshot']]
    watched += list(project.glob('hardcaml-workbench-*.sexp'))
    watched += [recovery / 'manifest.json', recovery / 'source-snapshot.json', generation / 'receipt.json']
    watched += [recovery / 'provider' / name for name in manifest['captured_files']]

    def inventory():
        return {str(path): sha(path) for path in watched}

    before = inventory()
    assert all(before[str(project / name)] == digest
               for name, digest in manifest['source_snapshot'].items())
    (base / 'preservation-before.json').write_text(json.dumps(before, indent=2))
    result = dict(status='failed', evidence=str(base), session=str(recovery),
                  project=str(project), command=sys.argv, checks=[], eda_allocation=0,
                  physical_launches=0, binaries={str(p): sha(p) for p in (binary, args.client)})
    terminal = None

    def save(name, value):
        (base / (name + '.json')).write_text(json.dumps(value, indent=2))

    def check(ok, label):
        fs0.require(ok, label)
        result['checks'].append(label)

    def selection(profile='balanced', assignments=None):
        return [['flow', 'standard'], ['profile', profile], ['endpoint', 'synthesis'],
                ['assignments', assignments or []]]

    def fresh(expected, previous=None):
        deadline = time.monotonic() + 15
        while True:
            snapshot = session.rpc('asic')
            intents = fs0.field(snapshot, 'fresh_intent')
            if intents and fs0.field(intents[0], 'id') != previous:
                intent = intents[0]
                check(dict(fs0.field(intent, 'selection')) == dict(expected),
                      'PTY stages exact selection: ' + fs0.sexp(expected))
                check(fs0.field(intent, 'expected_plan_identity') == [],
                      'Fresh intent explicitly uses current-source plan identity (None)')
                scope = dict(fs0.parse(fs0.field(intent, 'scope')))
                check(scope['project_scope'][0] == str(project),
                      'Fresh intent source scope is the real private recovery project')
                preparation = dict(scope['preparation'])
                check(preparation['build_target'] == 'bin/project.exe'
                      and Path(preparation['results_root']).is_relative_to(recovery),
                      'Fresh scope carries the private preparation configuration')
                save('fresh-' + fs0.field(expected, 'profile'), intent)
                return intent
            fs0.require(time.monotonic() < deadline, 'No new fresh intent from PTY Enter')
            terminal.drain(.1)

    def escape():
        os.write(terminal.master, b'\x1b')
        terminal.drain()

    def search(title, label):
        # Deliberately no Enter: launch availability is inspected, never executed.
        for key in (b' ', b'c', b'c'):
            os.write(terminal.master, key)
            terminal.drain(.12)
        os.write(terminal.master, title.encode())
        return terminal.capture(label, [title])

    def launch_enabled(label):
        title = 'Launch and view planned run in captured context'
        screen = search(title, label)
        rows = [row for row in screen.splitlines()
                if title + ' — synthesis' in row and '> ' in row]
        check(len(rows) == 1 and '[' not in rows[0],
              'Actual production Launch and view command is enabled: ' + label)
        escape()

    def public_plan(expected, label):
        snapshot = session.rpc('asic', fs0.sexp(['Plan', expected]), wait=True)
        preview = fs0.field(snapshot, 'preview')[0]
        check(dict(fs0.field(preview, 'selection')) == dict(expected),
              'Real public Plan accepts ' + label)
        plan = json.loads(fs0.field(preview, 'plan_json'))
        check(plan['plan_identity'] == fs0.field(preview, 'plan_identity'),
              'Public Plan identity agrees with its actual methodology JSON: ' + label)
        save('public-plan-' + label, preview)
        result.setdefault('plans', {})[label] = plan['plan_identity']

    try:
        session.start()
        check(not list((base / 'client-state').rglob('launch-*.sexp')),
              'New production client starts without remembered launch preferences')
        snapshot = session.rpc('asic', 'Discover', wait=True)
        save('discovery', snapshot)
        check(fs0.field(snapshot, 'catalog_default') == [[['flow', 'standard'], ['profile', 'balanced']]],
              'Real catalog default is standard/balanced')
        preparation = session.rpc('preparation')
        save('preparation', preparation)
        check(fs0.field(preparation, 'availability') == 'Available',
              'Real native preparation capability is Available')
        terminal = dashboard.Terminal(session)
        terminal.capture('01-startup', ['Overview'])
        terminal.palette('Plan ASIC standard / balanced')
        terminal.capture('02-balanced-form', ['PLAN ENDPOINT', '> synthesis'])
        check(True, 'Exact production Plan ASIC standard / balanced form visibly defaults to synthesis')
        os.write(terminal.master, b'\r')
        initial = fresh(selection())
        terminal.capture('03-balanced-ready', ['ready: Fresh input intent', 'endpoint: synthesis'])
        launch_enabled('04-balanced-launch-enabled')
        public_plan(selection(), 'balanced')
        terminal.palette('Preparation inputs: standard / synth_delay')
        terminal.capture('05-delay-preparation-default', ['PREPARATION INPUTS', '> synthesis'])
        overrides = ['SYNTH_ABC_BUFFERING=true', 'SYNTH_STRATEGY=DELAY 1']
        prompt = 'synthesis SYNTH_ABC_BUFFERING=true "SYNTH_STRATEGY=DELAY 1"'
        os.write(terminal.master, (' ' + prompt.removeprefix('synthesis ')).encode())
        terminal.capture('06-delay-preparation-edit', [prompt])
        os.write(terminal.master, b'\r')
        terminal.drain(.8)
        terminal.palette('Plan ASIC standard / synth_delay')
        terminal.capture('07-delay-plan-retained', ['PLAN ENDPOINT', '> ' + prompt])
        check(True, 'Preparation synth_delay selection preserves its endpoint and exact multiword overrides')
        os.write(terminal.master, b'\r')
        fresh(selection('synth_delay', overrides), previous=fs0.field(initial, 'id'))
        terminal.capture('08-delay-ready', ['ready: Fresh input intent', 'endpoint: synthesis'])
        launch_enabled('09-delay-launch-enabled')
        public_plan(selection('synth_delay', overrides), 'synth_delay-override')
        snapshot = session.rpc('asic')
        save('final-asic', snapshot)
        check(not fs0.field(snapshot, 'workflows') and not fs0.field(snapshot, 'runs')
              and not fs0.field(snapshot, 'launches'),
              'No workflow, launch submission, or physical run was allocated')
        result['status'] = 'passed'
    except Exception as error:
        result['error'] = repr(error)
        raise
    finally:
        if terminal:
            terminal.close()
        if session.process:
            if session.process.poll() is None:
                os.killpg(session.process.pid, signal.SIGTERM)
                session.process.wait(timeout=15)
            result['owned_daemon_exit'] = session.process.returncode
            session.log.close()
        after = inventory()
        save('preservation-after', after)
        result['preserved'] = before == after
        trace = (base / 'process.strace').read_text() if (base / 'process.strace').exists() else ''
        result['no_eda_process'] = bool(trace) and not any(token in trace for token in (
            '"stages",', '"yosys"', '"openroad"', '"librelane"', '"iverilog"', '"vvp"'))
        save('result', result)
        print(json.dumps(result, indent=2))
        assert result['preserved'] and result['no_eda_process']


if __name__ == '__main__':
    main()
