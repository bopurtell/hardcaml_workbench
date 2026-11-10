#!/usr/bin/env python3
"""Exercise installed stage preparation only, with real bounded metadata probes."""
import argparse
import fcntl
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
FAILED = LIVE / 'asic-results/stage-preflight/operations/20261105T231057712738Z_bab3dadb'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--store', type=Path)
    args = parser.parse_args()
    out = args.evidence.resolve()
    assert out.is_relative_to(Path('/tmp/opencode'))
    out.mkdir()
    live = json.loads((LIVE / 'manifest.json').read_bytes())
    selected = json.loads(((args.store or LIVE) / 'manifest.json').read_bytes())
    request = json.loads((FAILED / 'operation.json').read_bytes())['request']
    report = dict(eda_launches=0, metadata_allocation=2, installed_stage_workers=6,
                  checks=[], commands=[], consumer='installed hardcaml_asic.execution Stage_preparation.prepare')
    def check(ok, label):
        report['checks'].append(dict(passed=bool(ok), expectation=label))
        assert ok, label
    def run(label, argv, env, timeout=180):
        p = subprocess.run(argv, capture_output=True, env=env, timeout=timeout)
        (out / (label + '.stdout')).write_bytes(p.stdout)
        (out / (label + '.stderr')).write_bytes(p.stderr)
        report['commands'].append(dict(label=label, argv=argv, returncode=p.returncode))
        return p
    try:
        fixture = out / 'consumer'
        fixture.mkdir()
        (fixture / 'dune-project').write_text('(lang dune 3.17)\n')
        (fixture / 'dune').write_text('(executable (name consumer) (libraries hardcaml_asic.execution))\n')
        shutil.copyfile(HERE.parent / 'reviewdocs/tests/git-context-stage-prepare.ml', fixture / 'consumer.ml')
        env = {k: v for k, v in os.environ.items() if not k.startswith('GIT_')}
        env.update(selected['environment'])
        env.update(OMP_NUM_THREADS='2', OPENROAD_THREADS='2', _OPENLANE_MAX_CORES='2',
                   REVIEW_DOCKER_LOG=str(out / 'docker.jsonl'))
        build = [selected['inputs']['dune'], 'build', '--root', str(fixture), '-j2', 'consumer.exe']
        with Path('/tmp/opencode/asic-pt7-build.lock').open('a+b') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            result = run('build-consumer', build, env)
        check(result.returncode == 0, 'installed library consumer builds with switch5.2.0+ox dune -j2')
        wrapper = out / 'metadata-docker'
        shutil.copyfile(HERE / 'review-development-metadata-docker.py', wrapper)
        wrapper.chmod(0o755)
        bundle = out / 'bundle'
        shutil.copytree(request['bundle'], bundle)
        check(all(hashlib.sha256(p.read_bytes()).digest() == hashlib.sha256((Path(request['bundle']) / p.relative_to(bundle)).read_bytes()).digest()
                  for p in bundle.rglob('*') if p.is_file()), 'exact preserved bundle copy')
        executable = fixture / '_build/default/consumer.exe'
        def prepare(label, source, environment, success):
            parent = out / label
            parent.mkdir()
            argv = [str(executable), str(source), request['support_tools'], request['pdk_root'],
                    request['python'], str(wrapper), 'git', request['resources'],
                    str(parent / 'workspace'), str(parent / 'stage-preflight')]
            result = run(label, argv, environment)
            check((result.returncode == 0) == success, label + ': expected exit')
            return result
        contaminated = dict(env, GIT_DIR=live['inputs']['git_dir'], GIT_WORK_TREE=live['project_root'])
        # Force actual Git for the historical reproduction even with a fixed store selected.
        contaminated['PATH'] = '/usr/bin:' + contaminated['PATH']
        failed = prepare('contaminated', bundle, contaminated, False)
        check(b'collateral revision mismatch: support_tools_revision' in failed.stderr,
              'actual installed stage consumer reproduces original failure')
        clean = {k: v for k, v in env.items() if k not in ('GIT_DIR', 'GIT_WORK_TREE')}
        if args.store:
            clean.update(GIT_DIR=live['inputs']['git_dir'], GIT_WORK_TREE=live['project_root'],
                         GIT_COMMON_DIR=live['inputs']['git_dir'], GIT_INDEX_FILE='/nonexistent/review-index')
        result = prepare('scoped' if args.store else 'normal', bundle, clean, True)
        wrong = out / 'wrong-revision-bundle'
        shutil.copytree(bundle, wrong)
        manifest = json.loads((wrong / 'manifest.json').read_bytes())
        manifest['requested_tools']['support_tools_revision'] = '0' * 40
        payload = {k: v for k, v in manifest.items() if k != 'identity'}
        manifest['identity'] = hashlib.sha256(json.dumps(payload, separators=(',', ':'), ensure_ascii=False).encode()).hexdigest()
        (wrong / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        failed = prepare('wrong-revision', wrong, clean, False)
        check(b'collateral revision mismatch: support_tools_revision' in failed.stderr,
              'correctly rehashed wrong expected revision still rejected after library identity validation')
        # Public CLI preflight is independently callable and does not execute.
        # Public `stages` has no prepare-only option, so its exact service is
        # exercised above through the installed library, never its execute tail.
        tools = out / 'tools'
        tools.mkdir()
        (tools / 'docker').symlink_to(wrapper)
        public_env = dict(clean, PATH=str(tools) + ':' + clean['PATH'])
        cli = str(Path(selected['inputs']['asic_generation']) / 'bin/hardcaml-asic-flow')
        help_result = run('public-stages-help', [cli, 'stages', '--help'], public_env)
        check(help_result.returncode == 0, 'installed public stages help inspected')
        public = run('public-preflight', [cli, 'preflight', str(bundle),
            '--support-tools', request['support_tools'], '--pdk-root', request['pdk_root'],
            '--python', request['python'], '--results-root', str(out / 'public-results'), '--json'], public_env)
        check(public.returncode == 0 and json.loads(public.stdout)['ready'],
              'actual installed public preflight metadata consumer ready')
        report['passed'] = True
    except BaseException:
        report['error'] = traceback.format_exc()
        raise
    finally:
        (out / 'receipt.json').write_text(json.dumps(report, indent=2) + '\n')
    print(out / 'receipt.json')


if __name__ == '__main__':
    main()
