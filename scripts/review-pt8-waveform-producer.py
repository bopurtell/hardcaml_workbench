#!/usr/bin/env python3
"""Independent C-producer review. Read retained runs; mutate private copies only.

No simulator, daemon, EDA, Dune, or original acceptance script is invoked.
Exit 1 means reproduced contract findings; assertions mean a broken review control.
"""
import argparse
import ast
import contextlib
import hashlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
from unittest.mock import patch

sys.dont_write_bytecode = True
WB = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--example', type=Path, default=WB.parent / 'hardcaml_asic_example')
    parser.add_argument('--session', default='session-waveforms-02')
    parser.add_argument('--probe', type=Path, default=WB / '_build_pt8_workbench/default/terminal/waveform_probe.exe')
    args = parser.parse_args()
    example = args.example.resolve()
    session = example / '.dev/asic-pt8-workbench' / args.session
    sys.path.insert(0, str(example / 'scripts'))
    import pt8_workloads as producer
    import pt8_workbench_provider as provider
    import pt8_workbench_runner as runner

    evidence = Path(tempfile.mkdtemp(prefix='pt8-producer-review-', dir='/tmp/opencode'))
    print('Evidence: ' + str(evidence), flush=True)
    report = dict(checks=[], findings=[], observations=[], sources={}, evidence=str(evidence),
                  new_simulations=0, eda=0)

    def check(ok, label):
        report['checks'].append(dict(passed=bool(ok), label=label))
        assert ok, label

    def finding(name, label, **data):
        report['findings'].append(dict(id=name, label=label, **data))
        print('FINDING ' + name + ': ' + label, flush=True)

    def observe(name, **data):
        report['observations'].append(dict(name=name, **data))

    protected = set()
    baseline = Path('/tmp/opencode/pt8-waveform-preservation-01.json')
    if baseline.is_file():
        protected.update(Path(p) for p in json.loads(baseline.read_text()))
    protected.update(p for p in session.rglob('*') if p.is_file())
    for name in ('pt8_workloads.py', 'pt8_workbench_runner.py', 'pt8_workbench_provider.py',
                 'test_pt8_waveforms.py'):
        path = example / 'scripts' / name
        protected.add(path)
        report['sources'][str(path)] = sha(path)
        captured = session / 'provider/scripts' / name
        expected = (sha(captured) if captured.is_file() else
                    json.loads((session / 'manifest.json').read_text())['source_snapshot']['scripts/' + name])
        if name == 'test_pt8_waveforms.py':
            observe('owner-tests-capture', current_sha256=sha(path), captured_sha256=expected,
                    equal=sha(path) == expected)
        else:
            check(sha(path) == expected, name + ': current equals immutable session02 capture')
    before = {str(p): sha(p) for p in protected}

    def native(path, label, times=()):
        argv = [str(args.probe.resolve()), str(path), '2595000', '2595010', *map(str, times)]
        result = subprocess.run(argv, capture_output=True, timeout=30, check=True)
        (evidence / (label + '.native.sexp')).write_bytes(result.stdout)
        (evidence / (label + '.native.stderr')).write_bytes(result.stderr)
        return dict(provider.parse(result.stdout.decode()))

    try:
        direct = session / 'waveform-direct-84166e76c12147508792f756556fea1c'
        receipt = json.loads((direct / 'assertions.json').read_text())
        real_bytes = None
        times = [n * 10000 + phase for n in range(1307) for phase in (4000, 9000)]
        for case, policy in (('flops256', 'flops'), ('exact256', 'exact')):
            result = Path(receipt['results'][case]['result'])
            directory = result.parent
            wave = directory / 'waveform.vcd'
            raw = wave.read_bytes()
            real_bytes = raw if real_bytes is None else real_bytes
            descriptor = producer.validate_waveform(wave, 1307)
            check(descriptor == json.loads((directory / 'waveform.json').read_text()), case + ': descriptor independently recomputed')
            check(descriptor == receipt['results'][case]['waveform'], case + ': original receipt identity')
            check(sha(wave) == hashlib.sha256(raw).hexdigest() and len(raw) == 64078,
                  case + ': byte count/hash')
            check(raw == Path(receipt['results'][case]['copied']).read_bytes(), case + ': FS2 published copy identical')
            parsed = native(wave, case + '-all-samples', times)
            check(parsed['status'] == 'ok', case + ': production embedded parser admits retained real VCD')
            signals = {dict(s)['name'].split('[')[0]: dict(s) for s in parsed['signals']}
            expected_widths = dict(clk=1, ena=1, rst_n=1, ui_in=8, uio_in=8, q=16)
            check({k: int(v['width']) for k, v in signals.items()} ==
                  {'tb.' + k: v for k, v in expected_widths.items()}, case + ': six exact interface signals/widths')
            values = {name: {int(t): v[0] if v else None for t, v in s['values']}
                      for name, s in signals.items()}
            workload = json.loads((directory.parent / 'workload.json').read_text())
            rows = [line.split() for line in (directory / 'execute/stdout.log').read_text().splitlines()
                    if line.startswith('TRACE ')]
            check(len(rows) == 1307, case + ': same-execution raw driver output has 1307 rows')

            def bits(hex_value):
                return ''.join(c * 4 if c in 'xz' else format(int(c, 16), '04b')
                               for c in hex_value.lower()).zfill(16)

            unknowns = samples = 0
            for n, (tag, cycle, prior, response) in enumerate(rows):
                check(int(cycle) == n, case + ': raw driver cycle ' + cycle)
                op = workload['operations'][n]
                for phase, word in ((4000, prior), (9000, response)):
                    t = n * 10000 + phase
                    wanted = dict(clk=int(phase == 9000), ena=int(op['enable']),
                                  rst_n=int(not op['write']), ui_in=op['address'], uio_in=op['data'] & 255)
                    for name, value in wanted.items():
                        actual = values['tb.' + name][t]
                        assert actual == format(value, '0%db' % expected_widths[name]), (case, n, phase, name, actual, value)
                        samples += 1
                    actual = values['tb.q'][t]
                    assert actual == bits(word), (case, n, phase, actual, word)
                    unknowns += int('x' in actual or 'z' in actual)
                    samples += 1
            check(samples == 15684 and unknowns > 0, case + ': all 15684 VCD control/response samples match same-execution raw driver; unknowns retained')
            check(workload['operations'] == producer.workload()['operations'], case + ': current directed functional stimulus unchanged')
            counters = json.loads(result.read_text())['counters']
            check(counters == dict(cycles=1307, reads=525, writes=262, operations=787,
                                  defined_observations=2083, read_latency=1), case + ': functional counters unchanged')
            expanded = sum(int(s['width']) * int(s['history_length']) for s in signals.values())
            check(expanded <= 64 * 1024 * 1024 and int(parsed['changes']) == 6028,
                  case + ': native signal/event/expanded-value bounds')
            trace = producer.parse_trace(directory / 'execute/stdout.log', workload['operations'])
            historical = example / 'acceptance/pt8-workloads/simulation-04' / policy / 'trace.json'
            check(trace == json.loads((directory / 'trace.json').read_text()) == json.loads(historical.read_text()),
                  case + ': current raw functional trace unchanged from historical simulation-04')
            command = json.loads((directory / 'execute/command.json').read_text())
            check(command['cwd'] == str(directory) and command['exit_code'] == 0 and
                  Path(command['argv'][1]).parent == directory, case + ': actual vvp cwd is private case directory')
            observe(case, descriptor=descriptor, checked_samples=samples, unknown_q_samples=unknowns,
                    expanded_value_bytes=expanded)

        def original_events(label):
            return [dict(provider.parse(line))['payload'] for line in
                    (direct / label / 'events.sexp').read_text().splitlines()]

        cancelled = original_events('cancelled')
        check(cancelled[-1] == ['Finished', 'Incomplete'] and
              not any(isinstance(e, list) and e[0] == 'Artifact' for e in cancelled) and
              not list((direct / 'cancelled/artifacts').iterdir()),
              'original real cancellation has no artifact events/files')
        check(json.loads((direct / 'cancelled/command.json').read_text())['exit_code'] == 130,
              'original real cancellation exits 130')
        missing = original_events('missing-model')
        published = [dict(e[1]) for e in missing if isinstance(e, list) and e[0] == 'Artifact']
        check(missing[-1] == ['Finished', 'Failed'] and
              {e['id'] for e in published} == {'flops256-result-reference', 'flops256-waveform'},
              'original missing-model run publishes only completed preceding Flops artifacts')
        native_dir = session / 'waveform-native-16c4bda78c4042ab95e82c12879da2b3'
        native_receipt = json.loads((native_dir / 'assertions.json').read_text())
        transport = native_dir / 'transport.vcd'
        check(sha(transport) == native_receipt['waveform_sha256'] and
              transport.stat().st_size == native_receipt['waveform_bytes'],
              'original real native transport bytes/hash match receipt')
        check(native(transport, 'original-native-transport', (0, 2595000, 2595001))['status'] == 'ok',
              'original native HTTP VCD parses under current production parser')

        # Compare defaults to old pure bench, not to a replayed or newly simulated bench.
        old = example / '.dev/asic-pt8-workbench/session-final-review-01/provider/scripts/pt8_workloads.py'
        function = next(n for n in ast.parse(old.read_text()).body if isinstance(n, ast.FunctionDef) and n.name == 'bench')
        namespace = {}
        exec(compile(ast.Module(body=[function], type_ignores=[]), str(old), 'exec'), namespace)
        ops = producer.workload()['operations']
        for ignored in (False, True):
            default = producer.bench(ops, ignored)
            check(default == namespace['bench'](ops, ignored) and '$dump' not in default,
                  'historical default bench exact, ignore_workload=' + str(ignored))
            enabled = producer.bench(ops, ignored, capture_waveform=True)
            check(enabled.replace('    $dumpfile("waveform.vcd");\n'
                '    $dumpvars(0, tb.clk, tb.ena, tb.rst_n, tb.ui_in, tb.uio_in, tb.q);\n', '') == default,
                'opt-in adds only two dump statements, ignore_workload=' + str(ignored))

        fixtures = evidence / 'fixtures'
        fixtures.mkdir()
        wave = fixtures / 'waveform.vcd'
        wave.write_bytes(real_bytes)
        good = producer.validate_waveform(wave, 1307)

        def admission(label, data, rejected=True):
            path = fixtures / (label + '.vcd')
            path.write_bytes(data)
            error = None
            try:
                desc = producer.validate_waveform(path, 1307)
            except (ValueError, OSError) as e:
                desc, error = None, str(e)
            if rejected:
                check(error is not None, label + ': validator rejects')
            return path, desc, error

        for label, data in [
            ('empty', b''), ('oversize', b' ' * (8 * 1024 * 1024 + 1)),
            ('truncated', real_bytes[:1000]), ('undeclared', real_bytes + b'\nb1 UNKNOWN\n'),
            ('wrong-end-time', real_bytes.replace(b'#13070000', b'#13070001')),
            ('backwards', real_bytes + b'\n#1\n'), ('wrong-width', real_bytes.replace(b'16 & q', b'17 & q')),
        ]:
            admission(label, data)
        # Inclusive byte/event limits; no new simulated trace is claimed here.
        padding = b' ' * (8 * 1024 * 1024 - len(real_bytes))
        admission('exact-byte-budget', real_bytes + padding, rejected=False)
        check(producer.validate_waveform(fixtures / 'exact-byte-budget.vcd', 1307)['source']['bytes'] == 8 * 1024 * 1024,
              '8MiB boundary inclusive')
        added = 500000 - good['changes']
        _, budget, error = admission('exact-change-budget', real_bytes + b'\n0!\n' * added, rejected=False)
        check(error is None and budget['changes'] == 500000, '500000 changes boundary inclusive')
        admission('over-change-budget', real_bytes + b'\n0!\n' * (added + 1))
        link = fixtures / 'linked.vcd'
        link.symlink_to(wave)
        try:
            producer.validate_waveform(link, 1307)
            assert False, 'final symlink admitted'
        except ValueError:
            check(True, 'direct waveform symlink rejected')

        malformed = [
            ('unsupported-real-type', real_bytes.replace(b'$var reg 1 ! clk', b'$var real 1 ! clk')),
            ('missing-upscope', real_bytes.replace(b'$upscope $end\n', b'', 1)),
            ('scalar-bus', real_bytes.replace(b'bx &', b'x&', 1)),
            ('bad-range', real_bytes.replace(b'[7:0]', b'[999:0]', 1)),
        ]
        for label, data in malformed:
            path, descriptor, error = admission(label, data, rejected=False)
            parsed = native(path, label)
            observe(label, producer_accepted=error is None, native=parsed)
            if error is None and parsed['status'] == 'error':
                finding('VCD-' + label, 'producer accepts metadata/body rejected by embedded parser',
                        path=str(path), native_error=parsed['error'])

        # Deterministic publication seam: only Runner results are injected. The
        # provider's validation/copy/events remain real and run on private copies.
        def publish(label, passed=True, mode=None, data=real_bytes):
            root = evidence / label
            root.mkdir()
            output = root / 'output'
            directory = output / 'flops'
            directory.mkdir(parents=True)
            source = directory / 'waveform.vcd'
            source.write_bytes(data)
            descriptor = producer.validate_waveform(source, 1307)
            (directory / 'waveform.json').write_text(json.dumps(descriptor))
            (output / 'result-reference.json').write_text('{}')
            if mode == 'descriptor':
                descriptor['source']['bytes'] += 1
                (directory / 'waveform.json').write_text(json.dumps(descriptor))
            if mode in ('descriptor-path', 'descriptor-hash', 'descriptor-cycles', 'descriptor-signals'):
                if mode == 'descriptor-path':
                    descriptor['source']['path'] = '../../outside.vcd'
                elif mode == 'descriptor-hash':
                    descriptor['source']['sha256'] = 'a' * 64
                elif mode == 'descriptor-cycles':
                    descriptor['cycles'] += 1
                else:
                    descriptor['signals']['q'] = 32
                (directory / 'waveform.json').write_text(json.dumps(descriptor))
            if mode == 'changed-before':
                source.write_bytes(data.replace(b'Icarus', b'ICARUS'))
            if mode == 'parent-symlink':
                outside = root / 'other-root'
                directory.rename(outside)
                directory.symlink_to(outside, target_is_directory=True)
            request = [('protocol_version', 1), ('attempt_id', 'review-' + label), ('selection', [
                ('suite', provider.SUITE), ('cases', ['flops256']), ('seed', '34097'),
                ('parameters', []), ('asic_inputs', [])])]
            request_path = root / 'request.sexp'
            request_path.write_text(provider.sexp(request))
            args = SimpleNamespace(request=request_path, artifact_dir=root / 'artifacts', events=root / 'events.sexp',
                                   generation=root, emitter=root, model_root=root, producer_root=root)
            original_sha = provider.sha
            mutated = []

            def digest_then_change(path):
                value = original_sha(path)
                if mode == 'after-final-check' and path.name == 'flops256-waveform.vcd':
                    # Pause at the actual final digest-return boundary. This is a
                    # deterministic model of one private-file writer, not a claim
                    # that such a writer exists during a normal immutable run.
                    path.write_bytes(b'not a VCD\n')
                    mutated.append(str(path))
                return value

            original_validate = provider.validate_waveform

            def validate_then_change(path, cycles):
                value = original_validate(path, cycles)
                if mode == 'before-copy' and path == source:
                    path.write_bytes(b'not a VCD\n')
                return value

            with patch.object(provider, 'Runner') as mocked, patch.object(provider, 'sha', digest_then_change), \
                 patch.object(provider, 'validate_waveform', validate_then_change), \
                 contextlib.redirect_stderr(io.StringIO()):
                mocked.return_value.run.return_value = (output, {}, passed)
                if mode == 'execute-failed':
                    mocked.return_value.run.side_effect = RuntimeError('vvp exit 1')
                if mode == 'cancelled':
                    mocked.return_value.run.side_effect = provider.Cancelled('review cancellation')
                code = provider.run(args)
            events = [dict(provider.parse(line))['payload'] for line in args.events.read_text().splitlines()]
            artifacts = [dict(event[1]) for event in events if isinstance(event, list) and event[0] == 'Artifact']
            waves = [a for a in artifacts if a['kind'] == 'trace']
            observation = dict(name=label, exit_code=code, terminal=events[-1], wave_artifacts=waves,
                               all_artifacts=artifacts, mutation=mutated)
            observe(label, **{k: v for k, v in observation.items() if k != 'name'})
            return waves, events

        waves, _ = publish('good-publication')
        check(len(waves) == 1, 'private positive publication control')
        for mode in ('descriptor', 'descriptor-path', 'descriptor-hash', 'descriptor-cycles',
                     'descriptor-signals', 'changed-before', 'before-copy', 'execute-failed', 'cancelled'):
            waves, _ = publish(mode, mode=mode)
            check(not waves, mode + ': no waveform publication')
        waves, events = publish('functional-failure', passed=False)
        if waves:
            finding('FAILED-PUBLISH', 'functional failure still announces waveform Artifact',
                    events=str(evidence / 'functional-failure/events.sexp'), terminal=events[-1])
        for label, data in malformed:
            waves, _ = publish('publish-' + label, data=data)
            check(len(waves) == 1, label + ': reproduces through provider publication')
        waves, _ = publish('late-copy-mutation', mode='after-final-check')
        if waves:
            observe('LATE-MUTATION', label='mutation after final digest return is announced without a further fence',
                    path=str(evidence / 'late-copy-mutation/artifacts/flops256-waveform.vcd'),
                    scope='deterministic injected private-file mutation; not observed in normal execution')
        waves, _ = publish('parent-symlink', mode='parent-symlink')
        observe('parent-symlink-admission', accepted=bool(waves), scope='private fixture parent only; no arbitrary external path used')

        # Runner root isolation: stop at emit, before any executable/simulation.
        roots = [evidence / name for name in ('runner-A', 'runner-B')]
        for root in roots:
            root.mkdir()
            (root / 'emitter').write_text('review placeholder, never executed')
        a = runner.Runner(roots[0], roots[0] / 'emitter', roots[0], root=roots[0])
        b = runner.Runner(roots[1], roots[1] / 'emitter', roots[1], root=roots[1])

        def stop_at_emit(*unused, **kwargs):
            raise RuntimeError('review stop before emitter')

        with patch.object(a, 'command', stop_at_emit):
            try:
                a.run('flops256', '34097', 'review-root')
            except RuntimeError as error:
                assert str(error) == 'review stop before emitter'
        written = list((roots[1] / '.dev/asic-pt8-workbench/workloads').glob('*/request.json'))
        observe('runner-root-mutation', a_wrote_under_b=bool(written), requests=[str(p) for p in written],
                scope='two Runner instances in one process; current provider creates one sequentially')
        check(bool(written), 'root mutation repro reaches output allocation without hardware')
        link_root = evidence / 'runner-symlink-root'
        link_root.mkdir()
        outside = evidence / 'runner-other-store'
        outside.mkdir()
        (link_root / '.dev/asic-pt8-workbench').mkdir(parents=True)
        (link_root / '.dev/asic-pt8-workbench/workloads').symlink_to(outside, target_is_directory=True)
        linked = runner.Runner(roots[0], roots[0] / 'emitter', roots[0], root=link_root)
        with patch.object(linked, 'command', stop_at_emit):
            try:
                linked.run('flops256', '34097', 'review-link')
            except RuntimeError as error:
                assert str(error) == 'review stop before emitter'
        escaped = list(outside.glob('*/request.json'))
        check(bool(escaped), 'symlinked workloads parent reproduces allocation outside configured root')
        observe('runner-parent-symlink', requests=[str(p) for p in escaped],
                scope='pre-existing private-fixture store symlink; normal setup does not install one')
        for case in ('../flops256', '/flops256'):
            try:
                provider.validate([('protocol_version', '1'), ('attempt_id', 'review'), ('selection', [
                    ('suite', provider.SUITE), ('cases', [case]), ('seed', '34097'),
                    ('parameters', []), ('asic_inputs', [])])])
                assert False, 'path-like case admitted'
            except ValueError:
                check(True, 'path-like case rejected: ' + case)
        report['status'] = 'findings' if report['findings'] else 'passed'
    finally:
        after = {str(p): sha(p) for p in protected}
        report['protected_files'] = len(before)
        report['preserved'] = before == after
        (evidence / 'preservation-before.json').write_text(json.dumps(before, indent=2) + '\n')
        (evidence / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
        assert report['preserved'], 'original source/evidence changed during review'
    print(json.dumps(dict(checks=len(report['checks']), findings=len(report['findings']),
                          preserved=report['preserved'], status=report['status'])), flush=True)
    return int(bool(report['findings']))


if __name__ == '__main__':
    sys.exit(main())
