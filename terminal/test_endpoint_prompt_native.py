#!/usr/bin/env python3
"""Isolated production HTTP/PTY Plan form regression using the real catalog fixture.

No source builds, emission, or physical launches: the project driver permits only
flow list and the provider permits only version negotiation. All state is private.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import time

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--client', type=Path, default=ROOT / '_build_pt8_workbench/default/terminal/main.exe')
    parser.add_argument('--daemon', type=Path, default=ROOT / '_build_pt8_workbench/default/daemon/main.exe')
    args = parser.parse_args()
    args.client, args.daemon = args.client.resolve(), args.daemon.resolve()
    base = Path(tempfile.mkdtemp(prefix='endpoint-prompt-', dir='/tmp/opencode'))
    args.evidence, args.example_root = base, base
    args.outer_timeout, args.stage_timeout_seconds = 30, None
    provider = base / 'provider'
    provider.write_text('''#!/usr/bin/python3
import json,pathlib,sys
with (pathlib.Path.cwd()/'provider-calls').open('a') as f: f.write(json.dumps(sys.argv[1:])+'\\n')
assert sys.argv[1:]==['--version','--json'], 'No provider operations permitted'
print(json.dumps({'cli_contract':{'version':4,'capabilities':{'namedflow1':True}}}))
''')
    provider.chmod(0o700)
    resources = module('endpoint_resources', ROOT / 'scripts/test-resource-inspector.py')
    dashboard = module('endpoint_dashboard', ROOT / 'scripts/test-fs0-dashboard.py')
    fs0, session = resources.native_setup(args, base, provider)
    catalog = (ROOT / 'backend/test/asic/production_flow_list.json').read_text()
    driver = base / 'no-project-execution'
    driver.write_text('''#!/usr/bin/python3
import json,pathlib,sys
with (pathlib.Path.cwd()/'project-calls').open('a') as f: f.write(json.dumps(sys.argv[1:])+'\\n')
assert sys.argv[1:]==['flow','list','--json'], 'Only catalog reads permitted'
print(''' + repr(catalog) + ''')
''')
    preparation = session.root / 'hardcaml-workbench-preparation.sexp'
    preparation.write_text(fs0.sexp([
        ['schema_version', '1'], ['build_target', 'never-built.exe'],
        ['results_root', str(base / 'emission')], ['timeout_seconds', '10']]))
    terminal = None
    checks = []

    def check(ok, label):
        fs0.require(ok, label)
        checks.append(label)

    def fresh_selection():
        deadline = time.monotonic() + 12
        while True:
            snapshot = session.rpc('asic')
            intents = fs0.field(snapshot, 'fresh_intent')
            if intents:
                return fs0.field(intents[0], 'selection')
            fs0.require(time.monotonic() < deadline, 'Plan did not stage fresh inputs')
            time.sleep(.05)

    try:
        session.start()
        snapshot = session.rpc('asic', 'Discover', wait=True)
        flow = next(f for f in fs0.field(snapshot, 'flows') if fs0.field(f, 'id') == 'standard')
        check(fs0.field(flow, 'fresh_stage_endpoints') ==
              json.loads(catalog)['declaration']['entries'][0]['methodology']['endpoints'],
              'Native API preserves the real standard endpoint catalog')
        terminal = dashboard.Terminal(session)
        terminal.capture('startup', ['Overview'])
        terminal.palette('Preparation inputs: standard / balanced')
        terminal.capture('preparation-initial', ['PREPARATION INPUTS', '> synthesis'])
        check(True, 'Preparation also prefills from the catalog before any selection is remembered')
        os.write(terminal.master, b'\x1b')
        terminal.drain()
        terminal.palette('Plan ASIC standard / balanced')
        terminal.capture('plan-default', ['PLAN ENDPOINT', '> synthesis'])
        check(True, 'Production Plan dispatch visibly prefills synthesis from the real catalog')
        os.write(terminal.master, b'\r')
        selection = fresh_selection()
        check(fs0.record(selection) == dict(flow='standard', profile='balanced', endpoint='synthesis', assignments=[]),
              'Accepting Plan without typing stages exact synthesis inputs')
        terminal.capture('staged', ['ready: Fresh input intent', 'endpoint: synthesis'])
        terminal.palette('Preparation inputs: standard / balanced')
        terminal.capture('preparation-default', ['PREPARATION INPUTS', '> synthesis'])
        os.write(terminal.master, b'\x7f' * len('synthesis') + b'routing WIDTH=8')
        terminal.capture('preparation-edited', ['> routing WIDTH=8'])
        os.write(terminal.master, b'\r')
        terminal.drain(.8)
        terminal.palette('Plan ASIC standard / balanced')
        terminal.capture('plan-retained', ['PLAN ENDPOINT', '> routing WIDTH=8'])
        check(True, 'Preparation selection retains the exact endpoint and overrides in Plan')
        os.write(terminal.master, b'\x1b')
        terminal.drain()
        terminal.palette('Plan ASIC standard / synth_delay')
        terminal.capture('other-profile', ['PLAN ENDPOINT', '> synthesis'])
        check(True, 'A different profile gets its catalog-derived initial endpoint')
        snapshot = session.rpc('asic')
        check(not fs0.field(snapshot, 'workflows') and not fs0.field(snapshot, 'runs'),
              'Plan stages inputs without launching a workflow or physical run')
        check(all(json.loads(line) == ['flow', 'list', '--json']
                  for line in (session.root / 'project-calls').read_text().splitlines()),
              'Only real-catalog reads executed in the project driver')
        calls = session.root / 'provider-calls'
        check(not calls.exists() or all(json.loads(line) == ['--version', '--json']
                                       for line in calls.read_text().splitlines()),
              'No EDA or provider execution beyond version negotiation')
        (base / 'result.json').write_text(json.dumps(dict(status='passed', checks=checks), indent=2))
        print(json.dumps(dict(status='passed', evidence=str(base), checks=checks), indent=2))
    finally:
        if terminal:
            terminal.close()
        resources.stop_session(session)


if __name__ == '__main__':
    main()
