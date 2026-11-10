"""Deterministic backend protocol fixture; no builds or third-party dependencies."""
import argparse
import json
import os
import re
import sys
import time


def sexp(value):
    if isinstance(value, list):
        return '(' + ' '.join(sexp(x) for x in value) + ')'
    return json.dumps(str(value), ensure_ascii=True)


def parse(text):
    tokens = iter(re.findall(r'"(?:\\.|[^"\\])*"|[()]|[^()\s]+', text))

    def item(token):
        if token == '(':
            result = []
            for token in tokens:
                if token == ')':
                    return result
                result.append(item(token))
            raise ValueError('truncated')
        return json.loads(token) if token.startswith('"') else token

    return item(next(tokens))


parser = argparse.ArgumentParser()
parser.add_argument('operation')
parser.add_argument('--protocol-version')
parser.add_argument('--request')
parser.add_argument('--events')
parser.add_argument('--artifact-dir')
args = parser.parse_args()
if args.operation == 'discover':
    if os.path.exists('discovery-mode'):
        value = open('discovery-mode').read()
        if value == 'bad':
            print('broken')
            sys.exit(0)
        if value == 'version':
            print('((protocol_version 2)(suites ()))')
            sys.exit(0)
    print('((protocol_version 1)(suites (((id demo)(label Demo)'
          '(cases (((id one)(label One))((id two)(label Two))))'
          '(parameters (((key mode)(label Mode)(default pass)(choices ()))))'
          '(default_seed 42)))))')
    sys.exit(0)

request = dict(parse(open(args.request).read()))
selection = dict(request['selection'])
mode = dict(selection['parameters'])['mode']
sequence = 0
events = open(args.events, 'a')


def emit(payload):
    global sequence
    event = [['protocol_version', 1], ['attempt_id', request['attempt_id']],
             ['sequence', sequence], ['payload', payload]]
    events.write(sexp(event) + '\n')
    events.flush()
    sequence += 1


print('human stdout: Passed does not mean success', flush=True)
print('human stderr', file=sys.stderr, flush=True)
emit('Started')
if mode == 'oversized':
    events.write('x' * 16384)
    events.flush()
    time.sleep(30)
if mode == 'stream-overflow':
    events.write('x' * (16 * 1024 * 1024 + 1))
    events.flush()
    time.sleep(30)
for case in selection['cases']:
    emit(['Case_started', case])
    emit(['Progress', [['case_id', [case]], ['completed', 1],
                       ['total', []], ['unit_', 'cycles']]])
    if mode == 'hang':
        time.sleep(30)
    if mode == 'bad':
        events.write('invalid\n')
        events.flush()
        time.sleep(30)
    if mode == 'gap':
        sequence += 1
    path = os.path.join(args.artifact_dir, case + '.vcd')
    if mode == 'symlink':
        os.symlink('/etc/hosts', path)
    else:
        with open(path, 'wb') as artifact:
            artifact.write(b'\x00\xff\r\nVCD\x80')
    emit(['Artifact', [['id', 'wave-' + case], ['case_id', [case]],
                       ['label', 'Trace'], ['kind', 'waveform'],
                       ['media_type', 'application/octet-stream'],
                       ['path', case + '.vcd']]])
    emit(['Case_finished', [['case_id', case],
                           ['status', 'Failed' if mode == 'fail' else 'Passed'],
                           ['message', ['failure detail'] if mode == 'fail' else []]]])
emit(['Finished', 'Failed' if mode == 'fail' else 'Passed'])
if mode == 'post-finish-hang':
    time.sleep(30)
if mode == 'duplicate':
    emit(['Finished', 'Passed'])
if mode == 'truncated':
    events.write('((protocol_version 1)')
events.close()
sys.exit(7 if mode == 'nonzero' else 0)
