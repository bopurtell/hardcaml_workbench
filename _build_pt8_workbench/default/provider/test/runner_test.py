"""Foreground runner/process tests; no daemon, simulator, or shell dependency."""
import pathlib
import subprocess
import sys
import tempfile

exe = str(pathlib.Path(sys.argv[1]).resolve())
discovery = subprocess.run([exe, 'discover', '--protocol-version', '1'], capture_output=True)
assert discovery.returncode == 0 and discovery.stdout.endswith(b'\n'), discovery
assert len(discovery.stdout.splitlines()) == 1

def request(mode='good', cases='first second', seed='18446744073709551615', params=None, asic='()'):
    if params is None:
        params = f'((mode {mode}))'
    return (f'((protocol_version 1)(attempt_id attempt)(selection '
            f'((suite suite)(cases ({cases}))(seed {seed})(parameters {params})(asic_inputs {asic}))))')

with tempfile.TemporaryDirectory(prefix='provider-runner-') as tmp:
    root = pathlib.Path(tmp)
    req, events = root / 'request', root / 'events'
    artifacts = root / 'artifacts'
    artifacts.mkdir()
    argv = [exe, 'run', '--protocol-version', '1', '--request', str(req), '--events', str(events), '--artifact-dir', str(artifacts)]

    def invoke(text, success=False, no_events=False):
        req.write_text(text)
        events.write_bytes(b'')
        result = subprocess.run(argv, capture_output=True)
        assert (result.returncode == 0) == success, (text, result)
        data = events.read_bytes()
        if success:
            assert not result.stderr, result.stderr
            assert data.endswith(b'\n') and b'(sequence 0)' in data
            assert b'(payload Started)' in data and b'(payload(Finished ' in data
            assert b'\r' not in data and not any(not line for line in data.splitlines())
        else:
            assert result.stderr, result
        if no_events:
            assert not data, data
        return result, data

    for mode in ['good', 'failed', 'unknown-total', 'child', 'flush']:
        result, data = invoke(request(mode), success=True)
        if mode == 'child':
            assert result.stdout == 'child λ\n'.encode()
    # Standalone adapters must see caller order in BOTH callbacks and emit cases
    # in that order. Exercise independently reversed case and parameter lists.
    for cases in ['first second', 'second first']:
        for params, keys in [('((alpha a)(zeta z))', 'alpha,zeta'),
                             ('((zeta z)(alpha a))', 'zeta,alpha')]:
            text = request(cases=cases, params=params).replace('(suite suite)', '(suite ordered)')
            result, data = invoke(text, success=True)
            order = f'{cases.replace(" ", ",")};{keys}\n'
            assert result.stdout == ('validate: ' + order + 'run: ' + order).encode(), result.stdout
            started = [line for line in data.splitlines() if b'(Case_started ' in line]
            assert len(started) == 2, started
            for line, case in zip(started, cases.split()):
                assert f'(Case_started {case})'.encode() in line, started
    # Preserving order must not bypass generic validation or reach project callbacks.
    invalid_ordered = request(cases='second second', params='((zeta z)(alpha a))').replace(
        '(suite suite)', '(suite ordered)')
    result, _ = invoke(invalid_ordered, no_events=True)
    assert not result.stdout, result.stdout
    for text in [request(cases='unknown'), request(cases='first first'), request(cases=''),
                 request(seed='01'), request(seed='-1'), request(seed='18446744073709551616'),
                 request(params='()'), request(params='((mode good)(extra x))'),
                 request(params='((mode good)(mode good))'), request('domain-error'),
                 request().replace('(suite suite)', '(suite absent)'),
                 request().replace('(attempt_id attempt)', '(attempt_id "bad id")'),
                 request().replace('(protocol_version 1)', '(protocol_version 2)'),
                 request().replace('(attempt_id attempt)', '(unknown x)(attempt_id attempt)'),
                 request().replace('(attempt_id attempt)', '(attempt_id attempt)(attempt_id duplicate)'),
                 request() + ' trailing', '', '(' * (1024 * 1024 + 1),
                 request(asic='((((run ((backend asic)(id r)(build ())(label ())))(attempt a)(artifact_id b)(sha256 ' + 'a'*64 + '))))')]:
        invoke(text, no_events=True)
    for mode in ['duplicate-start', 'unselected', 'finish-early', 'regress', 'change-total',
                 'oversized', 'missing-finish', 'post-finish', 'exception', 'child-error', 'swallowed',
                 'artifact-limit', 'duplicate-artifact', 'artifact-path', 'event-count', 'stream-limit']:
        invoke(request(mode))
    for argv_bad in [[exe], [exe, 'discover', '--protocol-version', '2'], argv + ['extra']]:
        result = subprocess.run(argv_bad, capture_output=True)
        assert result.returncode != 0 and result.stderr
print('runner conformance: passed')
