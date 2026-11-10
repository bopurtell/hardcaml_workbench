#!/usr/bin/env python3
"""C adversarial renderer audit. Prebuilt C probe calls real Waveform_view only.

Findings are collected without suppressing other cases. No production edits,
simulation, daemon, EDA, Git mutation or implicit build. All outputs are private.
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
WB = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('c_wave_review_native', WB / 'scripts/test-fs2-native.py')
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)
field = native.field


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


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
    sources = ['terminal/' + name for name in ('waveform_time.ml', 'waveform_time.mli', 'waveform_data.ml',
        'waveform_data.mli', 'waveform_view.ml', 'waveform_preferences.ml', 'navigation_preferences.ml', 'main.ml')]
    sources += ['reviewdocs/tests/development_waveform_probe.ml', 'reviewdocs/tests/development-waveform-review.py']
    hashes = {name: sha(WB / name) for name in sources}
    report = dict(completed=False, findings=[], checks=[], sources=hashes,
        probe=str(args.probe), probe_sha256=sha(args.probe), new_simulations=0, eda=0,
        scope='synthetic original VCD -> native parser/input/cache -> production waves/signals rendering')

    def check(ok, label, severity='finding'):
        report['checks'].append(dict(passed=bool(ok), expectation=label))
        if not ok:
            report['findings'].append(dict(severity=severity, expectation=label))

    def run(label, text, actions):
        path = args.evidence / (label + '.vcd')
        path.write_text(text)
        command = [str(args.probe), str(path), actions]
        result = subprocess.run(command, capture_output=True, timeout=45)
        (args.evidence / (label + '.stdout')).write_bytes(result.stdout)
        (args.evidence / (label + '.stderr')).write_bytes(result.stderr)
        check(result.returncode == 0, label + ': native probe completed')
        if result.returncode:
            return {}
        frames = {field(f, 'name'): f for f in native.parse(result.stdout.decode())}
        for name, frame in frames.items():
            width, height = int(field(frame, 'width')), int(field(frame, 'height'))
            for pane in ('waves', 'signals'):
                ansi = bytes.fromhex(field(frame, pane + '_ansi'))
                (args.evidence / (label + '-' + name + '-' + pane + '.ansi')).write_bytes(ansi)
                screen = native.fs0.terminal_screen(ansi, width, height)
                (args.evidence / (label + '-' + name + '-' + pane + '.txt')).write_text(screen)
                frame.append((pane + '_text', screen))
        return frames

    def cells(frame):
        return [(int(a), int(b)) for a, b in field(frame, 'cells')]

    def partition(frame, label):
        intervals = cells(frame)
        start, stop = int(field(frame, 'start')), int(field(frame, 'stop'))
        check(intervals[0][0] == start and intervals[-1][1] == stop and
              all(start <= a <= b <= stop for a, b in intervals) and
              all(c == b + 1 or (a == b == c == d) for (a, b), (c, d) in zip(intervals, intervals[1:])),
              label + ': exact inclusive cell coverage/endpoints')

    def graph(frame):
        rows = field(frame, 'waves_text').splitlines()
        top = next(i for i, row in enumerate(rows) if '┌' in row and '┐' in row)
        left, right = rows[top].index('┌') + 1, rows[top].index('┐')
        bottom = next(i for i in range(top + 1, len(rows)) if '└' in rows[i])
        return [row[left:right] for row in rows[top + 1:bottom]]

    try:
        text = header('$var wire 1 ! pulse $end\n$var wire 1 " glitch $end\n$var wire 16 # bus $end\n$var wire 1 $ unknown $end\n')
        text += '#0\n0!\n0"\nb1100 #\n0$\n#9\n1!\n#10\n0!\n1"\n0"\n#11\nx$\n#12\nz$\n#13\n0$\n#1030\n1"\n0"\n'
        frames = run('cell-edge-glitches', text,
            '((Window 0 1030 10)(Frame full 120 32)(Window 10 1030 10)(Frame cropped 120 32))')
        f = frames['full']
        partition(f, 'cell-edge full')
        check(cells(f)[0] == (0, 9) and cells(f)[1] == (10, 19), 'control really straddles rendered cell edge')
        rows = graph(f)
        check(rows[0][:2] == '||' and rows[1][:2] == '||', 'actual pulse edges survive in each adjacent graph cell')
        check(rows[2][1] == rows[3][1] == '#' and rows[2][-1] == rows[3][-1] == '#',
              'actual graph marks equal-timestamp glitch at cell start and inclusive last tick')
        check('000C' in rows[5] and 'X/Z in window; no graph' in rows[7],
              'known bus hex stays graphed alongside separate hidden-X/Z row')
        check(dict(field(f, 'values'))['top.glitch'] == ['0'], 'same-timestamp final cursor state exact despite dense graph')
        check(graph(frames['cropped'])[0][0] == '|', 'first included transition compares value just before requested start')

        high, maximum = 2**53 + 1, 2**63 - 1
        text = header('$var wire 4 ! data $end\n') + '#0\nb0000 !\n#%d\nb1010 !\n#%d\nb1011 !\n#%d\nb1111 !\n' % (high, high + 1, maximum)
        frames = run('exact-high-cursor', text, '((Window %d %d %d)(Seek %d)(Frame exact 180 24)(Key l)(Frame plus1 180 24)(Key h)(Frame back 180 24)(Key f)(Frame fit 180 24)(Frame narrow 32 24) Reload (Frame reloaded 180 24)(Key G)(Frame last 180 24)(Seek %d)(Frame enteredlast 180 24)(Key f)(Frame refit 180 24))' % (high - 4, high + 4, high, high, maximum))
        for name, tick, bits in [('exact', high, '1010'), ('plus1', high + 1, '1011'), ('back', high, '1010'), ('last', maximum, '1111')]:
            f = frames[name]
            check(int(field(f, 'cursor')) == tick and 'Cursor %d ticks' % tick in field(f, 'waves_text')
                  and bits in field(f, 'signals_text'), name + ': original >2^53 cursor and real rendered signal value')
        for name in ('fit', 'narrow', 'reloaded', 'last'):
            partition(frames[name], 'high ' + name)
            check(field(frames[name], 'start') == '0' and field(frames[name], 'stop') == str(maximum),
                  name + ': real full max-int64 renderer keeps requested endpoints')
        check(field(frames['last'], 'cursor_location') == ['Column', str(len(cells(frames['last'])) - 1)],
              'max-int64 inclusive cursor is actual last plotted column')
        check(field(frames['enteredlast'], 'start') == field(frames['enteredlast'], 'stop') == str(maximum)
              and '1111' in field(frames['enteredlast'], 'signals_text'),
              'native timestamp editor accepts exact max-int64 entry and renders one-point endpoint window')
        check(field(frames['refit'], 'start') == '0' and field(frames['refit'], 'stop') == str(maximum),
              'Fit recovers full requested trace after exact high/max timestamp entry')

        def clock(last, rises, name='clk', extra=''):
            events = {0: ['0!']}
            for tick in rises:
                events.setdefault(tick, []).append('1!')
                events.setdefault(tick + 2, []).append('0!')
            events.setdefault(last, [])
            return header('$var wire 1 ! %s $end\n' % name + extra) + ''.join(
                '#%d\n%s\n' % (tick, '\n'.join(values)) for tick, values in sorted(events.items()))
        for label, text, inferred in [
            ('clock-normal', clock(1000, range(5, 1000, 10)), True),
            ('clock-missing', clock(1000, range(5, 1000, 10), name='activity'), False),
            ('clock-irregular', clock(1000, [5, 15, 25, 35, 46, 55]), False),
            ('clock-ambiguous', clock(1000, range(5, 1000, 10), extra='$var wire 1 " clock $end\n'), False),
            ('clock-short', clock(50, range(5, 50, 10)), True)]:
            frames = run(label, text, '((Frame default 180 24)(Key f)(Frame fit 180 24)(Frame narrow 32 24)(Key ])(Key [)(Frame panback 180 24) Reload (Frame reloaded 180 24)(Key d)(Frame defaultagain 180 24))')
            f = frames['default']
            if label != 'clock-short':
                check(('8 cycles' in field(f, 'waves_text')) == inferred, label + ': inference/fallback basis actually rendered')
            else:
                check('8-cycle target (clipped to trace)' in field(f, 'waves_text') and
                      'inferred clk period 10 ps' in field(f, 'waves_text') and
                      'extent 50 ps' in field(f, 'waves_text') and field(f, 'start') == '0' and field(f, 'stop') == '50',
                      'short clock: actual five-period extent has explicit clipped target and inferred period')
            if not inferred:
                check('no reliable clock inferred' in field(f, 'waves_text') and field(f, 'stop') == '1000',
                      label + ': no fabricated cycle basis; fallback includes whole trace')
            if label == 'clock-short':
                check(not ('8 cycles' in field(f, 'waves_text') and field(f, 'stop') == '50'),
                      'short clock: visible five-period trace must not be labelled eight cycles', severity='medium')
            check(field(frames['fit'], 'stop') == field(frames['narrow'], 'stop'), label + ': actual Fit resize preserves extent')
            for field_name in ('start', 'stop', 'span', 'cursor', 'basis'):
                check(field(frames['panback'], field_name) == field(frames['reloaded'], field_name), label + ': cache reload restores ' + field_name)
            check(field(frames['defaultagain'], 'start') == field(f, 'start') and field(frames['defaultagain'], 'stop') == field(f, 'stop'),
                  label + ': Default restores inferred/fallback extent after manual pan/reload')
            check('cycle 0' not in field(frames['fit'], 'waves_text').lower(), label + ': no synthetic renderer cycle index')

        for alias, unknown in [(True, False), (False, False), (False, True)]:
            label = 'payload-' + ('alias' if alias else 'unique') + ('-unknown' if unknown else '')
            ids = ['!'] * 4 if alias else ['!', '"', '#', '$']
            text = header(''.join('$var wire 4096 %s lane%d $end\n' % (code, i) for i, code in enumerate(ids)))
            text += ''.join('#%d\n%s\n' % (i, '\n'.join('b%s %s' % ('x' if unknown else str(i % 2), code)
                for code in sorted(set(ids)))) for i in range(1000))
            frames = run(label, text, '((Key f)(Frame full 120 32))')
            actual = field(frames['full'], 'waves_text')
            if alias:
                check('Graph unavailable' not in actual and len(graph(frames['full'])) >= 12,
                      'four wide aliases share budget and actually render their original four rows')
            else:
                check('Graph unavailable' in actual and '16 MiB value budget exceeded' in actual,
                      label + ': actual known/unknown graph rejects aggregate payload exhaustion')
                check(field(frames['full'], 'start') == '0' and field(frames['full'], 'stop') == '999',
                      label + ': budget failure retains full requested window')
        report['completed'] = True
    except BaseException:
        report['error'] = traceback.format_exc()
        raise
    finally:
        report['source_hashes_unchanged'] = all(sha(WB / name) == digest for name, digest in hashes.items())
        report['probe_unchanged'] = sha(args.probe) == report['probe_sha256']
        (args.evidence / 'receipt.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(dict(evidence=str(args.evidence), checks=len(report['checks']), findings=report['findings']), indent=2))


if __name__ == '__main__':
    main()
