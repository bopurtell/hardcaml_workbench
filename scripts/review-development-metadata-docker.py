#!/usr/bin/env python3
"""Private metadata-only Docker allocation adapter: fail closed on flow commands."""
import json
import os
from pathlib import Path
import sys

args = sys.argv[1:]
if args[:1] == ['run']:
    # Actual installed stage metadata payload is supplied inline; never a bridge.
    if '-c' not in args or args[-1] not in ('container', 'metadata-container'):
        raise SystemExit('independent review refuses non-metadata container')
    code = args[args.index('-c') + 1]
    if 'metadata_error' not in code or 'classic_inventory' not in code:
        raise SystemExit('independent review refuses unknown inline payload')
    args = ['--cpus=2' if arg.startswith('--cpus=') else
            key + '=2' if (key := arg.split('=')[0]) in
            ('OMP_NUM_THREADS', 'OPENROAD_THREADS', '_OPENLANE_MAX_CORES') else arg
            for arg in args]
    for key in ('OMP_NUM_THREADS', 'OPENROAD_THREADS', '_OPENLANE_MAX_CORES'):
        if key + '=2' not in args:
            args[1:1] = ['-e', key + '=2']
elif not (args[:1] == ['info'] or args[:2] == ['image', 'inspect'] or
          args[:1] in (['kill'], ['rm'], ['inspect'])):
    raise SystemExit('independent review refuses docker command')
receipt = Path(os.environ['REVIEW_DOCKER_LOG'])
assert receipt.resolve().is_relative_to(Path('/tmp/opencode'))
with receipt.open('a') as stream:
    stream.write(json.dumps(dict(requested=sys.argv[1:], actual=args,
                                 allocation=2, kind='metadata-only')) + '\n')
os.execv('/usr/bin/docker', ['/usr/bin/docker', *args])
