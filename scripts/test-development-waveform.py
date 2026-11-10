#!/usr/bin/env python3
"""Independent exact-value/event-projection controls using a prebuilt native probe.

Synthetic VCDs are controls, not claims of real execution. Includes an original
tick above 2**53, max-int64 Fit, alias/pulse/X/Z semantics and event budget failure.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import traceback

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('development_wave_wire', HERE / 'test-fs2-native.py')
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)
field = native.field


def header(declarations):
    return '$timescale 1 ps $end\n$scope module top $end\n' + declarations + '$upscope $end\n$enddefinitions $end\n'


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--probe', type=Path, required=True)
    p.add_argument('--evidence', type=Path, required=True)
    args = p.parse_args()
    args.probe = args.probe.resolve(strict=True)
    args.evidence = args.evidence.resolve()
    assert args.evidence.is_relative_to(Path('/tmp/opencode'))
    args.evidence.mkdir()
    report = dict(passed=False, synthetic=True, new_simulations=0, eda=0, checks=[],
                  probe=str(args.probe), probe_sha256=hashlib.sha256(args.probe.read_bytes()).hexdigest())

    def check(ok, message):
        report['checks'].append(dict(passed=bool(ok), expectation=message))
        assert ok, message

    def probe(name, text, start, stop, times=(), views=True):
        path = args.evidence / (name + '.vcd')
        path.write_text(text)
        env = dict(os.environ)
        env.pop('WB028_VIEW', None)
        if views:
            env['WB028_VIEW'] = '1'
        argv = [str(args.probe), str(path), str(start), str(stop), *map(str, times)]
        result = subprocess.run(argv, env=env, capture_output=True, timeout=30)
        (args.evidence / (name + '.stdout')).write_bytes(result.stdout)
        (args.evidence / (name + '.stderr')).write_bytes(result.stderr)
        check(result.returncode == 0, name + ': bounded native probe exit')
        value = native.parse(result.stdout.decode())
        check(field(value, 'status') == 'ok', name + ': VCD accepted')
        return value

    try:
        declarations = '$var wire 1 ! pulse $end\n$var wire 1 ! alias $end\n$var wire 1 " unknown $end\n'
        text = header(declarations) + '#0\n0!\n0"\n#1\n1!\n#2\n0!\n#3\nx"\n#4\nz"\n#5\n0"\n#1000000\n'
        value = probe('subcell-pulse-and-xz', text, 0, 1000000, [0, 1, 2, 3, 4, 5])
        lanes = {field(lane, 'signal'): lane for lane in field(value, 'projection')}
        check(field(lanes['top.pulse'], 'transitions')[0] == '2' and
              field(lanes['top.alias'], 'transitions') == field(lanes['top.pulse'], 'transitions'),
              'even subcell pulse has dense original-event marker; alias agrees')
        check(field(lanes['top.unknown'], 'reason') == ['X/Z in window'], 'hidden X/Z excursion marks lane honestly')
        signals = {field(s, 'name'): dict(field(s, 'values')) for s in field(value, 'signals')}
        check(signals['top.pulse'] == {'0': ['0'], '1': ['1'], '2': ['0'], '3': ['0'], '4': ['0'], '5': ['0']},
              'original-tick exact samples distinguish pulse despite equal cell endpoints')
        check(signals['top.unknown']['3'] == ['x'] and signals['top.unknown']['4'] == ['z'], 'exact X and Z retained separately')
        frames = {field(f, 'name'): f for f in field(value, 'view_frames')}
        check(field(frames['fit'], 'stop') == field(frames['fit-narrow'], 'stop') == '1000000', 'narrow resize preserves inclusive Fit extent')
        ticks = 2**63 - 1
        high = 2**53 + 1
        text = header('$var wire 4 ! data $end\n') + '#0\nb0000 !\n#' + str(high) + '\nb1010 !\n#' + str(ticks) + '\nb1111 !\n'
        value = probe('high-int64', text, 0, ticks, [high - 1, high, high + 1, ticks])
        actual = dict(field(field(value, 'signals')[0], 'values'))
        check(actual == {str(high - 1): ['0000'], str(high): ['1010'], str(high + 1): ['1010'], str(ticks): ['1111']},
              'above-2**53 and max-int64 original sample ticks remain exact')
        frames = {field(f, 'name'): f for f in field(value, 'view_frames')}
        check(field(frames['fit'], 'start') == '0' and field(frames['fit'], 'stop') == str(ticks)
              and field(frames['fit-narrow'], 'stop') == str(ticks), 'full max-int64 Fit survives actual renderer and narrow resolution')
        cells = field(frames['fit'], 'cell_bounds')
        check(cells[0][0] == '0' and cells[-1][-1] == str(ticks)
              and all(int(a[-1]) + 1 == int(b[0]) for a, b in zip(cells, cells[1:])),
              'max-int64 compressed cells partition every original tick without overflow/gap')
        value = probe('one-point', header('$var wire 1 ! flag $end\n') + '#0\n1!\n', 0, 0, [0])
        check(field(value, 'bounds') == ['0', '0'] and field(field(value, 'signals')[0], 'values') == [['0', ['1']]], 'one-point trace retains exact initialized value')
        text = header('$var wire 1 ! data $end\n') + ''.join('#%d\n%d!\n' % (i, i % 2) for i in range(100002))
        value = probe('event-budget', text, 0, 100001, views=False)
        check('100000 event budget exceeded' in field(field(value, 'projection'), 'error'),
              'projection exhausts bounded original-event budget explicitly')
        check(report['probe_sha256'] == hashlib.sha256(args.probe.read_bytes()).hexdigest(), 'same native probe bytes throughout controls')
        report['passed'] = True
    except BaseException:
        report['error'] = traceback.format_exc()
        raise
    finally:
        (args.evidence / 'receipt.json').write_text(json.dumps(report, indent=2) + '\n')
    print('PASS independent waveform controls: ' + str(args.evidence), flush=True)


if __name__ == '__main__':
    main()
