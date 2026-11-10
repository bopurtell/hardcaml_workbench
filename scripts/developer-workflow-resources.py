#!/usr/bin/env python3
"""Read-only six-worker synthesis observer; never launches or cancels a flow.

Writes only a fresh evidence directory. watch requires an externally authored
activation file. On violation writes stop-request.json and exits 2; the acceptance
harness MUST cancel its own exact workflow on that signal or premature exit.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

IMAGE = 'sha256:d109140b8f17fc54f4fca998beb8124f4949404ec52e339eebd2250854a18b5a'
GENERATION = 'ee3af8de9f83418b9afed9c67e473e3c'
DOCKER = '/usr/bin/docker'
NATIVE = {'yosys', 'yosys-abc', 'abc', 'sta', 'openroad', 'iverilog', 'vvp', 'verilator_bin',
          'verilator', 'magic', 'netgen', 'klayout'}
BUILD = {'dune', 'make', 'ninja', 'ocamlopt', 'ocamlc', 'gcc', 'g++', 'cc', 'cc1',
         'cc1plus', 'ld', 'rustc', 'cargo'}
LIMIT_ENV = ('_OPENLANE_MAX_CORES', 'OPENROAD_THREADS', 'OMP_NUM_THREADS')


def executable_name(value):
    name = Path(value).name
    # Nix's standard makeWrapper layout, without accepting arbitrary aliases.
    if name.startswith('.') and name.endswith('-wrapped'):
        name = name[1:-8]
    return name


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def save(path, value):
    with path.open('x') as f:
        json.dump(value, f, indent=2)
        f.write('\n')


def command(argv, timeout=15):
    p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    if p.returncode:
        raise RuntimeError(f'{argv!r}: exit {p.returncode}: {p.stderr}')
    return p.stdout


def processes():
    rows = {}
    for path in Path('/proc').iterdir():
        if not path.name.isdigit():
            continue
        try:
            stat = (path / 'stat').read_text()
            fields = stat[stat.rindex(')') + 2:].split()
            argv = (path / 'cmdline').read_bytes().decode(errors='replace').strip('\0').split('\0')
            if not argv[0]:
                continue
            try:
                cwd = os.readlink(path / 'cwd')
            except PermissionError:
                cwd = None
            rows[int(path.name)] = dict(pid=int(path.name), ppid=int(fields[1]),
                pgid=int(fields[2]), session=int(fields[3]),
                start_ticks=int(fields[19]), comm=stat[stat.index('(') + 1:stat.rindex(')')],
                argv=argv, os_threads=int(fields[17]), cwd=cwd)
        except (FileNotFoundError, ProcessLookupError):
            pass
        except PermissionError:
            # Kernel/other-user processes are not silently represented as observed.
            rows[int(path.name)] = dict(pid=int(path.name), unreadable=True)
    return rows


def descendants(rows, root):
    found = {root}
    while True:
        more = {pid for pid, row in rows.items() if row.get('ppid') in found}
        if more <= found:
            return found
        found |= more


def workers(rows, excluded=()):
    result = []
    for pid, row in rows.items():
        if pid in excluded or row.get('unreadable'):
            continue
        base = executable_name(row['argv'][0])
        # Match executable identity, never tool names in an agent's prompt argv.
        if base in NATIVE | BUILD or row['comm'] in NATIVE | BUILD or \
           base.startswith(('ocamlopt.', 'ocamlc.')) or \
           base.endswith(('_sim.exe', 'workload_emit.exe')):
            result.append(row)
    return result


def running():
    ids = command([DOCKER, 'ps', '-q', '--no-trunc']).split()
    return json.loads(command([DOCKER, 'inspect', *ids])) if ids else []


def brief(container):
    return {key: container[key] for key in ('Id', 'Name', 'Image', 'State', 'Path', 'Args', 'Mounts', 'HostConfig', 'Config')}


def validate_container(c, store):
    errors = []
    if c['Image'] != IMAGE:
        errors.append('unexpected image')
    host = c['HostConfig']
    if host.get('NanoCpus') != 6_000_000_000 or host.get('CpuQuota', 0) not in (0, -1):
        errors.append('expected exact six-CPU NanoCpus without competing quota override')
    env = {}
    for item in c['Config']['Env']:
        key, _, value = item.partition('=')
        if key in env and key in LIMIT_ENV:
            errors.append('duplicate limit environment')
        env[key] = value
    if any(env.get(key) != '6' for key in LIMIT_ENV):
        errors.append('expected explicit six-thread transport environment')
    for key in ('STA_THREADS', 'OPENBLAS_NUM_THREADS', 'MKL_NUM_THREADS'):
        if key in env and (not env[key].isdigit() or not 1 <= int(env[key]) <= 6):
            errors.append('unknown/expanded ' + key)
    mounts = c['Mounts']
    if not any(m.get('Type') == 'bind' and Path(m['Source']).resolve().is_relative_to(store)
               and m.get('RW') for m in mounts):
        errors.append('no test-store writable bind mount')
    if any(m.get('RW') and not Path(m['Source']).resolve().is_relative_to(store) for m in mounts):
        errors.append('writable mount outside test store')
    if not re.fullmatch(r'/hardcaml-asic-execution-[0-9a-f]{32}', c['Name']):
        errors.append('unexpected owned-container name')
    return errors


def owned(c, store):
    return any(m.get('Type') == 'bind' and Path(m['Source']).resolve().is_relative_to(store)
               for m in c['Mounts'])


def native_limits(argv):
    errors = []
    for index, arg in enumerate(argv):
        value = None
        if arg in ('-threads', '--threads', '-j', '--jobs'):
            value = argv[index + 1] if index + 1 < len(argv) else ''
        elif arg.startswith(('-threads=', '--threads=', '--jobs=')):
            value = arg.partition('=')[2]
        elif re.fullmatch(r'-j[0-9]+', arg):
            value = arg[2:]
        if value is not None and (not value.isdigit() or not 1 <= int(value) <= 6):
            errors.append('unknown/expanded native worker flag: ' + arg)
    if executable_name(argv[0]) == 'sta' and '-threads' not in argv:
        errors.append('native STA lacks explicit supported -threads limit')
    return errors


def launch_record(store, name):
    for path in (store / 'asic-results').rglob('*.json'):
        if path.stat().st_size > 2 * 1024 * 1024:
            continue
        try:
            raw = path.read_bytes()
            if name.encode() not in raw:
                continue
            value = json.loads(raw)
            argv = value.get('argv', [])
            if '--name' in argv and argv[argv.index('--name') + 1] == name:
                return dict(path=str(path), sha256=hashlib.sha256(raw).hexdigest(), record=value)
        except (ValueError, OSError, AttributeError):
            continue
    raise RuntimeError('owned container has no pre-existing test-store launch argv receipt: ' + name)


def tasks(row, previous):
    observations = []
    for path in (Path('/proc') / str(row['pid']) / 'task').iterdir():
        try:
            text = (path / 'stat').read_text()
            f = text[text.rindex(')') + 2:].split()
            ticks = int(f[11]) + int(f[12])
            key = (row['pid'], row['start_ticks'], int(path.name), int(f[19]))
            prior = previous.get(key)
            observations.append(dict(tid=int(path.name), state=f[0], cpu_ticks=ticks,
                delta_ticks=None if prior is None else ticks - prior))
            previous[key] = ticks
        except (FileNotFoundError, ProcessLookupError):
            pass
    return observations


def audit(out):
    containers = running()
    rows = processes()
    competitors = workers(rows, descendants(rows, os.getpid()))
    result = dict(kind='admission-snapshot-not-activation', time_unix=time.time(),
        image=IMAGE, competing_workers=competitors,
        running_containers=[dict(id=c['Id'], name=c['Name'], image=c['Image']) for c in containers],
        unreadable_pids=[pid for pid, r in rows.items() if r.get('unreadable')],
        clear=not competitors and not containers)
    save(out / 'admission.json', result)
    return result['clear']


METADATA = r'''
import hashlib, importlib.metadata, inspect, json, os, shutil, subprocess
from librelane.flows.classic import Classic
from librelane.steps import yosys, openroad
def source(obj):
    text=inspect.getsource(obj)
    return dict(source=text, sha256=hashlib.sha256(text.encode()).hexdigest())
tools={}
for name, options in [('yosys',['-V']),('yosys',['-h']),('yosys',['-h','abc']),('yosys-abc',['-h']),
                      ('sta',['-version']),('sta',['-help'])]:
    path=shutil.which(name)
    if path is None:
        tools[name+' '+ ' '.join(options)]=dict(missing=True)
        continue
    p=subprocess.run([path,*options],capture_output=True,text=True,timeout=20)
    tools[name+' '+ ' '.join(options)]=dict(path=path,argv=[path,*options],exit_code=p.returncode,
        stdout=p.stdout,stderr=p.stderr)
endpoint=next(i for i,s in enumerate(Classic.Steps) if s.id=='Yosys.Synthesis')
prefix=Classic.Steps[:endpoint+1]
methods={}
for cls in yosys.Synthesis.__mro__:
    for method in ['get_command','run','get_script_path']:
        if method in cls.__dict__:
            methods[cls.__name__+'.'+method]=source(getattr(cls,method))
print(json.dumps(dict(librelane=importlib.metadata.version('librelane'), tools=tools,
    synthesis_methods=methods,
    synthesis_prefix=[dict(id=s.id,implementation=s.get_implementation_id()) for s in prefix],
    sources={name:source(obj) for name,obj in [('synthesis',yosys.Synthesis),
      ('synthesis_command',yosys.Synthesis.get_command),
      ('synthesis_run',yosys.Synthesis.run),
      ('sta_command',openroad.OpenSTAStep.get_command)]},
    environment={k:os.environ.get(k) for k in ['OMP_NUM_THREADS','OPENROAD_THREADS',
        '_OPENLANE_MAX_CORES','OPENBLAS_NUM_THREADS','MKL_NUM_THREADS']})))
'''


def metadata(out):
    # No mounts, no flow construction/start, no scripts/designs supplied to tools.
    name = 'workbench-resource-metadata-' + os.urandom(8).hex()
    argv = [DOCKER, 'run', '--rm', '--pull=never', '--network=none', '--read-only',
            '--cpus=2', '--pids-limit=128', '--name', name,
            '--tmpfs', '/tmp:rw,noexec,nosuid,size=32m']
    for key in (*LIMIT_ENV, 'OPENBLAS_NUM_THREADS', 'MKL_NUM_THREADS'):
        argv += ['-e', key + '=2']
    argv += ['--entrypoint', 'python3', IMAGE, '-B', '-c', METADATA]
    save(out / 'metadata-request.json', dict(argv=argv, image=IMAGE, eda_launches=0,
         metadata_cpus=2, maximum_thread_environment=2))
    save(out / 'image.json', json.loads(command([DOCKER, 'image', 'inspect', IMAGE])))
    try:
        raw = command(argv, timeout=120)
        save(out / 'metadata.json', json.loads(raw))
    finally:
        # Only our randomly named metadata container, including timeout cleanup.
        p = subprocess.run([DOCKER, 'rm', '-f', name], capture_output=True, text=True, timeout=15)
        save(out / 'metadata-cleanup.json', dict(argv=p.args, exit_code=p.returncode,
             stdout=p.stdout, stderr=p.stderr))
    return True


def watch(args, out):
    store = args.store.resolve(strict=True)
    if args.finish.exists():
        raise ValueError('finish marker already exists')
    if not store.is_relative_to(Path('/tmp/opencode')):
        raise ValueError('watch admits only a /tmp/opencode test-owned store')
    manifest = store / 'manifest.json'
    m = json.loads(manifest.read_text())
    activation = json.loads(args.activation.read_text())
    required = dict(schema_version=1, allocation=6, endpoint='synthesis',
                    store=str(store), manifest_sha256=digest(manifest), activated=True)
    if any(activation.get(k) != v for k, v in required.items()):
        raise ValueError('coordinator activation must match ' + json.dumps(required))
    if not 0 < time.time() - activation['activated_at_unix'] < 300:
        raise ValueError('activation is not fresh (maximum 300 seconds)')
    if Path(m['inputs']['asic_generation']).name != GENERATION:
        raise ValueError('unexpected provider generation')
    bridge = Path(m['inputs']['asic_generation']) / 'lib/hardcaml_asic/flow/hardcaml_asic_flow/librelane_bridge.py'
    text = bridge.read_text()
    if 'ThreadPoolExecutor(max_workers=6)' not in text or '"STA_THREADS=1"' not in text:
        raise ValueError('unexpected installed bridge resource contract')
    save(out / 'activation.json', activation)
    save(out / 'bridge.json', dict(path=str(bridge), sha256=digest(bridge),
         executor_max_workers=6, sta_corner_workers=1,
         note='Configured executor ceiling, not a count of active or native OS threads.'))
    if not audit(out):
        raise RuntimeError('admission blocked: competing workers or running containers')
    save(out / 'ready.json', dict(ready=True, pid=os.getpid(), store=str(store),
         manifest_sha256=digest(manifest), allocation=6, image=IMAGE))
    known, previous, peaks = {}, {}, dict(native_os_threads=0, native_runnable_threads=0,
        native_cpu_progress_threads=0, native_processes=0, python_os_threads=0)
    seen_flow = False
    started = time.monotonic()
    samples = 0
    with (out / 'samples.jsonl').open('x', buffering=1) as log:
        while not args.finish.exists():
            if time.monotonic() - started > args.timeout:
                raise RuntimeError('monitor deadline exceeded; acceptance owner must cancel')
            rows = processes()
            containers = running()
            accepted = []
            excluded = descendants(rows, os.getpid())
            native_count = runnable = progressing = native_threads = 0
            for c in containers:
                if not owned(c, store):
                    raise RuntimeError('unowned running container: ' + c['Name'])
                log.write(json.dumps(dict(time_unix=time.time(), kind='docker-inspect',
                     inspect=brief(c))) + '\n')
                errors = validate_container(c, store)
                if errors:
                    raise RuntimeError(c['Name'] + ': ' + '; '.join(errors))
                cid = c['Id']
                if cid not in known:
                    record = launch_record(store, c['Name'].lstrip('/'))
                    save(out / (cid + '-inspect.json'), dict(inspect=brief(c), launch=record))
                    known[cid] = c['Name']
                argv = [c['Path'], *c['Args']]
                is_flow = any(arg.endswith('/librelane_bridge.py') for arg in argv)
                if is_flow:
                    seen_flow = True
                    request_path = Path(argv[-1]).resolve(strict=True)
                    if not request_path.is_relative_to(store):
                        raise RuntimeError('request outside test store')
                    request = json.loads(request_path.read_text())
                    if request['boundary'] != 'synthesis' or request['checkpoint'] is not None:
                        raise RuntimeError('nonfresh/nonsynthesis backend request')
                elif not ('-c' in argv and argv[-1] in ('container', 'metadata-container')):
                    raise RuntimeError('unknown owned container command')
                pids = descendants(rows, c['State']['Pid'])
                excluded |= pids
                observed = []
                for pid in sorted(pids):
                    row = rows.get(pid)
                    if row is None:
                        continue
                    if row.get('unreadable'):
                        raise RuntimeError('unreadable owned process')
                    try:
                        ts = tasks(row, previous)
                    except FileNotFoundError:
                        continue
                    base = executable_name(row['argv'][0])
                    is_native = base in NATIVE or row['comm'] in NATIVE
                    log.write(json.dumps(dict(time_unix=time.time(), kind='process',
                        container_id=cid, process=dict(**row, native=is_native, tasks=ts))) + '\n')
                    if base.startswith('python'):
                        peaks['python_os_threads'] = max(peaks['python_os_threads'], row['os_threads'])
                    elif not is_native and base not in {'sh', 'bash', 'env'} and not (
                        base == 'perl' and len(row['argv']) > 1 and
                        executable_name(row['argv'][1]) == 'verilator' and
                        '--lint-only' in row['argv'] and row['os_threads'] == 1):
                        raise RuntimeError('unknown owned native executable: ' + json.dumps(row))
                    if is_native:
                        native_count += 1
                        native_threads += row['os_threads']
                        runnable += sum(t['state'] == 'R' for t in ts)
                        progressing += sum((t['delta_ticks'] or 0) > 0 for t in ts)
                        if row['os_threads'] > 6:
                            raise RuntimeError('native OS threads exceed six: ' + json.dumps(row))
                        errors = native_limits(row['argv'])
                        if errors:
                            raise RuntimeError('; '.join(errors) + ': ' + json.dumps(row))
                        if base in {'openroad', 'magic', 'netgen', 'klayout'}:
                            raise RuntimeError('unexpected native tool in synthesis-only prefix: ' + base)
                    observed.append(dict(**row, native=is_native, tasks=ts))
                accepted.append(dict(id=cid, name=c['Name'], flow=is_flow, processes=observed))
            if len(accepted) > 1:
                raise RuntimeError('overlapping owned containers')
            competitors = workers(rows, excluded)
            # Own source build is allowed before first bridge call, never afterward.
            competitors = [r for r in competitors if seen_flow or accepted or not
                           (r['cwd'] and Path(r['cwd']).is_relative_to(store))]
            if competitors:
                raise RuntimeError('competing build/native work: ' + json.dumps(competitors))
            if native_threads > 6 or runnable > 6 or progressing > 6:
                raise RuntimeError('aggregate native thread budget exceeded')
            for key, value in [('native_os_threads', native_threads), ('native_processes', native_count),
                               ('native_runnable_threads', runnable), ('native_cpu_progress_threads', progressing)]:
                peaks[key] = max(peaks[key], value)
            log.write(json.dumps(dict(time_unix=time.time(), containers=accepted,
                native_os_threads=native_threads, native_runnable_threads=runnable,
                native_cpu_progress_threads=progressing, competing_workers=competitors)) + '\n')
            samples += 1
            time.sleep(args.interval)
    if any(owned(c, store) for c in running()):
        raise RuntimeError('finish requested with test-owned container still running')
    save(out / 'summary.json', dict(completed=True, seen_flow=seen_flow, samples=samples,
         containers=known, peaks=peaks, interval_seconds=args.interval,
         limitations=['Sampling can miss short processes/threads and is not exhaustive peak proof.',
             'CPU-progress threads in one interval need not have run simultaneously.',
             'Python OS threads include idle executor/controller threads; not native worker count.',
             'Configured bounds plus retained native command/step evidence require independent review.']))
    return seen_flow


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('mode', choices=('audit', 'metadata', 'watch'))
    p.add_argument('--evidence', type=Path, required=True)
    p.add_argument('--store', type=Path)
    p.add_argument('--activation', type=Path)
    p.add_argument('--finish', type=Path)
    p.add_argument('--interval', type=float, default=.25)
    p.add_argument('--timeout', type=float, default=900)
    args = p.parse_args()
    if args.mode == 'watch' and not all((args.store, args.activation, args.finish)):
        p.error('watch requires --store, --activation and --finish')
    if not .1 <= args.interval <= 1 or not 1 <= args.timeout <= 3600:
        p.error('interval must be .1..1 and timeout 1..3600')
    out = args.evidence.resolve()
    if not out.is_relative_to(Path('/tmp/opencode')):
        p.error('evidence must be a fresh directory under /tmp/opencode')
    out.mkdir()  # Never overwrite a previous monitoring attempt.
    save(out / 'observer.json', dict(script=str(Path(__file__).resolve()), sha256=digest(__file__),
         argv=sys.argv, image=IMAGE, mode=args.mode, started_at_unix=time.time()))
    try:
        ok = audit(out) if args.mode == 'audit' else metadata(out) if args.mode == 'metadata' else watch(args, out)
        return 0 if ok else 2
    except Exception as exc:
        save(out / 'stop-request.json', dict(reason=str(exc), time_unix=time.time(),
             action='acceptance harness must cancel only its exact test-owned workflow',
             observer_sent_signals=False))
        print(str(exc), file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
