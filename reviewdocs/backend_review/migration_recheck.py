#!/usr/bin/env python3
"""Independent correction recheck; private fixtures/store, stable generation read-only."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
from types import SimpleNamespace
from unittest.mock import patch

sys.dont_write_bytecode = True
WB = Path(__file__).resolve().parents[2]
EXAMPLE = WB.parent / 'hardcaml_asic_example'
sys.path[:0] = [str(EXAMPLE / 'scripts'), str(EXAMPLE / 'simulation')]
import workbench_dev as dev
import workbench_provider as router


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--store', type=Path, required=True)
    args = parser.parse_args()
    evidence, store = args.evidence.absolute(), args.store.absolute()
    assert evidence.is_relative_to(Path('/tmp/opencode')) and not evidence.exists()
    assert store.is_relative_to(Path('/tmp/opencode/development-backend-a-review-02'))
    evidence.mkdir()
    report = dict(completed=False, checks=[], new_simulations=0, eda=0)
    protected_names = ['scripts/workbench_dev.py', 'scripts/test_workbench_dev.py',
                       'simulation/workbench_provider.py', 'asic/project.ml', 'acceptance/dune']
    stable = EXAMPLE / '.dev/workbench-development'
    protected = {str(EXAMPLE / n): router.sha(EXAMPLE / n) for n in protected_names}
    protected[str(stable / 'manifest.json')] = router.sha(stable / 'manifest.json')
    for kind in dev.CONFIGS:
        for root in (EXAMPLE, stable / 'project'):
            p = root / dev.config_name(kind)
            protected[str(p)] = router.sha(p)

    def check(ok, label):
        report['checks'].append(dict(passed=bool(ok), label=label))
        print(('PASS ' if ok else 'FAIL ') + label, flush=True)
        assert ok, label

    def hashes(root):
        return {str(p.relative_to(root)): router.sha(p) for p in root.rglob('*') if p.is_file() and not p.is_symlink()}

    def fixture(label, *, support=False):
        root = evidence / label
        owner, project, receipt = root / 'owner', root / 'store/project', root / 'receipt'
        for p in (owner, project, receipt):
            p.mkdir(parents=True)
        for name in dev.IMPORT_GROUPS:
            if name != 'test':
                p = project / name
                if name == 'bootstrap.sh':
                    p.write_text('existing bootstrap')
                else:
                    p.mkdir()
        (owner / 'test').mkdir()
        (owner / 'test/fifo_test.ml').write_text('authored test fixture\n')
        (owner / 'test/dune').write_text('authored rule fixture\n')
        baseline = {}
        if support:
            for name in dev.OWNED_SUPPORT:
                p, q = owner / name, project / name
                p.parent.mkdir(parents=True, exist_ok=True)
                q.parent.mkdir(parents=True, exist_ok=True)
                p.write_text('new support ' + name)
                q.write_text('baseline support ' + name)
                baseline[name] = router.sha(q)
        prior = dict(source_owner_root=str(owner), source_files=baseline,
                     inputs=dict(git_dir=str(owner / '.git')))
        options = SimpleNamespace(root=owner, import_missing_source=not support, update_owned_support=support)
        return root, owner, project, receipt, prior, options

    def migrate(parts):
        root, owner, project, receipt, prior, options = parts
        return dev.migrate_sources(options, root / 'store', prior, receipt)

    try:
        manifest = json.loads((stable / 'manifest.json').read_text())
        check(manifest['generation_id'] == '26f0d5e474bc4d45b5fc5859325c162d', 'stable selection is requested final26f0 generation')
        dev.verify(manifest)
        approved = router.inventory(stable / 'project', router.SOURCE_FILES + router.SOURCE_DIRS)
        check(approved == manifest['source_files'], 'stable editable approved closure equals final captured source hashes')
        check(all(name in manifest['source_files'] for name in ('test/fifo_test.ml', 'asic_test/catalog_test.ml',
            'timing/dune', 'named_timing/dune', 'physical_timing/dune', 'bootstrap.sh', *router.ACCEPTANCE_FILES)),
            'final closure contains five test/timing roots, bootstrap and four authored acceptance files')
        check(all(not router.source_drift(manifest, suite) for suite in router.SUITES), 'both final stable suite inventories have no stale-source drift')
        check(manifest['apps']['client']['sha256'] == '896cee9b6546be5c5d7fcd132306a55cf33cbc43d1c25edbd7cea9c467bd7a42'
              and manifest['apps']['daemon']['sha256'] == 'ec0108fd3ae65ac8bc8113462bfc1eb4dcdcbecf6410c144fbc982113f495a38',
              'final stable generation pins exact corrected app pair')
        report['stable_manifest_sha256'] = router.sha(stable / 'manifest.json')
        report['stable_apps'] = manifest['apps']
        report['reviewed_sources'] = {n: router.sha(EXAMPLE / n) for n in protected_names[:3]}

        parts = fixture('missing-import')
        result = migrate(parts)
        check(result['installed'] == ['test'] and hashes(parts[2] / 'test') == hashes(parts[1] / 'test'),
              'missing directory import installs exact authored bytes only')

        for conflict in ('empty-directory', 'existing-symlink'):
            parts = fixture(conflict)
            target = parts[2] / 'test'
            if conflict == 'empty-directory':
                target.mkdir()
            else:
                target.symlink_to(parts[1] / 'test', target_is_directory=True)
            inode = target.lstat().st_ino
            result = migrate(parts)
            check(result['installed'] == [] and target.lstat().st_ino == inode,
                  conflict + ' exists before import: no merge or replacement')
            if conflict == 'existing-symlink':
                try:
                    router.inventory(parts[2], ('test',))
                except ValueError:
                    check(True, 'existing source symlink still rejected by capture inventory')
                else:
                    raise AssertionError('symlink admitted')

        original_rename = dev.rename_new
        for conflict in ('empty-directory', 'symlink'):
            parts = fixture('race-' + conflict)
            target = parts[2] / 'test'
            owner_before = hashes(parts[1])

            def raced(source, destination):
                if destination == target:
                    if conflict == 'empty-directory':
                        target.mkdir()
                    else:
                        target.symlink_to(parts[1] / 'test', target_is_directory=True)
                return original_rename(source, destination)

            try:
                with patch.object(dev, 'rename_new', raced):
                    migrate(parts)
            except FileExistsError:
                result = json.loads((parts[3] / 'source-migration-result.json').read_text())
                check(result['installed'] == [] and (parts[3] / 'source-stage/test/fifo_test.ml').exists()
                      and hashes(parts[1]) == owner_before and
                      (target.is_symlink() if conflict == 'symlink' else target.is_dir() and not list(target.iterdir())),
                      conflict + ' races publication: atomic no-replace, staged bytes/receipt retained')
            else:
                raise AssertionError('racing destination overwritten')

        parts = fixture('baseline-support', support=True)
        baseline = {n: (parts[2] / n).read_bytes() for n in dev.OWNED_SUPPORT}
        migrate(parts)
        check(all((parts[2] / n).read_bytes() == (parts[1] / n).read_bytes()
                  and (parts[3] / 'source-backup' / n).read_bytes() == baseline[n] for n in dev.OWNED_SUPPORT),
              'owned support updates only matching baselines and preserves exact old backups')

        parts = fixture('edited-support', support=True)
        (parts[2] / dev.OWNED_SUPPORT[0]).write_text('third-party source edit')
        before = hashes(parts[2])
        try:
            migrate(parts)
        except RuntimeError as error:
            check('baseline' in str(error) and hashes(parts[2]) == before, 'edited support refuses all overwrite before staging')
        else:
            raise AssertionError('edited support overwritten')

        parts = fixture('support-parent-link', support=True)
        simulation = parts[2] / 'simulation'
        simulation.rename(parts[0] / 'third-party-simulation')
        simulation.symlink_to(parts[0] / 'third-party-simulation', target_is_directory=True)
        before = hashes(parts[0] / 'third-party-simulation')
        try:
            migrate(parts)
        except RuntimeError as error:
            check('parent contains a symlink' in str(error) and hashes(parts[0] / 'third-party-simulation') == before,
                  'symlinked support parent refuses write-through')
        else:
            raise AssertionError('support parent admitted')

        # Use only A's newly prepared private store for a real failed capture after import.
        prior = json.loads((store / 'manifest.json').read_text())
        selected_bytes = (store / 'manifest.json').read_bytes()
        project = store / 'project'
        retained = evidence / 'retained-private-source'
        retained.mkdir()
        for name in dev.IMPORT_GROUPS:
            (project / name).rename(retained / name)
        source = project / 'lib/controlled_fifo.ml'
        source.write_bytes(source.read_bytes() + b'\n(* migration independent preservation check *)\n')
        source_hash = router.sha(source)
        durable = {part: hashes(store / part) for part in ('state', 'client-state')}
        prefix = [sys.executable, '-B', str(EXAMPLE / 'scripts/workbench_dev.py'), '--store', str(store), 'prepare', '--refresh']

        def failed(label, flags, expected_text):
            completed = subprocess.run(prefix + flags, capture_output=True, timeout=180)
            (evidence / (label + '.stdout')).write_bytes(completed.stdout)
            (evidence / (label + '.stderr')).write_bytes(completed.stderr)
            check(completed.returncode == 2 and expected_text in completed.stderr,
                  label + ': expected explicit refusal/failure')
            check((store / 'manifest.json').read_bytes() == selected_bytes and router.sha(source) == source_hash
                  and all(hashes(store / part) == expected for part, expected in durable.items()),
                  label + ': prior selection, existing source edit and durable bytes unchanged')

        failed('plain-refresh', [], b'import-missing-source')
        before = set((store / 'receipts').iterdir())
        failed('import-failed-build', ['--import-missing-source', '--dune', '/bin/false'], b'private source build failed')
        receipt = (set((store / 'receipts').iterdir()) - before).pop()
        migration = json.loads((receipt / 'source-migration-result.json').read_text())
        check(set(migration['installed']) == set(dev.IMPORT_GROUPS) and migration['retained_on_build_failure']
              and all((project / name).exists() for name in dev.IMPORT_GROUPS)
              and json.loads((receipt / 'failure.json').read_text())['previous'] == prior['generation'],
              'failed build retains and journals every explicitly imported addition against prior generation')
        acceptance = sorted(p.name for p in (project / 'acceptance').iterdir())
        check(acceptance == sorted(Path(n).name for n in router.ACCEPTANCE_FILES), 'acceptance import contains exactly four authored files, no results/snapshots')
        edited_test = project / 'test/fifo_test.ml'
        edited_test.write_bytes(edited_test.read_bytes() + b'\n(* user test edit retained *)\n')
        edited_hash = router.sha(edited_test)
        failed('repeat-import-failed-build', ['--import-missing-source', '--dune', '/bin/false'], b'private source build failed')
        check(router.sha(edited_test) == edited_hash, 'repeat import never replaces an existing user-edited test directory')
        report['private_migration_receipt'] = str(receipt)
        report['completed'] = True
    finally:
        report['protected'] = dict(before=protected, after={p: router.sha(p) for p in protected})
        check(report['protected']['before'] == report['protected']['after'],
              'owner source/configs, B production/tests and final stable selection unchanged')
        (evidence / 'receipt.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
