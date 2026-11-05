#!/usr/bin/env python3
"""Private HTTP/PTY frontend smoke with a synthetic public workload reader.

Uses existing binaries; never builds, changes application config or launches EDA.
All provider controls, configs, daemon state and captures live in a new temp root.
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


PROVIDER = r'''#!/usr/bin/python3
import hashlib,json,pathlib,sys,time
root=pathlib.Path.cwd()
args=sys.argv[1:]
with (root/'calls').open('a') as f: f.write(json.dumps(args)+'\n')
if args==['--version','--json']:
 print(json.dumps({'cli_contract':{'version':4,'capabilities':{'namedflow1':True,'workload_inspection1':True,'variant_comparison1':True,'workload_comparison1':True}}}));sys.exit(0)
def inspect(path):
 d=hashlib.sha256(path.encode()).hexdigest()
 return {'contract':'hardcaml-asic.workload-inspection','schema_version':1,'source_digest':d,
 'binding':{'bundle':str(pathlib.Path(path).parent/('bundle-a' if pathlib.Path(path).stem.startswith('a-') else 'bundle-b')),'bundle_identity':d,'hardware_variant_identity':d,'workload_identity':d,'simulation_sha256':d,'simulation_attempt_id':'sim-'+pathlib.Path(path).stem},
 'controls':{'adapter':'memory-1rw-latency1-v1'},'provenance':{'sources':[{'path':path}]},
 'outcome':{'status':'completed','functional':'pass','performance':'available'},
 'metrics':[{'metric_id':'workload/cycles','name':'cycles','quantity':'integer','value':9007199254740993,'classification':'derived','unit':'cycles','stage':'functional_simulation','definition':'test-exact-token','scope':'synthetic-only'}]}
if args[0]=='workload-inspect':
 path=args[1]
 if (root/'hold').exists():
  (root/'entered').touch()
  end=time.monotonic()+12
  while (root/'hold').exists() and time.monotonic()<end: time.sleep(.01)
 if (root/'fail').exists(): print('synthetic refresh failure',file=sys.stderr);sys.exit(2)
 print(json.dumps(inspect(path)));sys.exit(0)
if args[0]=='compare':
 def flag(k): return args[args.index('--'+k)+1]
 def side(k):
  w=inspect(flag(k+'-workload'))
  return {'kind':'bundle','target':flag(k),'source_digest':w['source_digest'],'identities':{},'outcomes':{},'workload':w}
 l,r=side('left'),side('right')
 m=l['workload']['metrics'][0]
 print(json.dumps({'contract':'hardcaml-asic.variant-comparison','schema_version':1,'comparison_digest':'c'*64,'policy':'bounded-pair-v1','axis':flag('axis'),'left':l,'right':r,'differences':[],
 'metrics':[{'metric_id':'workload/cycles','left':m,'right':m,'comparison':'comparable','reasons':[],'right_minus_left':0,'right_minus_left_ratio':{'numerator':0,'denominator':1}}],'workload':{},'truncated':False}));sys.exit(0)
print('unsupported synthetic operation',file=sys.stderr);sys.exit(2)
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--client', type=Path, default=ROOT / '_build_pt8_workbench/default/terminal/main.exe')
    parser.add_argument('--daemon', type=Path, default=ROOT / '_build_pt8_workbench/default/daemon/main.exe')
    parser.add_argument('--outer-timeout', type=int, default=60)
    args = parser.parse_args()
    args.client, args.daemon = args.client.resolve(), args.daemon.resolve()
    base = Path(tempfile.mkdtemp(prefix='pt8-workloads-ui-', dir='/tmp/opencode'))
    args.evidence = base
    args.stage_timeout_seconds = None
    args.example_root = base
    provider = base / 'provider'
    provider.write_text(PROVIDER)
    provider.chmod(0o700)
    for name in ('workload-inspect', 'compare'):
        (base / ('hardcaml-asic-experimental-' + name)).write_text('synthetic companion identity')
    resources = module('pt8_ui_resources', ROOT / 'scripts/test-resource-inspector.py')
    dashboard = module('pt8_ui_dashboard', ROOT / 'scripts/test-fs0-dashboard.py')
    fs0, session = resources.native_setup(args, base, provider)
    checks = []

    def check(value, label):
        fs0.require(value, label)
        checks.append(label)

    def reads():
        path = base / 'project/calls'
        return [json.loads(line) for line in path.read_text().splitlines()
                if json.loads(line)[0] in ('workload-inspect', 'compare')] if path.exists() else []

    # Provider runs with project cwd; companion identities live beside its launcher.
    retained = base / 'retained'
    retained.mkdir()
    a, b = retained / 'a-result.json', retained / 'b-result.json'
    a.write_text('{}')
    b.write_text('{}')
    bundles = [retained / 'bundle-a', retained / 'bundle-b']
    for path in bundles:
        path.mkdir()
    terminal = None
    try:
        session.start()
        terminal = dashboard.Terminal(session)

        def key(raw):
            os.write(terminal.master, raw)
            terminal.drain(.15)

        def import_result(path):
            terminal.palette('Workloads: Import exact retained result.json')
            key(str(path).encode())
            key(b'\r')
            terminal.capture('detail-' + path.stem, ['9007199254740993', 'functional: pass'])

        terminal.capture('startup', ['Overview'])
        terminal.palette('Open Workloads workspace')
        terminal.capture('empty-workloads', ['Workloads', 'No matching retained results'])
        import_result(a)
        terminal.palette('Workloads: Capture A left result')
        terminal.capture('automatic-capture-a', ['Functional simulation'], ['CAPTURE A —'])
        import_result(b)
        terminal.palette('Workloads: Capture B right result')
        terminal.capture('automatic-capture-b', ['Functional simulation'], ['CAPTURE B —'])
        terminal.palette('Workloads: Compare captured A / B (c)')
        # Full capture identities take several screens; use the production scroll key.
        frames = []
        for n in range(18):
            frames.append(terminal.capture('comparison-%02d' % n))
            if 'delta(B-A)=0' in '\n'.join(frames):
                break
            key(b']')
        check('delta(B-A)=0' in '\n'.join(frames), 'provider comparison delta reaches native renderer')
        compare_before = len([r for r in reads() if r[0] == 'compare'])
        terminal.palette('Workloads: Swap A / B and query provider')
        end = time.monotonic() + 10
        while len([r for r in reads() if r[0] == 'compare']) == compare_before and time.monotonic() < end:
            terminal.drain(.1)
        check(len([r for r in reads() if r[0] == 'compare']) == compare_before + 1,
              'swap binds a new ordered provider query')
        terminal.palette('workloads.axis.hardware')
        end = time.monotonic() + 10
        while not any(r[0] == 'compare' and r[r.index('--axis') + 1] == 'hardware'
                      for r in reads()) and time.monotonic() < end:
            terminal.drain(.1)
        check(any(r[0] == 'compare' and r[r.index('--axis') + 1] == 'hardware'
                  for r in reads()), 'explicit axis change queries the provider with the new axis')
        before = len(reads())
        key(b'\x1b')
        key(b'/no-match\x1b')
        terminal.palette('Open Workloads workspace')
        terminal.capture('cache-only-reopen', ['Workloads'])
        check(len(reads()) == before, 'filter palette and warm workspace reopen start no provider')
        # Hold an old source read, change source via the real import form, then release.
        (base / 'project/hold').write_text('hold')
        terminal.palette('Workloads: Select ' + str(a))
        terminal.palette('Workloads: Refresh exact source/pair (r)')
        end = time.monotonic() + 10
        while not (base / 'project/entered').exists() and time.monotonic() < end:
            terminal.drain(.1)
        check((base / 'project/entered').exists(), 'held source refresh entered provider')
        # Choose a warm B while A is held; no second provider is required.
        terminal.palette('Workloads: Select ' + str(b))
        (base / 'project/hold').unlink()
        key(b'd')
        terminal.capture('late-a-does-not-retarget-b', ['b-result.json', 'sim-b-result'], ['sim-a-result'])
        check(True, 'late old-source reply cannot populate selected B')
        (base / 'project/fail').write_text('fail')
        terminal.palette('Workloads: Refresh exact source/pair (r)')
        terminal.capture('refresh-failure', ['synthetic refresh failure', 'b-result.json'])
        check(True, 'refresh failure remains visible beside retained B')
        terminal.close()
        terminal = None
        session.stop()
        before = len(reads())
        session.start()
        terminal = dashboard.Terminal(session)
        terminal.capture('restart-restores-workspace', ['Workloads'])
        terminal.palette('Open Workloads workspace')
        terminal.capture('restart-cache-unverified', ['CACHED UNVERIFIED', '9007199254740993'])
        check(len(reads()) == before, 'restart cache-only reopen retains explicit source and labels data unverified')
    finally:
        if terminal:
            terminal.close()
        resources.stop_session(session)
        (base / 'ui-receipt.json').write_text(json.dumps({'checks': checks, 'count': len(checks)}, indent=2))
        print(json.dumps({'evidence': str(base), 'checks': len(checks)}, indent=2))


if __name__ == '__main__':
    main()
