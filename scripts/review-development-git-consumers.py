#!/usr/bin/env python3
"""Private corrected capture and actual Git consumer probes; no EDA or user writes."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import traceback

HERE = Path(__file__).resolve().parent
EXAMPLE = HERE.parent.parent / 'hardcaml_asic_example'
LIVE = EXAMPLE / '.dev/workbench-development'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--store', type=Path, required=True)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--existing-private-store', action='store_true')
    parser.add_argument('--refresh-private', action='store_true')
    args = parser.parse_args()
    out, store = args.evidence.resolve(), args.store.resolve()
    assert all(p.is_relative_to(Path('/tmp/opencode')) for p in (out, store))
    assert args.existing_private_store or args.refresh_private or not store.exists()
    out.mkdir()
    live = json.loads((LIVE / 'manifest.json').read_bytes())
    report = dict(eda_launches=0, checks=[], commands=[])
    def check(ok, label):
        report['checks'].append(dict(passed=bool(ok), expectation=label))
        assert ok, label
    def run(label, argv, env, cwd=None):
        p = subprocess.run(argv, env=env, cwd=cwd, capture_output=True, timeout=1200)
        (out / (label + '.stdout')).write_bytes(p.stdout)
        (out / (label + '.stderr')).write_bytes(p.stderr)
        report['commands'].append(dict(label=label, argv=argv, returncode=p.returncode, cwd=str(cwd)))
        return p
    try:
        env = dict(os.environ, OMP_NUM_THREADS='2', OPENROAD_THREADS='2', _OPENLANE_MAX_CORES='2')
        # Deliberately contaminated inherited context: prepare must clean it itself.
        env.update(GIT_DIR=live['inputs']['git_dir'], GIT_WORK_TREE=live['project_root'],
                   GIT_COMMON_DIR=live['inputs']['git_dir'], GIT_INDEX_FILE='/nonexistent/review-index')
        result = run('private-prepare', ['opam', 'exec', '--switch=5.2.0+ox', '--', 'python3', '-B',
            str(EXAMPLE / 'scripts/workbench_dev.py'), '--store', str(store), 'prepare',
            '--sdk-prefix', str(Path(live['generation']) / 'sdk'), '--git', '/usr/bin/git',
            *(['--refresh', '--update-owned-support'] if args.refresh_private else [])], env)
        check(result.returncode == 0, 'new private capture prepares under contaminated parent environment')
        manifest = json.loads((store / 'manifest.json').read_bytes())
        check('GIT_DIR' not in manifest['environment'] and 'GIT_WORK_TREE' not in manifest['environment'],
              'captured daemon environment has no global repository selection')
        helper = Path(manifest['generation']) / 'tool-bin/git'
        project = store / 'project'
        clean = {k: v for k, v in os.environ.items() if not k.startswith('GIT_')}
        clean.update(manifest['environment'])
        dirty = dict(clean, GIT_DIR=live['inputs']['git_dir'], GIT_WORK_TREE=live['project_root'],
                     GIT_COMMON_DIR=live['inputs']['git_dir'], GIT_INDEX_FILE='/nonexistent/review-index',
                     GIT_CONFIG_COUNT='1', GIT_CONFIG_KEY_0='core.bare', GIT_CONFIG_VALUE_0='true',
                     REVIEW_NON_REPOSITORY='preserved')
        # Exact roots select source context; nested paths must not inherit it.
        for i, (cwd, tail, expected) in enumerate([
                (project, [], live['inputs']['git_dir']),
                (project, ['-C', 'lib'], None),
                (out, ['-C', str(project), '-C', 'lib', '-C', '..'], live['inputs']['git_dir']),
                (out, ['-C' + str(project), '-C', 'lib'], None),
                (out, ['-C', str(EXAMPLE / '_flow_tools/tt')], str((EXAMPLE / '_flow_tools/tt/.git').resolve())),
                (out, ['-C', str(EXAMPLE / '_flow_tools/pdk')], str((EXAMPLE / '_flow_tools/pdk/.git').resolve()))]):
            result = run(f'git-root-{i}', [str(helper), *tail, 'rev-parse', '--absolute-git-dir'], dirty, cwd)
            if expected:
                check(result.returncode == 0 and result.stdout.decode().strip() == expected,
                      f'actual Git root dispatch {i}')
            else:
                check(result.returncode != 0, f'nested source path {i} gets no enclosing fake source context')
        # Runtime consumer's exact revision/status commands, using inherited poison.
        for name, expected in [('tt', 'd66cf179e7bc4d296362ab7e2e3b344dc3c4f665'),
                               ('pdk', '2bbec755dc67ca3db0261c3d6163e15735d66710')]:
            result = run('collateral-' + name, [str(helper), '-C', str(EXAMPLE / '_flow_tools' / name), 'rev-parse', 'HEAD'], dirty)
            check(result.returncode == 0 and result.stdout.decode().strip() == expected,
                  name + ' exact consumer revision probe survives inherited selectors/config')
        discover = run('simulation-discover', manifest['provider_command'] + ['discover', '--protocol-version', '1'], dirty)
        check(discover.returncode == 0 and all(s.encode() in discover.stdout for s in ('controlled-fifo', 'pt8-memory-workloads')),
              'actual captured composite discovery contains both suites')
        # Source CLI consumers never invoke execution in these commands.
        command = [str(Path(manifest['generation']) / 'provider/project.exe'), 'flow']
        common = ['--project-root', str(project), '--source-root', str(project), '--flow', 'standard',
                  '--profile', 'balanced', '--endpoint', 'synthesis', '--json']
        plan = run('source-plan', command + ['plan', *common], dirty)
        check(plan.returncode == 0, 'actual captured project source plan under inherited poison')
        emitted = out / 'emitted'
        result = run('source-emit', command + ['emit', *common, '--results-root', str(emitted)], dirty)
        check(result.returncode == 0, 'actual captured project elaboration-only source emit under inherited poison')
        report.update(passed=True, store=str(store), generation=manifest['generation'])
    except BaseException:
        report['error'] = traceback.format_exc()
        raise
    finally:
        (out / 'receipt.json').write_text(json.dumps(report, indent=2) + '\n')
    print(out / 'receipt.json')


if __name__ == '__main__':
    main()
