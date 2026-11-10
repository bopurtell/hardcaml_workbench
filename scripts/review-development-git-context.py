#!/usr/bin/env python3
"""Read-only retained failure/collateral audit; writes only fresh private receipts."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

EXAMPLE = Path('/home/wayne/devel/jane/hardcaml_asic_example')
STORE = EXAMPLE / '.dev/workbench-development'
FAILED = STORE / 'asic-results/stage-preflight/operations/20261105T231057712738Z_bab3dadb'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inventory(root):
    return {str(p.relative_to(root)): digest(p) for p in sorted(root.rglob('*')) if p.is_file()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--compare', type=Path)
    args = parser.parse_args()
    out = args.evidence.resolve()
    assert out.is_relative_to(Path('/tmp/opencode'))
    out.mkdir()
    operation = json.loads((FAILED / 'operation.json').read_bytes())
    bundle = Path(operation['bundle'])
    manifest = json.loads((bundle / 'manifest.json').read_bytes())
    selected = json.loads((STORE / 'manifest.json').read_bytes())
    protected = {str(p): digest(p) for p in EXAMPLE.glob('hardcaml-workbench-*.sexp')}
    protected.update({str(STORE / 'manifest.json'): digest(STORE / 'manifest.json')})
    for root in (FAILED, bundle, Path(selected['generation'])):
        protected.update({str(root / name): sha for name, sha in inventory(root).items()})
    report = dict(eda_launches=0, probes=[], requested_tools=manifest['requested_tools'],
                  operation=operation, protected=protected, checks=[])

    def check(ok, label):
        report['checks'].append(dict(passed=bool(ok), expectation=label))
        assert ok, label

    def probe(label, argv, env, require_success=True):
        result = subprocess.run(argv, env=env, capture_output=True, timeout=30)
        (out / (label + '.stdout')).write_bytes(result.stdout)
        (out / (label + '.stderr')).write_bytes(result.stderr)
        report['probes'].append(dict(label=label, argv=argv, returncode=result.returncode,
                                     stdout=result.stdout.decode(), stderr=result.stderr.decode()))
        if require_success:
            check(result.returncode == 0, label + ' exit')
        return result.stdout.decode().strip()

    try:
        normal = {k: v for k, v in os.environ.items() if not k.startswith('GIT_')}
        normal.update(GIT_OPTIONAL_LOCKS='0', GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null')
        contaminated = dict(normal, GIT_DIR=selected['inputs']['git_dir'], GIT_WORK_TREE=selected['project_root'])
        for key, request_key in [('support_tools', 'support_tools_revision'), ('pdk_root', 'pdk_revision')]:
            root = operation['request'][key]
            argv = ['/usr/bin/git', '-C', root, 'rev-parse', 'HEAD']
            actual = probe(key + '-normal', argv, normal)
            observed = probe(key + '-contaminated', argv, contaminated)
            check(actual == manifest['requested_tools'][request_key], key + ' actual revision matches requested_tools')
            check(observed != actual, key + ' global repository override reproduces mismatch')
        for i, ref in enumerate(manifest['target']['external_references']):
            support = ref['source'] == 'Support_tools'
            repo = Path(operation['request']['support_tools' if support else 'pdk_root'])
            root = repo if support else repo / manifest['target']['technology']
            path = root / ref['path']
            if ref.get('sha256'):
                check(digest(path) == ref['sha256'], 'external reference hash ' + str(path))
            for label, env in [('normal', normal), ('contaminated', contaminated)]:
                status = probe(f'reference-{i}-{label}', ['/usr/bin/git', '-C', str(repo), 'status', '--porcelain', '--', str(path)], env, label == 'normal')
                if label == 'normal':
                    check(status == '', f'reference {i} {label} raw status empty')
        # Copy raw historical command outputs, without rerunning the failed operation.
        report['historical_files'] = inventory(FAILED)
        for name in report['historical_files']:
            destination = out / 'historical' / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes((FAILED / name).read_bytes())
        if args.compare:
            baseline = json.loads(args.compare.read_bytes())['protected']
            check(protected == baseline, 'root configs, selected generation, failed run and bundle unchanged')
        check(all(digest(Path(p)) == sha for p, sha in protected.items()), 'protected bytes unchanged during audit')
        report['passed'] = True
    finally:
        (out / 'receipt.json').write_text(json.dumps(report, indent=2) + '\n')
    print(str(out / 'receipt.json'))


if __name__ == '__main__':
    main()
