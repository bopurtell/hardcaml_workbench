#!/usr/bin/env python3
"""Cached real-state dashboard regression: no builds or provider operations.

Only copies Workbench *.sexp state into a unique evidence directory. The source
state, example config and provider results are read-only inputs. Uses existing
terminal/daemon binaries and the shared test-support ANSI emulator (stdlib only).
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import sys
import tempfile
import traceback

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'test'))
from support.terminal import Terminal

spec = importlib.util.spec_from_file_location('fs0', Path(__file__).with_name('test-fs0.py'))
fs0 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fs0)
field, record, require = fs0.field, fs0.record, fs0.require


def inventory(paths):
    """Metadata for every provider file; content hashes for config/state/evidence JSON."""
    result = {}
    for root in paths:
        for path in sorted(root.rglob('*')) if root.is_dir() else [root]:
            if path.is_file():
                st = path.stat()
                item = dict(size=st.st_size, mtime_ns=st.st_mtime_ns, ctime_ns=st.st_ctime_ns)
                if path.suffix in ('.sexp', '.json') or path == root:
                    item['sha256'] = hashlib.sha256(path.read_bytes()).hexdigest()
                result[str(path)] = item
    return result


def exercise(args):
    source = args.source_state.resolve()
    require(source.is_dir(), 'Missing saved Workbench state')
    config = args.example_root / 'hardcaml-workbench-asic.sexp'
    cfg = record(fs0.parse(config.read_text()))
    watched = [source, config, Path(cfg['results_root']), Path(cfg['provider_executable'])]
    before_files = inventory(watched)
    (args.evidence / 'files-before.json').write_text(json.dumps(before_files, indent=2))
    state = args.evidence / 'state'
    state.mkdir()
    copied = []
    for path in source.glob('*.sexp'):
        require(not path.is_symlink(), 'Refusing symlink in saved state')
        require(path.name.startswith(('asic-', 'workspace-')), 'Unexpected WB state file')
        shutil.copy2(path, state / path.name)
        copied.append(path.name)
    require(any(n.startswith('workspace-') for n in copied), 'No workspace copied')
    session = fs0.Session(args, args.evidence, args.example_root)
    session.state_dir = state
    terminal = None
    result = dict(status='failed', source_state=str(source), copied=copied,
                  state_dir=str(state), pty=dict(width=120, height=40), checks=[])
    def check(ok, message):
        result['checks'].append(dict(passed=bool(ok), expectation=message))
        require(ok, message)
    try:
        session.start()
        initial = session.rpc('workspace')
        asic_before = session.rpc('asic')
        for run in field(asic_before, 'runs'):
            session.rpc('asic', '(Load_summary ' + fs0.sexp(field(run, 'run')) + ')', wait=True)
        asic_before = session.rpc('asic')
        check(sorted(field(s, 'cell_count') for s in field(asic_before, 'summaries')) == [['673'], ['685']],
              'Cached real synthesis summaries contain 673 and 685')
        check(all(field(s, 'freshness') == 'Cached_unverified' for s in field(asic_before, 'summaries')),
              'Cached replay does not validate provider evidence')
        overview = next(w for w in field(initial, 'workspaces') if field(w, 'name') == 'Overview')
        demo = next(w for w in reversed(field(initial, 'workspaces'))
                    if field(w, 'name').startswith('FS0 Real Demo') and
                    len([t for t in field(initial, 'tiles') if field(t, 'workspace') == field(w, 'id')]) == 2)
        check(not any(field(t, 'workspace') == field(overview, 'id') for t in field(initial, 'tiles')),
              'Source reproduces empty Overview')
        terminal = Terminal(session)
        terminal.capture('01-empty-overview', ['Overview', 'No visible tiles', 'Apply default layout'])
        check(b'Loading workspace...' in terminal.data, 'Startup renders loading workspace host')
        check(b'PROJECT / GENERIC DUNE WORKSPACE' not in terminal.data,
              'Startup transcript contains no legacy PROJECT flash')
        check(session.rpc('workspace') == initial, 'Startup leaves registry unchanged')
        terminal.palette('Apply default layout (add missing tiles)')
        dashboard = session.rpc('workspace')
        tiles = [t for t in field(dashboard, 'tiles') if field(t, 'workspace') == field(overview, 'id')]
        kinds = ['run-selector', 'synthesis', 'placement', 'cts', 'routing', 'timing', 'checks',
                 'finalization', 'asic', 'execution', 'project-tests', 'logs', 'navigation']
        check(sorted(field(t, 'kind') for t in tiles) == sorted(kinds), 'Default action adds all thirteen kinds')
        check(all(t in field(dashboard, 'tiles') for t in field(initial, 'tiles')) and
              len(field(dashboard, 'tiles')) == len(field(initial, 'tiles')) + 13,
              'Default action preserves all original tiles and adds exactly thirteen')
        check(field(initial, 'contexts') == field(dashboard, 'contexts'),
              'Additive recovery preserves selections and contexts')
        text = terminal.capture('02-default-fit', kinds + ['Cell count: 685', 'Not requested', 'unsupported'])
        placement = '\n'.join(line[80:] for line in text.splitlines()[1:8])
        check('placement' in placement.lower() and 'Not requested' in placement and 'Unsupported' in placement,
              'Placement region explicitly reports not requested and unsupported')
        check(not any(metric in placement.lower() for metric in ['cell count:', 'slack:', 'area:', 'utilization:']),
              'Placement region contains no invented synthesis or physical metrics')
        (args.evidence / 'placement-region.txt').write_text(placement)
        check(any(len(line.rstrip()) >= 118 for line in text.splitlines()[1:-1]), 'Fit fills screen width')
        check(any(line.strip() for line in text.splitlines()[32:38]), 'Fit fills lower screen surface')
        # Rendering-only style/layout checks must not mutate registry at all.
        baseline = session.rpc('workspace')
        for i, title in enumerate(['Appearance: B - Structured', 'Layout: Requested tile sizes',
                                   'Appearance: C - Minimal', 'Appearance: D - Studio', 'Layout: Fit tiles to window',
                                   'Appearance: A - Instrument']):
            terminal.palette(title)
            terminal.capture(f'03-transition-{i}')
            check(session.rpc('workspace') == baseline, title + ' leaves full registry unchanged')
        terminal.capture('04-restored-fit', kinds + ['Cell count: 685'])
        terminal.palette('Switch to ' + field(demo, 'name'))
        text = terminal.capture('05-demo-fit', ['Cell count: 673', 'Cell count: 685', 'Cached_unverified'])
        demo_tiles = [t for t in field(initial, 'tiles') if field(t, 'workspace') == field(demo, 'id')]
        check(all(field(field(t, 'requested_geometry'), 'width') == '56' and
                  field(field(t, 'requested_geometry'), 'height') == '14' for t in demo_tiles),
              'Saved demo reproduces two 56x14 requested tiles')
        check(field(demo_tiles[0], 'binding')[0] == 'Pin_run' and field(demo_tiles[1], 'binding') == 'Follow',
              'Demo starts with explicit pinned and following bindings')
        check('Cell count: 673' in text.splitlines()[4][:60] and
              'Cell count: 685' in text.splitlines()[4][61:], 'Pinned 673 left and following 685 right')
        check(len(text.splitlines()[38]) == 120 and text.splitlines()[38].count('+') == 4,
              'Both Fit tile frames reach row 39 and span all 120 columns')
        check(any(line.strip() for line in text.splitlines()[32:38]), 'Two demo tiles fill lower Fit surface')
        check(session.rpc('workspace') == baseline, 'Workspace switch preserves registry including pin/follow')
        for i, title in enumerate(['Layout: Requested tile sizes', 'Appearance: E - Structured studio',
                                   'Layout: Fit tiles to window']):
            terminal.palette(title)
            transition = terminal.capture(f'06-demo-transition-{i}', ['Cell count: 673', 'Cell count: 685'])
            if i == 0:
                check(not any(line.strip() for line in transition.splitlines()[15:39]) and
                      transition.splitlines()[14].count('+') == 4,
                      'Preferred restores 14-row shelf instead of Fit surface')
            check(session.rpc('workspace') == baseline, title + ' preserves demo bindings and geometry')
        terminal.capture('07-demo-final', ['Cell count: 673', 'Cell count: 685'])
        asic_after = session.rpc('asic')
        check(field(asic_before, 'runs') == field(asic_after, 'runs'), 'No run allocations or run changes')
        check(field(asic_before, 'operations') == field(asic_after, 'operations'), 'No provider operations added')
        result.update(status='passed', initial_workspace=record(initial), final_workspace=record(baseline),
                      asic_before=record(asic_before), asic_after=record(asic_after),
                      protocol_counts=dict(runs_before=len(field(asic_before, 'runs')),
                                           runs_after=len(field(asic_after, 'runs')),
                                           operations_before=len(field(asic_before, 'operations')),
                                           operations_after=len(field(asic_after, 'operations')),
                                           tiles_before=len(field(initial, 'tiles')),
                                           tiles_after=len(field(baseline, 'tiles'))))
    except Exception:
        result['error'] = traceback.format_exc()
        raise
    finally:
        if terminal:
            terminal.close()
        if session.process:
            session.stop()
        after_files = inventory(watched)
        (args.evidence / 'files-after.json').write_text(json.dumps(after_files, indent=2))
        unchanged = before_files == after_files
        result['input_files_unchanged'] = unchanged
        if not unchanged:
            result['status'] = 'failed'
        (args.evidence / 'result.json').write_text(json.dumps(result, indent=2))
        require(unchanged, 'Original state/config/provider files changed; see inventories')


def main():
    repo = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-state', type=Path, default=Path('/tmp/opencode/workbench-fs0-91em64rl/real/state'))
    parser.add_argument('--example-root', type=Path, default=repo.parent / 'hardcaml_asic_example')
    parser.add_argument('--client', type=Path, default=repo / '_build/default/terminal/main.exe')
    parser.add_argument('--daemon', type=Path, default=repo / '_build/default/daemon/main.exe')
    args = parser.parse_args()
    args.outer_timeout = 60
    args.evidence = Path(tempfile.mkdtemp(prefix='workbench-fs0-dashboard-', dir='/tmp/opencode'))
    print('Evidence: ' + str(args.evidence), flush=True)
    exercise(args)
    print('PASS: cached dashboard PTY regression', flush=True)


if __name__ == '__main__':
    main()
