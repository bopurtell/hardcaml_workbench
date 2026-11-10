#!/usr/bin/env python3
"""A independent B lifecycle/router review. Private --store; no B production edits.

No functional simulation or EDA. Real prepare/refresh uses B's two-job locked
source build. Publication fault fixtures never serve as runtime app captures.
"""
import argparse
import copy
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import urllib.request
import uuid
from unittest.mock import patch

sys.dont_write_bytecode = True
WB = Path(__file__).resolve().parents[2]
EXAMPLE = WB.parent / 'hardcaml_asic_example'
sys.path.insert(0, str(EXAMPLE / 'scripts'))
sys.path.insert(0, str(EXAMPLE / 'simulation'))
import workbench_dev as dev
import workbench_provider as router
from wire import parse, sexp


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--cancel-probe', type=Path, required=True)
    args = parser.parse_args()
    evidence = args.evidence.absolute()
    assert evidence.is_relative_to(Path('/tmp/opencode')) and not evidence.exists()
    evidence.mkdir()
    store = evidence / 'store'
    records = dict(completed=False, checks=[], findings=[], new_simulations=0, eda=0)
    protected_paths = [EXAMPLE / name for name in (
        'hardcaml-workbench-simulation.sexp', 'hardcaml-workbench-asic.sexp',
        'hardcaml-workbench-preparation.sexp', 'asic/project.ml', 'acceptance/dune',
        'scripts/workbench_dev.py', 'scripts/test_workbench_dev.py', 'simulation/workbench_provider.py')]
    protected = {str(p): router.sha(p) for p in protected_paths}
    user_manifest = EXAMPLE / '.dev/workbench-development/manifest.json'
    if user_manifest.exists():
        protected[str(user_manifest)] = router.sha(user_manifest)
        for name in dev.CONFIGS:
            p = EXAMPLE / '.dev/workbench-development/project' / dev.config_name(name)
            protected[str(p)] = router.sha(p)
    home = evidence / 'home'
    home.mkdir()
    env = dict(os.environ, HOME=str(home), XDG_CONFIG_HOME=str(home / 'config'), PYTHONDONTWRITEBYTECODE='1')
    prefix = [sys.executable, '-B', str(EXAMPLE / 'scripts/workbench_dev.py'), '--store', str(store)]
    counter = 0

    def check(ok, label):
        records['checks'].append(dict(passed=bool(ok), label=label))
        print(('PASS ' if ok else 'FINDING ') + label, flush=True)
        if not ok:
            records['findings'].append(label)

    def command(label, argv, expected=0, timeout=240):
        result = subprocess.run(list(map(str, argv)), capture_output=True, env=env, timeout=timeout)
        (evidence / (label + '.stdout')).write_bytes(result.stdout)
        (evidence / (label + '.stderr')).write_bytes(result.stderr)
        records.setdefault('commands', []).append(dict(label=label, argv=list(map(str, argv)), exit_code=result.returncode))
        assert result.returncode == expected, (label, result.stderr.decode())
        return result

    def prepare(*options, expected=0):
        nonlocal counter
        counter += 1
        return command('prepare-%02d' % counter, prefix + ['prepare', *options], expected, timeout=600)

    def selected():
        return json.loads((store / 'manifest.json').read_text())

    def snapshot(path):
        return {str(p.relative_to(path)): router.sha(p) for p in path.rglob('*') if p.is_file()}

    daemon = None
    try:
        prepare()
        initial = selected()
        check(all((store / 'project' / name).is_file() and not (store / 'project' / name).is_symlink()
                  and router.sha(store / 'project' / name) == digest for name, digest in initial['config_files'].items()),
              'initial publication has three exact regular production configs')
        with dev.locked('/tmp/opencode/workbench-pt8-build.lock'):
            check(all(router.sha(app['path']) == app['sha256'] == router.sha(
                WB / '_build_pt8_workbench/default' / ('terminal' if kind == 'client' else 'daemon') / 'main.exe')
                for kind, app in initial['apps'].items()), 'captured app pair matches both locked source binaries')
        check(all(not (Path(app['path']).stat().st_mode & 0o222) for app in initial['apps'].values()),
              'captured apps are read-only immutable generation files')
        old_inventory = snapshot(Path(initial['generation']))
        prepare()
        check(selected() == initial, 'repeat prepare preserves exact generation selection')

        # Discover through production regular-config admission, not a router-only shortcut.
        out = (evidence / 'daemon.stdout').open('wb')
        err = (evidence / 'daemon.stderr').open('wb')
        daemon = subprocess.Popen(prefix + ['daemon'], env=env, stdout=out, stderr=err)
        try:
            metadata_path = store / 'discovery/daemon.sexp'
            deadline = time.monotonic() + 30
            while not metadata_path.exists() and daemon.poll() is None and time.monotonic() < deadline:
                time.sleep(.03)
            assert daemon.poll() is None and metadata_path.exists()
            metadata = dict(parse(metadata_path.read_text()))
            requests = []

            def http(path, operation):
                req = urllib.request.Request(metadata['endpoint'] + path, data=sexp(operation).encode(),
                    headers={'Content-Type': 'application/sexp', 'X-Workbench-Protocol': '1'})
                with urllib.request.urlopen(req, timeout=30) as response:
                    body = response.read().decode()
                result = parse(body)
                requests.append(dict(path=path, request=operation, response=result))
                assert result[0] == 'Ok', result
                return result[1]

            opened = dict(http('/api/v1/open-project', [('instance_id', metadata['instance_id']),
                ('root', str(store / 'project')), ('environment', 'Inherit_daemon')]))
            project_id = dict(opened['project'])['id']

            def simulation(operation):
                return dict(http('/api/v1/simulation', [('instance_id', metadata['instance_id']),
                    ('project', project_id), ('operation', operation)]))

            discovery = simulation('Discover')
            while not discovery['discovery'] and not discovery['discovery_error'] and time.monotonic() < deadline:
                time.sleep(.05)
                discovery = simulation('Get')
            check(not discovery['discovery_error'] and bool(discovery['discovery']),
                  'actual native Discover admits unchanged regular configs')
            suites = dict(discovery['discovery'][0])['suites']
            check([dict(s)['id'] for s in suites] == list(router.SUITES), 'native Discover exposes exactly FIFO then PT8')
            children = []
            for suite in router.SUITES:
                result = command('child-discover-' + suite, initial['provider_commands'][suite] + ['discover', '--protocol-version', '1'])
                children.extend(dict(parse(result.stdout.decode()))['suites'])
            check(suites == children, 'native combined catalog equals exact real child catalog union')
            (evidence / 'native-discover.json').write_text(json.dumps(requests, indent=2))
            prepare()
            prepare('--refresh', expected=2)
            check(selected() == initial, 'active launched daemon fences refresh but permits read-only prepare')
        finally:
            daemon.terminate()
            daemon.wait(timeout=15)
            daemon = None
            out.close()
            err.close()

        # Each lifetime lock must independently block before capture/publication.
        for name in ('state', 'discovery'):
            before = snapshot(store / 'receipts')
            with dev.locked(store / name / 'lifetime.lock'):
                prepare('--refresh', expected=2)
            check(selected() == initial and snapshot(store / 'receipts') == before,
                  name + ' lifetime lock refuses refresh before allocating capture receipts')

        # Local request/exec controls never invoke a functional simulator.
        def request(label, suite, manifest=None):
            directory = evidence / label
            directory.mkdir()
            artifacts = directory / 'artifacts'
            artifacts.mkdir()
            req = directory / 'request with spaces.sexp'
            req.write_text(sexp([('protocol_version', 1), ('attempt_id', 'review-' + label),
                ('selection', [('suite', suite), ('cases', ['directed'] if suite == 'controlled-fifo' else ['exact256']),
                    ('seed', '42' if suite == 'controlled-fifo' else '34097'),
                    ('parameters', [('checker', 'normal'), ('cycles', '64')] if suite == 'controlled-fifo' else []),
                    ('asic_inputs', [])])]) + '\n\n')
            events = directory / 'events.sexp'
            events.touch()
            router_command = initial['provider_command'] if manifest is None else [sys.executable, '-B',
                initial['provider_command'][2], '--manifest', str(manifest)]
            tail = ['run', '--protocol-version', '1', '--request', str(req), '--events', str(events), '--artifact-dir', str(artifacts)]
            return directory, req, events, artifacts, router_command + tail, tail

        child = evidence / 'exec_child.py'
        child.write_text('import hashlib,json,os,pathlib,sys\na=sys.argv[1:]\np=pathlib.Path(a[a.index("--request")+1])\nprint(json.dumps(dict(pid=os.getpid(),pgid=os.getpgrp(),argv=a,request_sha=hashlib.sha256(p.read_bytes()).hexdigest())))\n')
        for suite in router.SUITES:
            fixture = copy.deepcopy(initial)
            fixture['provider_commands'][suite] = [sys.executable, str(child)]
            manifest = evidence / ('exec-' + suite + '.json')
            manifest.write_text(json.dumps(fixture))
            directory, req, events, artifacts, argv, tail = request('route-' + suite, suite, manifest)
            process = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, start_new_session=True)
            stdout, stderr = process.communicate(timeout=30)
            (directory / 'stdout').write_bytes(stdout)
            assert process.returncode == 0, stderr
            identity = json.loads(stdout)
            check(identity['pid'] == process.pid == identity['pgid'] and identity['argv'] == tail
                  and identity['request_sha'] == router.sha(req) and events.read_bytes() == b'' and not list(artifacts.iterdir()),
                  suite + ' routing execs exact untouched argv/request/PID/process group')

        for suite, path in [('controlled-fifo', 'lib/controlled_fifo.ml'), ('pt8-memory-workloads', 'variants/variant_memory.ml')]:
            editable = store / 'project' / path
            original = editable.read_bytes()
            try:
                editable.write_bytes(original + b'\n(* independent source drift review *)\n')
                directory, req, events, artifacts, argv, _ = request('stale-' + suite, suite)
                result = command('stale-' + suite, argv, expected=2)
                check(b'prepare --refresh' in result.stderr and events.read_bytes() == b'' and not list(artifacts.iterdir()),
                      suite + ' edited relevant source refuses frozen execution before events/artifacts')
            finally:
                editable.write_bytes(original)

        # Refuse every edited installed config, including one late in publication order.
        for kind in dev.CONFIGS:
            config = store / 'project' / dev.config_name(kind)
            original = config.read_bytes()
            dev.replace_regular(config, original + b'\n; third-party owned edit\n')
            edited = config.read_bytes()
            before = snapshot(store / 'receipts')
            prepare('--refresh', expected=2)
            check(config.read_bytes() == edited and selected() == initial and snapshot(store / 'receipts') == before,
                  kind + ' modified config ownership refuses overwrite/capture')
            dev.replace_regular(config, original)

        # Isolated state-machine fixtures: kill publication at each replacement and
        # after selection, then check fencing and all-file recovery prevalidation.
        class Crash(BaseException):
            pass

        for checkpoint in (0, 1, 2, 3, 4):
            scratch = evidence / ('publication-' + str(checkpoint))
            for part in ('project', 'generations', 'receipts', 'state', 'discovery'):
                (scratch / part).mkdir(parents=True, exist_ok=True)
            dep = scratch / 'dependency'
            dep.mkdir()
            (dep / 'receipt.json').write_text('{}')

            def candidate(value):
                generation = scratch / 'generations' / value
                (generation / 'config').mkdir(parents=True)
                for kind in dev.CONFIGS:
                    (generation / 'config' / dev.config_name(kind)).write_text(value + '-' + kind)
                manifest = dict(schema_version=1, store=str(scratch), project_root=str(scratch / 'project'),
                    generation=str(generation), generation_id=value, inputs=dict(asic_generation=str(dep)), asic_files={},
                    asic_receipt_sha256=router.sha(dep / 'receipt.json'), captured_files=dev.tree_hashes(generation),
                    config_files={dev.config_name(kind): router.sha(generation / 'config' / dev.config_name(kind)) for kind in dev.CONFIGS})
                dev.write(generation / 'manifest.json', manifest)
                receipt = scratch / 'receipts' / value
                receipt.mkdir()
                return manifest, receipt

            old, _ = candidate('old')
            new, receipt = candidate('new')
            for kind in dev.CONFIGS:
                name = dev.config_name(kind)
                dev.replace_regular(scratch / 'project' / name, (Path(old['generation']) / 'config' / name).read_bytes())
            (scratch / 'manifest.json').symlink_to('selected/manifest.json')
            dev.select_generation(scratch, old['generation'])
            original_replace, original_select = dev.replace_regular, dev.select_generation
            calls = 0

            def interrupted_replace(path, data):
                nonlocal calls
                original_replace(path, data)
                calls += 1
                if checkpoint == 0 and calls == 1:
                    raise RuntimeError('ordinary publication failure after first replacement')
                if calls == checkpoint:
                    raise Crash()

            def interrupted_select(*argv):
                original_select(*argv)
                if checkpoint == 4:
                    raise Crash()

            with dev.locked(scratch / 'prepare.lock'), dev.locked(scratch / 'state/lifetime.lock'), dev.locked(scratch / 'discovery/lifetime.lock'):
                try:
                    with patch.object(dev, 'replace_regular', interrupted_replace), patch.object(dev, 'select_generation', interrupted_select):
                        dev.publish(scratch, old, new, receipt)
                except Crash:
                    pass
                except RuntimeError:
                    assert checkpoint == 0
                    dev.verify(old)
                    check(dev.selected_manifest(scratch) == old and not (scratch / 'publication.json').exists(),
                          'ordinary publication failure automatically rolls back all configs/selection')
                    continue
                else:
                    raise AssertionError('publication interruption was not reached')
                try:
                    dev.selected_manifest(scratch)
                except RuntimeError as error:
                    check('prepare --refresh' in str(error), 'publication checkpoint%d fences readers' % checkpoint)
                else:
                    raise AssertionError('unsettled selection admitted')
                edited_path = scratch / 'project' / dev.config_name('preparation')
                owned = edited_path.read_bytes()
                dev.replace_regular(edited_path, owned + b' unknown edit')
                before = snapshot(scratch / 'project')
                selected_before = os.readlink(scratch / 'selected')
                try:
                    dev.recover_publication(scratch)
                except RuntimeError as error:
                    check('refusing overwrite' in str(error) and snapshot(scratch / 'project') == before
                          and os.readlink(scratch / 'selected') == selected_before,
                          'checkpoint%d validates ALL configs before rollback; third-party edit untouched' % checkpoint)
                else:
                    raise AssertionError('unknown edit was overwritten')
                dev.replace_regular(edited_path, owned)
                if checkpoint == 4:
                    third, _ = candidate('third-party-selection')
                    dev.select_generation(scratch, third['generation'])
                    unchanged = snapshot(scratch / 'project')
                    try:
                        dev.recover_publication(scratch)
                    except RuntimeError as error:
                        check('selection edited' in str(error) and snapshot(scratch / 'project') == unchanged
                              and (scratch / 'selected').resolve() == Path(third['generation']),
                              'interrupted recovery refuses third-party selection without touching configs')
                    else:
                        raise AssertionError('third-party selection overwritten')
                    dev.select_generation(scratch, new['generation'])
                dev.recover_publication(scratch)
                dev.verify(old)
                check(dev.selected_manifest(scratch) == old and not (scratch / 'publication.json').exists(),
                      'checkpoint%d explicit recovery restores old selection and all configs' % checkpoint)

        # Actual source refresh: edited source and preexisting native state stay put.
        (store / 'state/review-history-artifact').write_bytes(b'old attempt/artifact sentinel\0')
        (store / 'client-state/review-preferences').write_bytes(b'exact display preference sentinel')
        durable = {part: snapshot(store / part) for part in ('state', 'client-state')}
        editable = store / 'project/lib/controlled_fifo.ml'
        editable.write_bytes(editable.read_bytes() + b'\n(* retained A independent editable-source review *)\n')
        edited_hash = router.sha(editable)
        prepare('--refresh', '--dune', '/bin/false', expected=2)
        check(selected() == initial and router.sha(editable) == edited_hash and
              all(snapshot(store / part) == files for part, files in durable.items()),
              'actual failed build refresh preserves edited source, selection and all existing durable files')
        prepare('--refresh')
        current = selected()
        check(current['generation'] != initial['generation'] and current['project_root'] == initial['project_root']
              and current['source_files']['lib/controlled_fifo.ml'] == edited_hash == router.sha(editable),
              'actual successful refresh captures editable source without recopying owner checkout')
        check(all(snapshot(store / part) == files for part, files in durable.items()) and
              snapshot(Path(initial['generation'])) == old_inventory,
              'successful refresh retains old immutable capture and every existing state/preference byte')
        records['prepared_store'] = str(store)
        records['initial_generation'] = initial['generation']
        records['final_generation'] = current['generation']
        records['apps'] = current['apps']
        # Record the already-raised general-development closure question precisely.
        omitted = [name for name in ('test', 'asic_test', 'timing', 'named_timing', 'physical_timing')
                   if (EXAMPLE / name).is_dir() and not (store / 'project' / name).exists()]
        records['source_closure_omissions'] = omitted
        check(not omitted, 'general-development source-complete claim includes existing test/timing source directories')
        # Revalidate retained real cancellation prefixes with actual production FS2 semantics.
        retained = Path('/tmp/opencode/workbench-dev-b-t8l6wa8a/store/test-evidence')
        for suite in router.SUITES:
            command('cancel-prefix-' + suite, [args.cancel_probe, retained / ('cancel-' + suite) / 'events.sexp'])
            check(True, suite + ' retained real cancellation prefix passes production codec/reducer cancellation')
        records['completed'] = True
    finally:
        if daemon is not None:
            daemon.terminate()
            daemon.wait(timeout=15)
        records['protected'] = dict(before=protected, after={p: router.sha(p) for p in protected})
        check(records['protected']['before'] == records['protected']['after'],
              'owner configs, modified owner sources, B production/tests and user selection unchanged')
        (evidence / 'receipt.json').write_text(json.dumps(records, indent=2) + '\n')
    return 1 if records['findings'] else 0


if __name__ == '__main__':
    raise SystemExit(main())
