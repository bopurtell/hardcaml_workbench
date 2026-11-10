#!/usr/bin/python3
"""Disposable public-CLI fixture; all mutations stay in the test's temp root."""
import json
import pathlib
import sys
import time

root = pathlib.Path.cwd()
args = sys.argv[1:]
with (root / 'calls').open('a') as out:
    out.write(json.dumps(args) + '\n')
if args == ['--version', '--json']:
    supported = not (root / 'unsupported').exists()
    print(json.dumps({'cli_contract': {'version': 4, 'capabilities': {
        'namedflow1': True,
        'workload_inspection1': {'schema_version': 1, 'read_only': supported},
        'variant_comparison1': {'schema_version': 1, 'read_only': supported},
        'workload_comparison1': {'schema_version': 1, 'read_only': supported}}}}))
    sys.exit(0)
if (root / 'hold').exists():
    (root / 'entered').touch()
    end = time.monotonic() + 5
    while (root / 'hold').exists() and time.monotonic() < end:
        time.sleep(.005)
if (root / 'fail').exists():
    print('invalid retained evidence', file=sys.stderr)
    sys.exit(2)
if (root / 'mutate-helper').exists():
    name = 'workload-inspect' if args[0] == 'workload-inspect' else 'compare'
    with (root / ('hardcaml-asic-experimental-' + name)).open('a') as out:
        out.write('\nchanged companion\n')
if (root / 'mutate-launcher').exists():
    with pathlib.Path(__file__).open('a') as out:
        out.write('\n# changed launcher\n')
if (root / 'oversize').exists():
    sys.stdout.write(' ' * (1024 * 1024 + 1))
else:
    response = json.loads((root / 'response.json').read_text())
    if args[0] == 'workload-inspect':
        response['provenance']['sources'] = [{'path': str(pathlib.Path(args[1]).resolve())}]
    elif args[0] == 'compare':
        for side in ('left', 'right'):
            flag = '--' + side + '-workload'
            if flag in args:
                response[side]['workload']['provenance']['sources'] = [
                    {'path': str(pathlib.Path(args[args.index(flag) + 1]).resolve())}]
    sys.stdout.write(json.dumps(response))
