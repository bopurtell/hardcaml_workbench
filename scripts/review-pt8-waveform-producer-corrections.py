#!/usr/bin/env python3
"""Independent corrected-current-source recheck using unchanged real session02 bytes.

No hardware execution, builds, original probe edits, or old-provider relabelling.
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
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--example', type=Path, default=WB.parent / 'hardcaml_asic_example')
    p.add_argument('--original-evidence', type=Path, default=Path('/tmp/opencode/pt8-producer-review-y6yxh4gt'))
    p.add_argument('--probe', type=Path, default=WB / '_build_pt8_workbench/default/terminal/waveform_probe.exe')
    args = p.parse_args()
    example = args.example.resolve()
    session = example / '.dev/asic-pt8-workbench/session-waveforms-02'
    corrected_session = example / '.dev/asic-pt8-workbench/session-waveforms-final-01'
    sys.path.insert(0, str(example / 'scripts'))
    import pt8_workloads as producer
    import pt8_workbench_provider as provider

    evidence = Path(tempfile.mkdtemp(prefix='pt8-producer-correction-review-', dir='/tmp/opencode'))
    print('Evidence: ' + str(evidence), flush=True)
    protected = set()
    for tree in (args.original_evidence, session / 'provider'):
        protected.update(path for path in tree.rglob('*') if path.is_file())
    protected.add(WB / 'scripts/review-pt8-waveform-producer.py')
    source_names = ('pt8_workloads.py', 'pt8_workbench_runner.py', 'pt8_workbench_provider.py', 'test_pt8_waveforms.py')
    protected.update(example / 'scripts' / name for name in source_names)
    direct = session / 'waveform-direct-84166e76c12147508792f756556fea1c'
    receipt = json.loads((direct / 'assertions.json').read_text())
    protected.update(path for path in direct.rglob('*') if path.is_file())
    for case in receipt['results'].values():
        protected.update(path for path in Path(case['result']).parent.rglob('*') if path.is_file())
    if corrected_session.is_dir():
        protected.update(path for path in (corrected_session / 'provider').rglob('*') if path.is_file())
        protected.add(corrected_session / 'manifest.json')
    before = {str(path): sha(path) for path in protected}
    report = dict(checks=[], findings=[], sources={}, evidence=str(evidence), new_simulations=0,
                  production_edits=0, original_probe=str(WB / 'scripts/review-pt8-waveform-producer.py'))

    def check(ok, label):
        report['checks'].append(dict(passed=bool(ok), label=label))
        if not ok:
            report['findings'].append(label)
            print('FINDING ' + label, flush=True)

    def native(path, label, times=()):
        command = [str(args.probe.resolve()), str(path), '2595000', '2595010', *map(str, times)]
        result = subprocess.run(command, capture_output=True, timeout=30, check=True)
        (evidence / (label + '.native.sexp')).write_bytes(result.stdout)
        (evidence / (label + '.native.stderr')).write_bytes(result.stderr)
        return dict(provider.parse(result.stdout.decode()))

    try:
        original_command = [sys.executable, '-B', str(WB / 'scripts/review-pt8-waveform-producer.py'),
                            '--example', str(example)]
        original = subprocess.run(original_command, cwd=WB, capture_output=True, timeout=120)
        (evidence / 'original-probe.stdout').write_bytes(original.stdout)
        (evidence / 'original-probe.stderr').write_bytes(original.stderr)
        report['original_invocation'] = dict(argv=original_command, exit_code=original.returncode,
            disposition='old session02 source-identity guard; not a corrected-provider acceptance run')
        check(original.returncode != 0 and b'current equals immutable session02 capture' in original.stderr,
              'unchanged original probe stops on expected current-vs-session02 source identity difference')
        check(Path(producer.__file__).resolve() == example / 'scripts/pt8_workloads.py', 'validator is current example source')
        check(Path(provider.__file__).resolve() == example / 'scripts/pt8_workbench_provider.py', 'publication is current example source')
        check(provider.validate_waveform is producer.validate_waveform, 'provider uses corrected current validator')
        for name in source_names:
            current = example / 'scripts' / name
            old = session / 'provider/scripts' / name
            report['sources'][name] = dict(current=sha(current), old_session02=sha(old) if old.exists() else None)
            final = corrected_session / 'provider/scripts' / name
            if final.is_file():
                report['sources'][name]['corrected_final_capture'] = sha(final)
                check(sha(current) == sha(final), name + ': current equals corrected final capture')
        check(sha(example / 'scripts/pt8_workloads.py') != sha(session / 'provider/scripts/pt8_workloads.py'),
              'old session02 validator remains distinct; never relabelled corrected')
        check(sha(example / 'scripts/pt8_workbench_provider.py') != sha(session / 'provider/scripts/pt8_workbench_provider.py'),
              'old session02 publisher remains distinct; never relabelled corrected')

        raw = None
        descriptors = {}
        times = [n * 10000 + phase for n in range(1307) for phase in (4000, 9000)]
        for case, policy in (('flops256', 'flops'), ('exact256', 'exact')):
            directory = Path(receipt['results'][case]['result']).parent
            wave = directory / 'waveform.vcd'
            data = wave.read_bytes()
            raw = data if raw is None else raw
            descriptor = producer.validate_waveform(wave, 1307)
            descriptors[case] = descriptor
            check(descriptor == json.loads((directory / 'waveform.json').read_text()) == receipt['results'][case]['waveform'],
                  case + ': corrected validator exactly preserves original descriptor')
            check(data == Path(receipt['results'][case]['copied']).read_bytes(), case + ': original publication bytes unchanged')
            parsed = native(wave, case + '-real-all-samples', times)
            check(parsed['status'] == 'ok', case + ': same real VCD parses with current production viewer')
            signals = {dict(s)['name'].split('[')[0]: dict(s) for s in parsed['signals']}
            check({name: int(s['width']) for name, s in signals.items()} ==
                  {'tb.' + name: width for name, width in descriptor['signals'].items()}, case + ': six real interface signals')
            values = {name: {int(t): v[0] if v else None for t, v in s['values']} for name, s in signals.items()}
            ops = producer.workload()['operations']
            rows = [line.split() for line in (directory / 'execute/stdout.log').read_text().splitlines() if line.startswith('TRACE ')]
            samples, unknowns, mismatches = 0, 0, []
            for n, (_, cycle, before_q, after_q) in enumerate(rows):
                if int(cycle) != n:
                    mismatches.append(('cycle', n, cycle))
                for phase, word in ((4000, before_q), (9000, after_q)):
                    tick = n * 10000 + phase
                    wanted = dict(clk=int(phase == 9000), ena=int(ops[n]['enable']), rst_n=int(not ops[n]['write']),
                                  ui_in=ops[n]['address'], uio_in=ops[n]['data'] & 255)
                    wanted = {name: format(value, '0%db' % descriptor['signals'][name]) for name, value in wanted.items()}
                    wanted['q'] = ''.join(c * 4 if c in 'xz' else format(int(c, 16), '04b') for c in word.lower()).zfill(16)
                    for name, value in wanted.items():
                        if values['tb.' + name][tick] != value:
                            mismatches.append((n, phase, name))
                        samples += 1
                    unknowns += int('x' in wanted['q'] or 'z' in wanted['q'])
            check(not mismatches and samples == 15684 and unknowns == 519,
                  case + ': 15684 same-execution control/response samples match, 519 unknown responses preserved')
            check(producer.parse_trace(directory / 'execute/stdout.log', ops) == json.loads(
                (example / 'acceptance/pt8-workloads/simulation-04' / policy / 'trace.json').read_text()),
                case + ': functional trace still equals unchanged historical execution')
        report['real_descriptors'] = descriptors

        old = example / '.dev/asic-pt8-workbench/session-final-review-01/provider/scripts/pt8_workloads.py'
        function = next(n for n in ast.parse(old.read_text()).body if isinstance(n, ast.FunctionDef) and n.name == 'bench')
        namespace = {}
        exec(compile(ast.Module(body=[function], type_ignores=[]), str(old), 'exec'), namespace)
        for ignored in (False, True):
            check(producer.bench(ops, ignored) == namespace['bench'](ops, ignored), 'historical default bench exact, ignored=' + str(ignored))

        fixtures = evidence / 'fixtures'
        fixtures.mkdir()
        mutations = {
            'unsupported-real-type': raw.replace(b'$var reg 1 ! clk', b'$var real 1 ! clk', 1),
            'missing-upscope': raw.replace(b'$upscope $end\n', b'', 1),
            'scalar-bus': raw.replace(b'bx &', b'x&', 1),
            'bad-range': raw.replace(b'[7:0]', b'[999:0]', 1),
            'unknown-header-directive': raw.replace(b'$enddefinitions', b'$unknown bad $end\n$enddefinitions', 1),
            'plain-header-garbage': raw.replace(b'$enddefinitions', b'IGNORED LINE\n$enddefinitions', 1),
            'malformed-extra-declaration': raw.replace(b'$enddefinitions', b'$var nonsense $end\n$enddefinitions', 1),
            'duplicate-code': raw.replace(b'1 " ena', b'1 ! ena', 1),
            'duplicate-name': raw.replace(b'1 " ena', b'1 " clk', 1),
            'extra-upscope': raw.replace(b'$enddefinitions', b'$upscope $end\n$enddefinitions', 1),
            'nested-scope': raw.replace(b'$var reg 1 ! clk', b'$scope module tb $end\n$var reg 1 ! clk', 1),
            'wrong-scope': raw.replace(b'$scope module tb', b'$scope module vendor', 1),
            'duplicate-timescale': raw.replace(b'$enddefinitions', b'$timescale 1ps $end\n$enddefinitions', 1),
            'wrong-timescale': raw.replace(b'\t1ps', b'\t10ps', 1),
            'unclosed-dump': raw + b'\n$dumpvars\n',
            'nested-dump': raw.replace(b'$dumpvars', b'$dumpvars $dumpall', 1),
            'unexpected-end': raw + b'\n$end\n',
            'unknown-body-directive': raw + b'\n$ignored 0! $end\n',
            'metadata-in-body': raw + b'\n$version ignored $end\n',
            'timestamp-in-dump': raw.replace(b'$dumpvars', b'$dumpvars #0', 1),
            'plain-body-prefix': raw.replace(b'#0\n$dumpvars', b'IGNORED LINE\n#0\n$dumpvars', 1),
            'plain-body-middle': raw.replace(b'#5000', b'IGNORED LINE\n#5000', 1),
            'plain-body-suffix': raw + b'\nIGNORED LINE\n',
            'trailing-after-assignment': raw + b'\n0! junk\n',
            'trailing-after-timestamp': raw + b'\n#13070000 junk\n',
            'unterminated-header-comment': raw.split(b'$enddefinitions $end', 1)[0] + b'$comment no end\n',
            'unterminated-body-comment': raw + b'\n$comment no end\n',
            'negative-time': raw + b'\n#-1\n',
            'timestamp-garbage': raw + b'\n#13070000xyz\n',
            'undeclared-code': raw + b'\n1UNKNOWN\n',
            'overwidth-vector': raw + b'\nb111111111 $\n',
            'missing-vector-code': raw + b'\nb1\n',
            'nul': raw + b'\n\x00\n',
            'vertical-tab': raw + b'\n0!\x0b1!\n',
        }
        rejects = {}
        for label, data in mutations.items():
            check(data != raw, label + ': mutation applies')
            path = fixtures / (label + '.vcd')
            path.write_bytes(data)
            try:
                producer.validate_waveform(path, 1307)
                error = None
            except (ValueError, OSError) as e:
                error = str(e)
            rejects[label] = error
            check(error is not None, label + ': corrected validator rejects complete malformed stream')
            if label in ('unsupported-real-type', 'missing-upscope', 'scalar-bus', 'bad-range'):
                original = args.original_evidence / 'fixtures' / (label + '.vcd')
                check(original.read_bytes() == data, label + ': identical original review repro bytes')
                check(native(path, label)['status'] == 'error', label + ': native parser still rejects')
        report['rejections'] = rejects

        good_path = fixtures / 'good.vcd'
        good_path.write_bytes(raw)
        original_descriptor = producer.validate_waveform(good_path, 1307)

        def publish(label, cases):
            root = evidence / label
            root.mkdir()
            outputs = []
            for case, mode, passed in cases:
                output = root / case
                policy = provider.CASES[case]
                directory = output / policy
                directory.mkdir(parents=True)
                wave = directory / 'waveform.vcd'
                wave.write_bytes(mutations.get(mode, raw))
                descriptor = dict(original_descriptor, source=producer.ref(directory, wave))
                descriptor['source']['path'] = 'waveform.vcd'
                (directory / 'waveform.json').write_text(json.dumps(descriptor))
                reference = dict(contract='hardcaml-workbench.pt8-result-reference', schema_version=1,
                                 result='/retained-review/' + case + '/result.json', source_digest='a' * 64)
                (output / 'result-reference.json').write_text(json.dumps(reference))
                if mode == 'no-wave':
                    wave.unlink()
                    (directory / 'waveform.json').unlink()
                outputs.append((output, reference, passed))
            request = root / 'request.sexp'
            request.write_text(provider.sexp([('protocol_version', 1), ('attempt_id', 'review-' + label), ('selection', [
                ('suite', provider.SUITE), ('cases', [case for case, _, _ in cases]), ('seed', '34097'),
                ('parameters', []), ('asic_inputs', [])])]))
            args = SimpleNamespace(request=request, artifact_dir=root / 'artifacts', events=root / 'events.sexp',
                                   generation=root, emitter=root, model_root=root, producer_root=root)
            with patch.object(provider, 'Runner') as mocked, contextlib.redirect_stderr(io.StringIO()):
                mocked.return_value.run.side_effect = outputs
                code = provider.run(args)
            envelopes = [dict(provider.parse(line)) for line in args.events.read_text().splitlines()]
            check([int(e['sequence']) for e in envelopes] == list(range(len(envelopes))), label + ': exact event sequence')
            check(all(e['attempt_id'] == 'review-' + label for e in envelopes), label + ': exact attempt binding')
            events = [e['payload'] for e in envelopes]
            artifacts = [dict(e[1]) for e in events if isinstance(e, list) and e[0] == 'Artifact']
            waves = [a for a in artifacts if a['kind'] == 'trace']
            for case, _, _ in cases:
                reference_file = args.artifact_dir / (case + '-result-reference.json')
                check(reference_file.read_bytes() == (root / case / 'result-reference.json').read_bytes(),
                      label + ': JSON reference bytes retained independently for ' + case)
            return root, code, events, artifacts, waves

        for label in ('unsupported-real-type', 'missing-upscope', 'scalar-bus', 'bad-range'):
            root, code, events, artifacts, waves = publish('reject-' + label, [('flops256', label, True)])
            check(not waves and not (root / 'artifacts/flops256-waveform.vcd').exists(), label + ': no waveform publication/file')
            check([a['kind'] for a in artifacts] == ['json'] and events[-1] == ['Finished', 'Failed'],
                  label + ': rehashed malformed input leaves independent JSON and Failed status')
            case_event = next(dict(e[1]) for e in events if isinstance(e, list) and e[0] == 'Case_finished')
            check(case_event['message'] == [rejects[label]], label + ': syntax error, not stale digest, causes provider rejection')

        for mode in ('good', 'no-wave', 'unsupported-real-type'):
            root, code, events, artifacts, waves = publish('inspection-failed-' + mode, [('flops256', mode, False)])
            check(code == 0 and not waves and not (root / 'artifacts/flops256-waveform.vcd').exists(),
                  mode + ': passedFalse never copies/announces waveform')
            check([a['kind'] for a in artifacts] == ['json'] and events[-1] == ['Finished', 'Failed'],
                  mode + ': passedFalse retains JSON and finishes Failed')
            case_event = next(dict(e[1]) for e in events if isinstance(e, list) and e[0] == 'Case_finished')
            check(case_event['status'] == 'Failed' and case_event['message'] == ['functional failure; inspect retained result'],
                  mode + ': failed inspection is distinct from VCD validation failure')
        root, code, events, artifacts, waves = publish('good-positive', [('flops256', 'good', True)])
        check(code == 0 and len(waves) == 1 and events[-1] == ['Finished', 'Passed'], 'positive corrected publisher still emits valid VCD')
        root, code, events, artifacts, waves = publish('preceding-pass-next-fail', [
            ('flops256', 'good', True), ('exact256', 'good', False)])
        check([a['id'] for a in waves] == ['flops256-waveform'] and len(artifacts) == 3 and events[-1] == ['Finished', 'Failed'],
              'preceding successful case keeps its VCD; failed case keeps only its independent JSON')
        report['status'] = 'findings' if report['findings'] else 'passed'
    finally:
        after = {str(path): sha(path) for path in protected}
        report['preserved'] = before == after
        report['protected_files'] = len(before)
        (evidence / 'preservation-before.json').write_text(json.dumps(before, indent=2) + '\n')
        (evidence / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
        assert before == after, 'original source/provider/evidence changed during review'
    print(json.dumps(dict(status=report['status'], checks=len(report['checks']), findings=report['findings'],
                          preserved=report['preserved'])), flush=True)
    return int(bool(report['findings']))


if __name__ == '__main__':
    sys.exit(main())
