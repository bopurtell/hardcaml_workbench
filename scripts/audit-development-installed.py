#!/usr/bin/env python3
"""Read-only final installed capture comparison against C native09 provenance.

Never executes installed setup/provider/apps, opens a daemon, or writes the user
store. Only --output beneath /tmp/opencode receives new evidence.
"""
import argparse
import ast
import difflib
import hashlib
import importlib.util
import json
from pathlib import Path
import stat
import sys
import traceback

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('installed_audit_wire', HERE / 'test-fs2-native.py')
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)


def sha(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def read(path):
    return json.loads(path.read_bytes())


def normalized(value, manifest):
    if isinstance(value, list):
        return [normalized(v, manifest) for v in value]
    if isinstance(value, dict):
        return {k: normalized(v, manifest) for k, v in value.items()}
    if isinstance(value, str):
        for key in ('generation', 'project_root', 'store'):
            value = value.replace(manifest[key], '$' + key.upper())
    return value


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--store', type=Path, required=True)
    p.add_argument('--native', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args()
    args.store, args.native, args.output = args.store.resolve(strict=True), args.native.resolve(strict=True), args.output.resolve()
    assert args.output.is_relative_to(Path('/tmp/opencode')) and not args.output.is_relative_to(args.store)
    args.output.mkdir()
    installed = read(args.store / 'manifest.json')
    invocation = read(args.native / 'invocation.json')
    tested = read(Path(invocation['manifest']))
    generation, baseline = Path(installed['generation']), Path(tested['generation'])
    report = dict(passed=False, checks=[], stable_store=str(args.store), final_generation=str(generation),
        native_evidence=str(args.native), native_generation=str(baseline), new_simulations=0, new_daemons=0,
        eda=0, user_store_writes=0, attribution='native09 actual executions remain private; installed capture is compared, never reattributed')

    def check(ok, label):
        report['checks'].append(dict(passed=bool(ok), expectation=label))
        assert ok, label

    try:
        check(installed['generation_id'] == '26f0d5e474bc4d45b5fc5859325c162d', 'exact requested final generation selected')
        check(read(args.native / 'receipt.json')['status'] == 'passed', 'actual native09 receipt passed')
        report['manifest_sha256'] = sha(generation / 'manifest.json')
        report['native_manifest_sha256'] = sha(Path(invocation['manifest']))
        check(report['native_manifest_sha256'] == invocation['manifest_sha256'], 'native09 original manifest identity unchanged')
        check((args.store / 'selected').resolve() == generation, 'selected pointer agrees with final manifest')
        for name, digest in installed['captured_files'].items():
            check(sha(generation / name) == digest, 'installed immutable capture digest ' + name)
        source_before = {}
        for name, digest in installed['source_files'].items():
            actual = Path(installed['project_root']) / name
            check(not actual.is_symlink() and sha(actual) == digest == sha(generation / 'source' / name), 'authored editable/captured source agrees ' + name)
            source_before[name] = digest
        for kind, app in installed['apps'].items():
            old = tested['apps'][kind]
            check(sha(Path(app['path'])) == app['sha256'] == old['sha256'] == sha(Path(old['path'])), 'exact native-tested installed app ' + kind)
        old_router = baseline / 'provider/simulation/workbench_provider.py'
        new_router = generation / 'provider/simulation/workbench_provider.py'
        (args.output / 'router.diff').write_text(''.join(difflib.unified_diff(old_router.read_text().splitlines(True),
            new_router.read_text().splitlines(True), fromfile=str(old_router), tofile=str(new_router))))
        def runtime_ast(path):
            tree = ast.parse(path.read_text())
            tree.body = [node for node in tree.body if not (isinstance(node, ast.Assign) and any(
                isinstance(t, ast.Name) and t.id in {'SOURCE_DIRS', 'SOURCE_FILES', 'ACCEPTANCE_FILES'} for t in node.targets))]
            return ast.dump(tree, include_attributes=False)
        check(runtime_ast(old_router) == runtime_ast(new_router), 'router differs only in authored source inventory constants; all runtime/exec AST unchanged')
        report['router_sha256'] = dict(native=sha(old_router), installed=sha(new_router))
        constants = {}
        for node in ast.parse(new_router.read_text()).body:
            if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
                name = node.targets[0].id
                if name in ('SOURCE_DIRS', 'ACCEPTANCE_FILES', 'SUITE_PATHS'):
                    constants[name] = ast.literal_eval(node.value)
        check(installed['source_dirs'] == list(constants['SOURCE_DIRS']), 'manifest source directories equal installed router authored closure')
        runtime = [name for name in tested['captured_files'] if name.startswith(('provider/', 'tool-bin/', 'sdk/'))]
        different = []
        for name in runtime:
            if name == 'provider/simulation/workbench_provider.py':
                continue
            a, b = baseline / name, generation / name
            if sha(a) != sha(b):
                different.append(dict(path=name, native_sha256=sha(a), installed_sha256=sha(b)))
        report['runtime_byte_differences'] = different
        # Local build paths/OCaml source digests can vary compiled executable bytes;
        # preserve every such difference and independently compare authored inputs.
        check(all(d['path'].endswith('.exe') for d in different), 'all non-router runtime scripts/models/SDK/shim byte-identical; differences confined to rebuilt executables')
        check(installed['asic_files'] == tested['asic_files'] and installed['asic_receipt_sha256'] == tested['asic_receipt_sha256']
              and installed['inputs']['asic_generation'] == tested['inputs']['asic_generation'], 'same exact immutable ASIC provider closure/receipt')
        for name, digest in installed['asic_files'].items():
            check(sha(Path(installed['inputs']['asic_generation']) / name) == digest, 'external immutable ASIC digest ' + name)
        allowed_support = {'simulation/workbench_provider.py', 'scripts/workbench_dev.py', 'scripts/test_workbench_dev.py', 'scripts/test_pt8_waveforms.py'}
        changed, added = [], sorted(set(installed['source_files']) - set(tested['source_files']))
        marker = b'\n(* Independent C private refresh preservation control. *)\n'
        for name in sorted(set(installed['source_files']) & set(tested['source_files'])):
            a, b = baseline / 'source' / name, generation / 'source' / name
            if sha(a) != sha(b):
                change = dict(path=name, native_sha256=sha(a), installed_sha256=sha(b))
                if name == 'lib/controlled_fifo.ml':
                    check(a.read_bytes().replace(marker, b'') == b.read_bytes(), 'FIFO authored difference is solely C private refresh comments, no logic change')
                    change['classification'] = 'C private comment-only control removed'
                else:
                    check(name in allowed_support, 'other changed source is explicit B support/migration file ' + name)
                    change['classification'] = 'B authored closure/setup/test migration support'
                changed.append(change)
        check(not (set(tested['source_files']) - set(installed['source_files'])), 'final closure removes no previously captured authored source')
        report['source_changes'], report['added_source_files'] = changed, added
        for suite, expected in installed['suite_sources'].items():
            actual = {name: digest for name, digest in installed['source_files'].items() if any(
                name == root or name.startswith(root + '/') for root in constants['SUITE_PATHS'][suite])}
            check(actual == expected, 'suite guard inventory exactly covers its declared source paths: ' + suite)
            for name, digest in expected.items():
                check(installed['source_files'][name] == digest, 'suite guard binds actual authored source: ' + suite + '/' + name)
        for directory in ('test', 'asic_test', 'timing', 'named_timing', 'physical_timing'):
            check(any(n.startswith(directory + '/') for n in added), 'missing authored directory is now captured ' + directory)
        expected_acceptance = {'acceptance/' + name for name in ('dune', 'export_trace.ml', 'check_bundle.py', 'replay.v')}
        check({n for n in installed['source_files'] if n.startswith('acceptance/')} == expected_acceptance, 'only exact four authored acceptance files captured')
        check('bootstrap.sh' in installed['source_files'] and bool((Path(installed['project_root']) / 'bootstrap.sh').stat().st_mode & stat.S_IXUSR), 'authored bootstrap exists and remains executable')
        for key in ('provider_commands', 'provider_command', 'environment'):
            check(normalized(installed[key], installed) == normalized(tested[key], tested), 'runtime metadata agrees after explicit local path substitution: ' + key)
        configs = {}
        for kind in ('simulation', 'asic', 'preparation'):
            path = Path(installed['project_root']) / ('hardcaml-workbench-' + kind + '.sexp')
            check(path.is_file() and not path.is_symlink(), 'installed config is regular ' + kind)
            expected = generation / 'config' / path.name
            check(sha(path) == sha(expected), 'installed config equals exact selected capture ' + kind)
            check(normalized(native.parse(path.read_text()), installed) == normalized(native.parse((baseline / 'config' / path.name).read_text()), tested), 'config behavior matches native-tested after local paths: ' + kind)
            configs[kind] = sha(path)
        report['regular_config_sha256'] = configs
        targets = {}
        for directory in ('test', 'asic_test', 'timing'):
            path = Path(installed['project_root']) / directory / 'dune'
            targets[directory] = dict(sha256=sha(path), dune=path.read_text())
        check('--directed' in targets['test']['dune'] and '--cycles 20000' in targets['test']['dune'], 'ordinary FIFO directed/seeded authored test targets present')
        check(all(n in targets['asic_test']['dune'] for n in ('wrapper_test', 'resolution_test', 'catalog_test')) and 'core_test' in targets['timing']['dune'], 'ordinary ASIC and timing authored test targets present')
        report['ordinary_test_targets'] = targets
        known = Path('/tmp/opencode/workbench-dev-b-jzc4uvlt/store/test-evidence')
        known_result, imports, refresh = read(known / 'result.json'), read(known / 'source-import.json'), read(known / 'refresh.json')
        check(known_result['passed'] and known_result['tests_run'] == 12 and not known_result['failures'], 'known B corrected closure/migration suite passed12 tests')
        check(all(imports[k] for k in ('passed', 'source_edit_preserved', 'additions_retained_after_failed_build', 'arbitrary_support_edit_refused', 'no_acceptance_snapshots')),
              'known explicit import failure/edit preservation controls passed')
        check(all(refresh[k] for k in ('edited_source_preserved', 'history_preferences_preserved', 'publication_rollback', 'crash_requires_explicit_recovery', 'edited_configs_not_overwritten')),
              'known edited-source refresh/publication recovery controls passed')
        for race in ('empty-directory', 'symlink'):
            result = read(known / 'migration-races' / race / 'source-migration-result.json')
            check(result['installed'] == [] and (known / 'migration-races' / race / 'source-stage/test/owned.ml').is_file(),
                  'retained migration no-replace control preserves staged source: ' + race)
        ordinary = read(known / 'standard-source-flow/ordinary-tests.command.json')
        check(ordinary['exit_code'] == 0 and ordinary['eda_allocation'] == 0 and '-j2' in ordinary['argv'], 'known actual ordinary test gate passed at2 jobs/EDA0')
        report['known_B_receipts'] = {str(path): sha(path) for path in
            (known / 'result.json', known / 'source-import.json', known / 'refresh.json', known / 'standard-source-flow/ordinary-tests.command.json')}
        report['known_B_receipt_review_scope'] = 'read-only independent inspection of retained controls and source assertions; not relabelled as new C executions'
        check(read(args.store / 'manifest.json') == installed, 'final selection metadata unchanged during audit')
        check(all(sha(Path(installed['project_root']) / name) == digest for name, digest in source_before.items()), 'final authored project bytes unchanged during read-only audit')
        report['passed'] = True
    except BaseException:
        report['error'] = traceback.format_exc()
        raise
    finally:
        (args.output / 'receipt.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(dict(passed=report['passed'], output=str(args.output), runtime_byte_differences=report['runtime_byte_differences'], source_changes=report['source_changes'], added_files=len(report['added_source_files'])), indent=2))


if __name__ == '__main__':
    main()
