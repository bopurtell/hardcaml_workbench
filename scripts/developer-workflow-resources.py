#!/usr/bin/env python3
"""Read-only six-worker synthesis observer; never launches or cancels a flow.

Writes only a fresh evidence directory. watch requires an externally authored
activation file. On violation writes stop-request.json and exits 2; the acceptance
harness MUST cancel its own exact workflow on that signal or premature exit.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import time

IMAGE = 'sha256:d109140b8f17fc54f4fca998beb8124f4949404ec52e339eebd2250854a18b5a'
GENERATION = 'ee8be18f0a5a43f1aab099ff8c4ce24f'
DOCKER = '/usr/bin/docker'
NATIVE = {'yosys', 'yosys-abc', 'abc', 'sta', 'openroad', 'iverilog', 'vvp', 'verilator_bin',
          'verilator', 'magic', 'netgen', 'klayout'}
BUILD = {'dune', 'make', 'ninja', 'ocamlopt', 'ocamlc', 'gcc', 'g++', 'cc', 'cc1', 'as',
         'cc1plus', 'ld', 'rustc', 'cargo'}
LIMIT_ENV = ('_OPENLANE_MAX_CORES', 'OPENROAD_THREADS', 'OMP_NUM_THREADS')
EXAMPLE_STORES = Path('/home/wayne/devel/jane/hardcaml_asic_example/.dev')


def executable_name(value):
    name = Path(value).name
    # Nix's standard makeWrapper layout, without accepting arbitrary aliases.
    if name.startswith('.') and name.endswith('-wrapped'):
        name = name[1:-8]
    return name


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def save(path, value):
    # Publish whole receipts atomically; readers may hash ready as soon as it appears.
    temporary = path.with_name(path.name + '.pending')
    with temporary.open('x') as f:
        json.dump(value, f, indent=2)
        f.write('\n')
    try:
        os.link(temporary, path)  # exclusive publication, never overwrite evidence
    finally:
        temporary.unlink()


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
                argv=argv, state=fields[0], os_threads=int(fields[17]), cwd=cwd)
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


def validate_container(c, store, metadata_only=False):
    errors = []
    if c['Image'] != IMAGE:
        errors.append('unexpected image')
    host = c['HostConfig']
    if host.get('PidsLimit') != 6:
        errors.append('expected enforced total container task limit6')
    if host.get('NanoCpus') != 6_000_000_000 or host.get('CpuQuota', 0) not in (0, -1):
        errors.append('expected exact six-CPU NanoCpus without competing quota override')
    env = {}
    for item in c['Config']['Env']:
        key, _, value = item.partition('=')
        if key in env and key in (*LIMIT_ENV, 'STA_THREADS', 'OPENBLAS_NUM_THREADS', 'MKL_NUM_THREADS'):
            errors.append('duplicate limit environment')
        env[key] = value
    required_env = ('_OPENLANE_MAX_CORES', 'OMP_NUM_THREADS') if metadata_only else LIMIT_ENV
    if any(env.get(key) != '6' for key in required_env):
        errors.append('expected explicit six-thread transport environment')
    for key in ('STA_THREADS', 'OPENBLAS_NUM_THREADS', 'MKL_NUM_THREADS'):
        if key in env and (not env[key].isdigit() or not 1 <= int(env[key]) <= 6):
            errors.append('unknown/expanded ' + key)
    mounts = c['Mounts']
    if not metadata_only and not any(m.get('Type') == 'bind' and Path(m['Source']).resolve().is_relative_to(store)
               and m.get('RW') for m in mounts):
        errors.append('no test-store writable bind mount')
    if any(m.get('RW') and not Path(m['Source']).resolve().is_relative_to(store) for m in mounts):
        errors.append('writable mount outside test store')
    if any(m.get('Type') != 'bind' or m.get('Destination') != m.get('Source') for m in mounts):
        errors.append('expected provider identity-mapped bind mounts only')
    if not re.fullmatch(r'/hardcaml-asic-execution-[0-9a-f]{32}', c['Name']):
        errors.append('unexpected owned-container name')
    if metadata_only and (mounts or not host.get('ReadonlyRootfs') or host.get('NetworkMode') != 'none'):
        errors.append('metadata-only transport must have no mounts, read-only root and no network')
    if host.get('Privileged') or host.get('PidMode') == 'host' or host.get('CapAdd'):
        errors.append('unexpected container privilege/PID configuration')
    return errors


def owned(c, store):
    return any(m.get('Type') == 'bind' and Path(m['Source']).resolve().is_relative_to(store)
               for m in c['Mounts'])


def native_limits(argv):
    errors = []
    for index, arg in enumerate(argv):
        value = None
        if arg in ('-threads', '--threads', '-j', '--jobs', '--verilate-jobs', '--build-jobs',
                   '--hierarchical-threads', '--trace-threads'):
            value = argv[index + 1] if index + 1 < len(argv) else ''
        elif arg.startswith(('-threads=', '--threads=', '--jobs=', '--verilate-jobs=', '--build-jobs=',
                             '--hierarchical-threads=', '--trace-threads=')):
            value = arg.partition('=')[2]
        elif re.fullmatch(r'-j[0-9]+', arg):
            value = arg[2:]
        if value is not None and (not value.isdigit() or not 1 <= int(value) <= 6):
            errors.append('unknown/expanded native worker flag: ' + arg)
    if executable_name(argv[0]) == 'sta' and '-threads' not in argv:
        errors.append('native STA lacks explicit supported -threads limit')
    return errors


def preparation_workers(rows, competitors, store, dune):
    """Admit one explicit max2 private source Dune tree before any container.

    No cwd-only exemptions: nested schedulers/native EDA and a second Dune tree
    are competitors even within the test store. Observed thread sum is a tripwire,
    not a proof that a compiler cannot create short-lived threads.
    """
    roots = [r for r in competitors if r['argv'][0] == dune]
    if len(roots) != 1:
        return []
    root = roots[0]
    argv = root['argv']
    bounds = []
    for i, arg in enumerate(argv):
        if arg in ('-j', '--jobs'):
            bounds.append(argv[i + 1] if i + 1 < len(argv) else '')
        elif arg.startswith('--jobs='):
            bounds.append(arg.partition('=')[2])
        elif arg.startswith('-j'):
            bounds.append(arg[2:])
    if not bounds or any(v not in ('1', '2') for v in bounds):
        return []
    if (argv.count('--root') != 1 or argv.index('--root') + 1 == len(argv)
            or argv[argv.index('--root') + 1] != str(store / 'project')
            or not root.get('cwd') or not Path(root['cwd']).is_relative_to(store)):
        return []
    family = descendants(rows, root['pid'])
    allowed = []
    for row in competitors:
        base = executable_name(row['argv'][0])
        if row['pid'] not in family or (row is not root and base not in
                {'ocamlopt', 'ocamlc', 'gcc', 'g++', 'cc', 'cc1', 'cc1plus', 'ld', 'as'}
                and not base.startswith(('ocamlopt.', 'ocamlc.'))):
            return []
        allowed.append(row)
    if sum(r['os_threads'] for r in allowed if r is not root) > 6:
        return []
    return allowed


def launch_record(store, name, payload=None):
    matches = []
    # ownership-v1 can move result roots. Only inspect bounded JSON in this store;
    # never follow a receipt symlink into owner or sibling history.
    for path in store.rglob('*.json'):
        if not path.resolve().is_relative_to(store):
            continue
        try:
            if path.stat().st_size > 2 * 1024 * 1024:
                continue
            raw = path.read_bytes()
            if name.encode() not in raw:
                continue
            value = json.loads(raw)
            argv = value.get('argv', [])
            if not isinstance(argv, list) or not all(isinstance(a, str) for a in argv):
                continue
            if argv.count('--name') == 1 and argv[argv.index('--name') + 1] == name:
                if argv.count(IMAGE) != 1 or (payload is not None and argv[argv.index(IMAGE) + 1:] != payload):
                    raise RuntimeError('launch receipt payload/image mismatch: ' + str(path))
                # Runtime probes rewrite the same path with terminal data. Match
                # by content, not a stale filename or pre-launch hash assumption.
                matches.append(dict(path=str(path), sha256=hashlib.sha256(raw).hexdigest(), record=value))
        except (ValueError, OSError, AttributeError, IndexError):
            continue
    if len(matches) == 1:
        return matches[0]
    if matches:
        raise RuntimeError('ambiguous launch receipts: ' + name)
    raise RuntimeError('owned container has no pre-existing test-store launch argv receipt: ' + name)


def container_kind(c, helper, store):
    argv = [c['Path'], *c['Args']]
    if executable_name(argv[0]) != 'python3':
        raise RuntimeError('unexpected container entrypoint')
    args = argv[1:]
    if args[:2] == ['-I', '-B']:
        args = args[2:]
    elif args[:1] == ['-B']:
        args = args[1:]
    else:
        raise RuntimeError('missing provider interpreter flags')
    if len(args) == 3 and args == ['-c', (helper / 'stage_metadata_probe.py').read_text(), 'metadata-container']:
        return 'metadata'
    if len(args) == 3 and args == ['-c', (helper / 'stage_metadata_probe.py').read_text(), 'container']:
        return 'probe'
    if len(args) != 2 or Path(args[0]).name != 'librelane_bridge.py':
        raise RuntimeError('unknown owned container command')
    bridge, request_path = (Path(a).resolve(strict=True) for a in args)
    if not all(p.is_relative_to(store) for p in (bridge, request_path)):
        raise RuntimeError('transported bridge/request outside test store')
    if digest(bridge) != digest(helper / 'librelane_bridge.py'):
        raise RuntimeError('transported bridge differs from immutable provider')
    request = json.loads(request_path.read_text())
    if request.get('boundary') != 'synthesis' or request.get('checkpoint', 'missing') is not None:
        raise RuntimeError('nonfresh/nonsynthesis backend request')
    if request.get('operation') not in ('execute_segment', 'validate_publication'):
        raise RuntimeError('unexpected bridge operation')
    return 'flow' if request['operation'] == 'execute_segment' else 'publication'


def capture(store):
    if not (store.is_relative_to(Path('/tmp/opencode')) or store.parent == EXAMPLE_STORES):
        raise ValueError('watch requires a private /tmp/opencode or example .dev store')
    if store == EXAMPLE_STORES / 'workbench-development':
        raise ValueError('owner store is never admitted')
    manifest = store / 'manifest.json'
    m = json.loads(manifest.read_text())
    generation = Path(m['generation'])
    if (m.get('source_layout') != 'ownership-v1' or m.get('max_jobs') not in (1, 2) or m['store'] != str(store)
            or m['project_root'] != str(store / 'project')
            or generation.parent != store / 'generations' or generation.resolve() != generation
            or (store / 'selected').resolve() != generation
            or manifest.read_bytes() != (generation / 'manifest.json').read_bytes()):
        raise ValueError('requires exact selected ownership-v1 capture in private store')
    asic = Path(m['inputs']['asic_generation'])
    if asic.name != GENERATION or asic.resolve() != asic:
        raise ValueError('unexpected provider generation')
    if digest(asic / 'receipt.json') != m['asic_receipt_sha256']:
        raise ValueError('provider receipt changed')
    if not m.get('asic_files'):
        raise ValueError('missing provider capture inventory')
    for name, expected in m['asic_files'].items():
        path = asic / name
        if not path.resolve().is_relative_to(asic) or digest(path) != expected:
            raise ValueError('provider capture bytes changed: ' + name)
    return m


def object_digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def cap_binding(store, m):
    generation = Path(m['generation'])
    sdk = {name: sha for name, sha in m['captured_files'].items() if name.startswith('sdk/')}
    if not sdk or m['environment'].get('HARDCAML_ASIC_SYNTHESIS_TASK_LIMIT') != '6':
        raise ValueError('capture must explicitly opt in to task-limit6 and inventory its SDK')
    for name, expected in sdk.items():
        path = generation / name
        if not path.resolve().is_relative_to(generation / 'sdk') or digest(path) != expected:
            raise ValueError('captured SDK changed: ' + name)
    return dict(store=str(store), manifest_sha256=digest(store / 'manifest.json'),
        asic_generation=m['inputs']['asic_generation'], asic_receipt_sha256=m['asic_receipt_sha256'],
        provider_inventory_sha256=object_digest(m['asic_files']), sdk_inventory_sha256=object_digest(sdk),
        image=IMAGE, profile='synthesis-total-tasks-v1', total_container_tasks=6,
        configured_executor_max_workers=6, reduced_usable_executor_concurrency=True)


def kernel_limits(pid):
    entries = (Path('/proc') / str(pid) / 'cgroup').read_text().splitlines()
    paths = [line[3:] for line in entries if line.startswith('0::')]
    if len(paths) != 1:
        raise RuntimeError('owned process lacks one cgroup-v2 membership')
    root = Path('/sys/fs/cgroup')
    group = (root / paths[0].lstrip('/')).resolve(strict=True)
    if not group.is_relative_to(root):
        raise RuntimeError('invalid owned cgroup path')
    return dict(path=str(group), **{key: (group / key).read_text().strip()
                for key in ('pids.max', 'pids.current', 'pids.events', 'cpu.max')})


CAP_CONSUMER = r'''
open Hardcaml_asic_execution
module J=Identity_json
module T=Execution_transport
let ok=function Ok x->x | Error _->failwith "invalid metadata input"
let get j k=match j with J.Object xs->List.assoc k xs | _->failwith "object required"
let text=function J.String s->s | _->failwith "string required"
let read p=let ic=open_in_bin p in Fun.protect ~finally:(fun()->close_in ic)
  (fun()->really_input_string ic (in_channel_length ic))
let ()=
  let config=ok (J.parse (read Sys.argv.(1))) in
  let d=match ok (T.of_json (get config "binding")) with T.Docker d->d | _->failwith "Docker required" in
  let environment=Array.to_list (Unix.environment ()) in
  if not (Synthesis_envelope.requested environment) then failwith "explicit profile required";
  let invocation=T.metadata_invocation ~workers:2 ?pids_limit:(Synthesis_envelope.pids_limit environment) d
    ~arguments:["-c";read (text (get config "payload"));"metadata-container"] ~environment
    ~stdout:(Process.File (text (get config "stdout"))) ~stderr:(Process.File (text (get config "stderr"))) in
  let argv=(T.process_specification invocation).argv in
  let record fields=ok (J.object_ fields) in
  Result_store.save_json (text (get config "launch")) (record ["argv",J.array (List.map (fun s->ok (J.string s)) argv)]);
  let result=T.run ~timeout:20. invocation in
  Result_store.save_json (text (get config "result")) (record ["succeeded",J.bool (T.succeeded result);
    "envelope",Synthesis_envelope.to_json ();"process",Segment_service.process_json result.process]);
  if not (T.succeeded result) then exit 2
'''
CAP_PROOF_FILES = ('engine.json', 'native-launch.json', 'native-result.json', 'enforcement.json', 'native.stdout',
                   'consumer-exit.json', 'consumer-build.json', 'consumer/probe.ml', 'build/default/probe.exe')


def cap_probe(args, out):
    store = args.store.resolve(strict=True)
    m = capture(store)
    binding = cap_binding(store, m)
    info = json.loads(command([DOCKER, 'info', '--format', '{{json .}}']))
    if info.get('Name') != os.uname().nodename or info.get('CgroupVersion') != '2' or not info.get('PidsLimit'):
        raise RuntimeError('cap probe requires the local cgroup-v2 engine with task limits')
    if running():
        raise RuntimeError('cap probe requires no running containers')
    image = json.loads(command([DOCKER, 'image', 'inspect', IMAGE]))[0]
    engine = dict(name='docker', executable=DOCKER, rootless=any('rootless' in s for s in info['SecurityOptions']),
        server_version=info['ServerVersion'], daemon_id=info['ID'], name_on_server=info['Name'])
    transport = dict(schema_version=1, execution_mode='dockerized', interpreter='python3', interpreter_flags=['-B'],
        engine_identity=engine, image_identity=dict(binding='local-image-id', declared_ref=IMAGE,
        image_id=IMAGE, repo_digests=image.get('RepoDigests', []), platform=dict(os=image['Os'], architecture=image['Architecture'])))
    save(out / 'engine.json', info)
    source = out / 'consumer'
    source.mkdir()
    for name, text in [('dune-project', '(lang dune 3.17)\n'),
                       ('dune', '(executable (name probe) (libraries hardcaml_asic.execution unix))\n'),
                       ('probe.ml', CAP_CONSUMER)]:
        with (source / name).open('x') as f:
            f.write(text)
    env = dict(os.environ, OCAMLPATH=m['inputs']['asic_generation'] + '/lib',
        HARDCAML_ASIC_SYNTHESIS_TASK_LIMIT='6', OMP_NUM_THREADS='1', OPENBLAS_NUM_THREADS='1', MKL_NUM_THREADS='1')
    build = ['flock', '/tmp/opencode/asic-pt7-build.lock', 'opam', 'exec', '--switch=5.2.0+ox', '--',
             'dune', 'build', '--root', str(source), '--build-dir', str(out / 'build'), '-j2', 'probe.exe']
    save(out / 'consumer-build.json', dict(argv=build, provider=binding))
    subprocess.run(build, env=env, check=True, timeout=300)
    payload = out / 'payload.py'
    with payload.open('x') as f:
        f.write("import json,time\nfrom pathlib import Path\np=Path('/sys/fs/cgroup')\n"
                "print(json.dumps({k:(p/k).read_text().strip() for k in ['pids.max','pids.current','cpu.max']}),flush=True)\n"
                "time.sleep(4)\n")
    config = dict(binding=transport, payload=str(payload), stdout=str(out / 'native.stdout'),
        stderr=str(out / 'native.stderr'), launch=str(out / 'native-launch.json'), result=str(out / 'native-result.json'))
    save(out / 'native-config.json', config)
    executable = out / 'build/default/probe.exe'
    proc = subprocess.Popen([str(executable), str(out / 'native-config.json')], env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    inspected = None
    try:
        deadline = time.monotonic() + 15
        while inspected is None:
            if proc.poll() is not None:
                raise RuntimeError('installed native transport exited before cap inspection; retain failure, no fallback')
            if time.monotonic() > deadline:
                raise RuntimeError('cap inspection deadline')
            launch_path = out / 'native-launch.json'
            if launch_path.exists():
                argv = json.loads(launch_path.read_text())['argv']
                name = argv[argv.index('--name') + 1]
                p = subprocess.run([DOCKER, 'inspect', name], capture_output=True, text=True, timeout=10)
                if p.returncode == 0:
                    c = json.loads(p.stdout)[0]
                    if c['State']['Running']:
                        inspected = dict(inspect=brief(c), kernel=kernel_limits(c['State']['Pid']))
            if inspected is None:
                time.sleep(.05)
        save(out / 'enforcement.json', inspected)
        stdout, stderr = proc.communicate(timeout=25)
        save(out / 'consumer-exit.json', dict(exit_code=proc.returncode, stdout=stdout, stderr=stderr,
             executable_sha256=digest(executable), source_sha256=digest(source / 'probe.ml')))
        if proc.returncode:
            raise RuntimeError('installed native transport/cgroup probe failed; no fallback')
    finally:
        if proc.poll() is None:
            # Only this metadata consumer; its supervisor owns exact container cleanup.
            proc.terminate()
            proc.communicate(timeout=30)
    kernel = json.loads((out / 'native.stdout').read_text())
    c = inspected['inspect']
    if (c['Image'] != IMAGE or c['HostConfig'].get('PidsLimit') != 6 or
            inspected['kernel']['pids.max'] != '6' or kernel['pids.max'] != '6' or
            c['HostConfig'].get('NanoCpus') != 2_000_000_000 or c['Mounts']):
        raise RuntimeError('effective native metadata envelope differs from requested cap6/quota2/no mounts')
    save(out / 'cap.json', dict(schema_version=1, kind='provider-envelope-cap-receipt-v1',
        binding=binding, established_at_unix=time.time(), cap_enforcement_verified=True,
        verifier_sha256=digest(__file__), probe_cpu_quota=2, execution_cpu_quota=6,
        synthesis_compatibility_tested=False, proof_files={name: digest(out / name) for name in CAP_PROOF_FILES}))
    return True


def verify_cap(path, store, m):
    cap = json.loads(path.read_text())
    if (cap.get('kind') != 'provider-envelope-cap-receipt-v1' or cap.get('schema_version') != 1 or
            cap.get('verifier_sha256') != digest(__file__) or
            cap.get('binding') != cap_binding(store, m) or cap.get('cap_enforcement_verified') is not True or
            not 0 <= time.time() - cap['established_at_unix'] < 3600):
        raise ValueError('cap receipt does not bind the exact fresh provider/capture/SDK/envelope')
    if set(cap['proof_files']) != set(CAP_PROOF_FILES):
        raise ValueError('cap receipt is missing independently hashed proof files')
    for name, expected in cap['proof_files'].items():
        proof = path.parent / name
        if not proof.resolve().is_relative_to(path.parent) or digest(proof) != expected:
            raise ValueError('cap proof bytes changed: ' + name)
    evidence = json.loads((path.parent / 'enforcement.json').read_text())
    native = json.loads((path.parent / 'native-result.json').read_text())
    consumer = json.loads((path.parent / 'consumer-exit.json').read_text())
    kernel = json.loads((path.parent / 'native.stdout').read_text())
    launch = json.loads((path.parent / 'native-launch.json').read_text())['argv']
    expected_envelope = dict(schema_version=1, profile='synthesis-total-tasks-v1', total_container_tasks=6,
                             configured_executor_max_workers=6, reduced_usable_executor_concurrency=True)
    if (native.get('succeeded') is not True or native.get('envelope') != expected_envelope or
            native['process'].get('outcome') != 'exited' or native['process'].get('code') != 0 or
            native['process'].get('cleanup_error') is not None or consumer.get('exit_code') != 0 or
            evidence['inspect']['Image'] != IMAGE or
            evidence['inspect']['HostConfig'].get('PidsLimit') != 6 or
            evidence['inspect']['HostConfig'].get('NanoCpus') != 2_000_000_000 or
            evidence['inspect']['HostConfig'].get('Privileged') or evidence['inspect'].get('Mounts') or
            evidence['kernel']['pids.max'] != '6' or kernel['pids.max'] != '6' or
            [a for a in launch if a.startswith('--pids-limit')] != ['--pids-limit=6'] or
            [a for a in launch if a.startswith('--cpus=')] != ['--cpus=2']):
        raise ValueError('cap proof does not demonstrate installed transport plus HostConfig AND kernel task limit6')
    return cap


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
        clear=not competitors and not containers and not any(r.get('unreadable') for r in rows.values()))
    save(out / 'admission.json', result)
    return result['clear']


METADATA = r'''
import hashlib, importlib.metadata, inspect, json, os, shutil, subprocess, resource
from pathlib import Path
from librelane.flows.classic import Classic
from librelane.steps import yosys, openroad
from librelane.common import get_script_dir
def source(obj):
    text=inspect.getsource(obj)
    return dict(source=text, sha256=hashlib.sha256(text.encode()).hexdigest())
tools={}
for name, options in [('yosys',['-V']),('yosys',['-h']),('yosys',['-h','abc']),('yosys-abc',['-h']),
                      ('sta',['-version']),('sta',['-help']),
                      ('verilator',['--version']),('verilator',['--help'])]:
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
scripts={}
script_root=Path(get_script_dir())
for directory in ('yosys', 'pyosys', 'verilator'):
    for path in (script_root/directory).rglob('*'):
        if path.is_file() and path.suffix in ('.py','.tcl'):
            text=path.read_text()
            scripts[str(path.relative_to(script_root))]=dict(source=text,sha256=hashlib.sha256(text.encode()).hexdigest())
print(json.dumps(dict(librelane=importlib.metadata.version('librelane'), tools=tools,
    prefix_sources={s.id:source(s) for s in prefix}, scripts=scripts,
    process_limits=dict(nproc=resource.getrlimit(resource.RLIMIT_NPROC),
        affinity_cpus=sorted(os.sched_getaffinity(0)),
        cgroup={str(p):p.read_text() for p in [Path('/sys/fs/cgroup/cpu.max'),
            Path('/sys/fs/cgroup/pids.max')] if p.exists()}),
    synthesis_methods=methods,
    synthesis_prefix=[dict(id=s.id,implementation=s.get_implementation_id()) for s in prefix],
    sources={name:source(obj) for name,obj in [('synthesis',yosys.Synthesis),
      ('synthesis_command',yosys.Synthesis.get_command),
      ('synthesis_run',yosys.Synthesis.run),
      ('sta_command',openroad.OpenSTAStep.get_command)]},
    environment={k:os.environ.get(k) for k in ['OMP_NUM_THREADS','OPENROAD_THREADS',
        '_OPENLANE_MAX_CORES','OPENBLAS_NUM_THREADS','MKL_NUM_THREADS']})))
'''


ENVELOPE_PROBE = r'''
# Kernel-resource diagnostics only: no flow objects, designs, tool passes or EDA.
import errno, inspect, json, os, resource, sys, threading, subprocess, shutil
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from librelane.steps.step import Step
from librelane.common.toolbox import Toolbox
from librelane.flows.classic import Classic
cg=Path('/sys/fs/cgroup')
def limits():
    return {name:(cg/name).read_text().strip() for name in
        ('cpu.max','cpuset.cpus.effective','pids.max','pids.current','pids.events')}
before=limits()
allowed=sorted(os.sched_getaffinity(0))
os.sched_setaffinity(0, range(os.cpu_count()))
expanded=sorted(os.sched_getaffinity(0))
cap=int(before['pids.max'])
result=dict(before=before, affinity=allowed, attempted_affinity_expansion=expanded,
    nproc=resource.getrlimit(resource.RLIMIT_NPROC),
    sources={name:inspect.getsource(obj) for name,obj in
        [('run_subprocess',Step.run_subprocess),
         ('classic_run',Classic.run),
         ('step_start',Step.start),
         ('process_stats_thread',Step.run_subprocess.__globals__['ProcessStatsThread']),
         ('create_blackbox_model',Toolbox.create_blackbox_model)]})
# Saturation is deliberately limited to <=12 sleeping tasks, even if the proposed
# production envelope is20. Other sessions may still be doing bounded builds.
if cap <= 12:
    release=threading.Event()
    threads=[]
    failure=None
    try:
        for i in range(cap+1):
            t=threading.Thread(target=release.wait)
            try:
                t.start()
                threads.append(t)
            except RuntimeError as exc:
                failure=str(exc)
                break
        result['thread_saturation']=dict(created=len(threads), failure=failure, at_limit=limits())
        try:
            pid=os.fork()
        except OSError as exc:
            result['fork_at_thread_limit']=dict(errno=exc.errno, error=str(exc))
        else:
            if pid==0: os._exit(0)
            os.waitpid(pid,0)
            result['fork_at_thread_limit']=dict(unexpected_success=True)
    finally:
        release.set()
        for t in threads: t.join()
    result['after_threads']=limits()
    children=[]
    fds=[]
    failure=None
    try:
        for i in range(cap+1):
            rd,wr=os.pipe()
            try:
                pid=os.fork()
            except OSError as exc:
                os.close(rd); os.close(wr)
                failure=dict(errno=exc.errno,error=str(exc))
                break
            if pid==0:
                os.close(wr)
                os.read(rd,1)
                os._exit(0)
            os.close(rd)
            children.append(pid); fds.append(wr)
        result['process_saturation']=dict(created=len(children),failure=failure,at_limit=limits())
    finally:
        for fd in fds: os.write(fd,b'x'); os.close(fd)
        for pid in children: os.waitpid(pid,0)
    # Demonstrate the compatibility cost of a strict total-task limit6:
    # a controller plus a fully occupied six-thread executor already needs7.
    release=threading.Event()
    pool=ThreadPoolExecutor(max_workers=6)
    futures=[]
    failure=None
    try:
        for i in range(6):
            try: futures.append(pool.submit(release.wait))
            except RuntimeError as exc:
                failure=str(exc); break
        result['six_executor_slots']=dict(submitted=len(futures), failure=failure, occupied=limits())
    finally:
        release.set(); pool.shutdown(wait=True)
    # Exercise the exact subprocess/statistics scaffolding with Python metadata,
    # without constructing any Step/Config/Flow or invoking any design operation.
    from types import SimpleNamespace
    directory=Path('/tmp/controller-probe')
    directory.mkdir()
    dummy=SimpleNamespace(step_dir=str(directory),output_processors=[],
        get_log_path=lambda:str(directory/'metadata.log'))
    scaffold=Step.run_subprocess(dummy,[sys.executable,'-B','-c',
        "import json,time; from pathlib import Path; time.sleep(.05); "
        "print(json.dumps({k:(Path('/sys/fs/cgroup')/k).read_text().strip() "
        "for k in ['pids.current','pids.max','cpuset.cpus.effective']}))"], silent=True)
    result['subprocess_scaffold']=dict(returncode=scaffold['returncode'],
        output=(directory/'metadata.log').read_text(),
        stats=json.loads((directory/'metadata.process_stats.json').read_text()))
    tools={}
    for tool,args in [('yosys',['-V']),('yosys-abc',['-h']),('sta',['-version']),
                      ('verilator',['--verilate-jobs','1','--version'])]:
        path=shutil.which(tool)
        proc=subprocess.run([path,*args],capture_output=True,text=True,timeout=10)
        tools[tool]=dict(argv=[path,*args],exit_code=proc.returncode,stdout=proc.stdout,stderr=proc.stderr)
    result['native_metadata']=tools
result['after']=limits()
print('ENVELOPE_RESULT='+json.dumps(result))
'''


def envelope_probe(out):
    """Prove cpuset/task-controller semantics; never authorize implementation."""
    info = json.loads(command([DOCKER, 'info', '--format', '{{json .}}']))
    save(out / 'engine.json', info)
    if info.get('Name') != os.uname().nodename or info.get('CgroupVersion') != '2':
        raise RuntimeError('probe requires the local cgroup-v2 Docker engine')
    if not all(info.get(k) for k in ('CPUSet', 'PidsLimit', 'CpuCfsQuota')):
        raise RuntimeError('engine lacks required envelope controllers')
    cpus = sorted(os.sched_getaffinity(0))[:2]
    if len(cpus) != 2:
        raise RuntimeError('probe requires two available CPUs')
    passed = True
    for task_cap in (6, 12, 20):
        name = 'workbench-envelope-metadata-' + os.urandom(8).hex()
        argv = [DOCKER, 'run', '--rm', '--pull=never', '--network=none', '--read-only',
                '--cpus=2', '--cpuset-cpus=' + ','.join(map(str, cpus)),
                '--pids-limit=' + str(task_cap), '--cap-drop=ALL',
                '--security-opt=no-new-privileges', '--name', name,
                '--tmpfs', '/tmp:rw,noexec,nosuid,size=32m']
        for key in (*LIMIT_ENV, 'STA_THREADS', 'OPENBLAS_NUM_THREADS', 'MKL_NUM_THREADS'):
            argv += ['-e', key + '=1']
        argv += ['--entrypoint', 'python3', IMAGE, '-B', '-c', ENVELOPE_PROBE]
        prefix = str(task_cap)
        save(out / (prefix + '-request.json'), dict(argv=argv, eda_launches=0,
             metadata_cpus=2, total_tasks_cap=task_cap, saturation_attempted=task_cap <= 12))
        try:
            proc = subprocess.run(argv, capture_output=True, text=True, timeout=60)
            raw = proc.stdout
            with (out / (prefix + '-stdout.txt')).open('x') as f:
                f.write(raw)
            with (out / (prefix + '-stderr.txt')).open('x') as f:
                f.write(proc.stderr)
            save(out / (prefix + '-exit.json'), dict(exit_code=proc.returncode))
            if proc.returncode:
                raise RuntimeError('kernel probe exited nonzero: ' + prefix)
            results = [line.removeprefix('ENVELOPE_RESULT=') for line in raw.splitlines()
                       if line.startswith('ENVELOPE_RESULT=')]
            if len(results) != 1:
                raise RuntimeError('missing/ambiguous kernel probe result')
            value = json.loads(results[0])
            save(out / (prefix + '-result.json'), value)
            for key, text in value['sources'].items():
                with (out / (prefix + '-' + key + '.txt')).open('x') as f:
                    f.write(text)
            checks = dict(affinity_restricted=value['affinity'] == cpus == value['attempted_affinity_expansion'],
                          exact_pids_max=value['before']['pids.max'] == prefix,
                          exact_cpu_quota=value['before']['cpu.max'] == '200000 100000',
                          tasks_recovered=value['after']['pids.current'] == '1')
            if task_cap <= 12:
                checks.update(thread_creation_denied=value['thread_saturation']['failure'] is not None,
                    threads_counted=int(value['thread_saturation']['at_limit']['pids.current']) == task_cap,
                    fork_denied_at_thread_limit=value['fork_at_thread_limit'].get('errno') == 11,
                    process_creation_denied=value['process_saturation']['failure']['errno'] == 11,
                    processes_counted=int(value['process_saturation']['at_limit']['pids.current']) == task_cap,
                    kernel_denials_recorded=int(value['after']['pids.events'].split()[1]) >
                                            int(value['before']['pids.events'].split()[1]),
                    controllers_consume_task_budget=(value['six_executor_slots']['submitted'] < 6
                        if task_cap == 6 else value['six_executor_slots']['submitted'] == 6),
                    subprocess_scaffold_works=value['subprocess_scaffold']['returncode'] == 0,
                    native_metadata_works=all(v['exit_code'] == (1 if k == 'yosys-abc' else 0)
                                              for k,v in value['native_metadata'].items()))
            save(out / (prefix + '-checks.json'), checks)
            passed &= all(checks.values())
        finally:
            p = subprocess.run([DOCKER, 'rm', '-f', name], capture_output=True, text=True, timeout=15)
            save(out / (prefix + '-cleanup.json'), dict(argv=p.args, exit_code=p.returncode,
                 stdout=p.stdout, stderr=p.stderr))
    save(out / 'envelope-summary.json', dict(probe_checks_passed=passed,
         runtime_ceiling_established=False, synthesis_compatibility_tested=False,
         reason='Production transport installation and contract approval remain separate prerequisites.'))
    return passed


def metadata(out, asic=None):
    # No mounts, no flow construction/start, no scripts/designs supplied to tools.
    name = 'workbench-resource-metadata-' + os.urandom(8).hex()
    argv = [DOCKER, 'run', '--rm', '--pull=never', '--network=none', '--read-only',
            '--cpus=2', '--pids-limit=128', '--name', name,
            '--tmpfs', '/tmp:rw,noexec,nosuid,size=32m']
    for key in (*LIMIT_ENV, 'STA_THREADS', 'OPENBLAS_NUM_THREADS', 'MKL_NUM_THREADS'):
        argv += ['-e', key + '=2']
    argv += ['--entrypoint', 'python3', IMAGE, '-B', '-c', METADATA]
    save(out / 'metadata-request.json', dict(argv=argv, image=IMAGE, eda_launches=0,
         metadata_cpus=2, maximum_thread_environment=2))
    save(out / 'image.json', json.loads(command([DOCKER, 'image', 'inspect', IMAGE])))
    if asic is not None:
        asic = asic.resolve(strict=True)
        if asic.name != GENERATION:
            raise ValueError('unexpected provider generation')
        helper = asic / 'lib/hardcaml_asic/flow/hardcaml_asic_flow'
        execution = asic / 'lib/hardcaml_asic/execution'
        runtime_sources = [execution / 'runtime' / name for name in
                           ('execution_transport.ml', 'process_supervisor.ml', 'runtime_probe.ml')]
        runtime_sources += [execution / 'backends/librelane' / name for name in
                            ('segment_service.ml', 'named_stage_service.ml')]
        files = [asic / 'receipt.json', *sorted((asic / 'bin').iterdir()), *sorted(helper.glob('*.py')),
                 *runtime_sources]
        save(out / 'provider.json', dict(generation=str(asic), receipt=json.loads((asic / 'receipt.json').read_text()),
             files={str(p.relative_to(asic)): digest(p) for p in files if p.is_file()}))
        for path in runtime_sources:
            if path.is_file():
                with (out / ('installed-' + path.name + '.txt')).open('x') as f:
                    f.write(path.read_text())
    try:
        raw = command(argv, timeout=120)
        value = json.loads(raw)
        save(out / 'metadata.json', value)
        # Also retain readable source files: JSON strings obscure long methods.
        sources = out / 'imported-sources'
        sources.mkdir()
        for group in ('prefix_sources', 'synthesis_methods', 'sources', 'scripts'):
            for key, record in value[group].items():
                with (sources / (group + '-' + key.replace('/', '_') + '.txt')).open('x') as f:
                    f.write(record['source'])
        for key, record in value['tools'].items():
            for stream in ('stdout', 'stderr'):
                with (sources / ('tool-' + key.replace(' ', '_') + '-' + stream + '.txt')).open('x') as f:
                    f.write(record.get(stream, ''))
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
    manifest = store / 'manifest.json'
    m = capture(store)
    cap = verify_cap(args.cap_receipt.resolve(strict=True), store, m)
    engine = json.loads(command([DOCKER, 'info', '--format', '{{json .}}']))
    cap_engine = json.loads((args.cap_receipt.parent / 'engine.json').read_text())
    if any(engine.get(key) != cap_engine.get(key) for key in ('ID', 'Name', 'ServerVersion', 'CgroupVersion')):
        raise ValueError('Docker engine changed since independent cap proof')
    cap_hash = digest(args.cap_receipt)
    manifest_hash = digest(manifest)
    activation = json.loads(args.activation.read_text())
    required = dict(schema_version=2, allocation=6, endpoint='synthesis',
                    store=str(store), manifest_sha256=digest(manifest), activated=True,
                    cap_receipt_sha256=cap_hash, profile='synthesis-total-tasks-v1', total_container_tasks=6)
    if any(activation.get(k) != v for k, v in required.items()):
        raise ValueError('coordinator activation must match ' + json.dumps(required))
    stamp = activation['activated_at_unix']
    if not isinstance(stamp, (int, float)) or not math.isfinite(stamp) or not 0 <= time.time() - stamp < 300:
        raise ValueError('activation is not fresh (maximum 300 seconds)')
    if Path(m['inputs']['asic_generation']).name != GENERATION:
        raise ValueError('unexpected provider generation')
    bridge = Path(m['inputs']['asic_generation']) / 'lib/hardcaml_asic/flow/hardcaml_asic_flow/librelane_bridge.py'
    helper = bridge.parent
    text = bridge.read_text()
    if 'ThreadPoolExecutor(max_workers=6)' not in text or '"STA_THREADS=1"' not in text:
        raise ValueError('unexpected installed bridge resource contract')
    save(out / 'activation.json', activation)
    save(out / 'bridge.json', dict(path=str(bridge), sha256=digest(bridge),
         executor_max_workers=6, sta_corner_workers=1,
         note='Configured executor ceiling, not a count of active or native OS threads.'))
    if not audit(out):
        raise RuntimeError('admission blocked: competing workers or running containers')
    identity = processes()[os.getpid()]
    save(out / 'ready.json', dict(schema_version=2, ready=True, pid=os.getpid(),
         monitor_start_ticks=identity['start_ticks'], start_ticks=identity['start_ticks'],
         store=str(store), manifest_sha256=manifest_hash, allocation=6, workers=6,
         endpoint='synthesis', asic_generation=m['inputs']['asic_generation'],
         activation_sha256=digest(args.activation), image=IMAGE,
         verifier_sha256=digest(__file__), profile='synthesis-total-tasks-v1', total_container_tasks=6,
         cap_receipt=str(args.cap_receipt.resolve()), cap_receipt_sha256=cap_hash,
         cap_binding=cap['binding'], runtime_ceiling_established=True,
         readiness_scope='strict total-container-task<=6 profile; installed transport, HostConfig and kernel proof hash-bound; synthesis success untested'))
    known, previous, peaks = {}, {}, dict(native_os_threads=0, native_runnable_threads=0,
        native_cpu_progress_threads=0, native_processes=0, python_os_threads=0)
    seen_flow = False
    flow_container = None
    seen_container = False
    started = time.monotonic()
    samples = 0
    with (out / 'samples.jsonl').open('x', buffering=1) as log:
        while True:
            if time.monotonic() - started > args.timeout:
                raise RuntimeError('monitor deadline exceeded; acceptance owner must cancel')
            containers = running()
            rows = processes()
            finishing = args.finish.exists()
            if digest(manifest) != manifest_hash or digest(store / 'selected/manifest.json') != manifest_hash:
                raise RuntimeError('selected capture changed during observation')
            if any(row.get('unreadable') for row in rows.values()):
                raise RuntimeError('unreadable processes prevent admission accounting')
            if finishing and containers:
                raise RuntimeError('finish requested with running container')
            accepted = []
            excluded = descendants(rows, os.getpid())
            native_count = runnable = progressing = native_threads = 0
            for c in containers:
                # Mountless metadata containers are associated by the exact same-store
                # launch receipt and pinned payload, never by their name alone.
                kind = container_kind(c, helper, store)
                log.write(json.dumps(dict(time_unix=time.time(), kind='docker-inspect',
                     inspect=brief(c))) + '\n')
                errors = validate_container(c, store, metadata_only=kind == 'metadata')
                if errors:
                    raise RuntimeError(c['Name'] + ': ' + '; '.join(errors))
                cid = c['Id']
                if cid not in known:
                    record = launch_record(store, c['Name'].lstrip('/'), c['Args'])
                    save(out / (cid + '-inspect.json'), dict(inspect=brief(c), launch=record))
                    known[cid] = c['Name']
                is_flow = kind == 'flow'
                if is_flow:
                    if flow_container is not None and flow_container != cid:
                        raise RuntimeError('second synthesis execution container in one observation')
                    flow_container = cid
                    seen_flow = True
                if c['State']['Pid'] not in rows:
                    raise RuntimeError('owned container root process missing from snapshot; retry with fresh observation')
                limits = kernel_limits(c['State']['Pid'])
                log.write(json.dumps(dict(time_unix=time.time(), kind='kernel-enforcement', container_id=cid, limits=limits)) + '\n')
                if limits['pids.max'] != '6' or int(limits['pids.current']) > 6:
                    raise RuntimeError('effective owned kernel task bound is not six')
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
                    if base in {'python3', 'python3.13'}:
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
            seen_container |= bool(accepted)
            if len(accepted) > 1:
                raise RuntimeError('overlapping owned containers')
            competitors = workers(rows, excluded)
            preparing = [] if seen_container or finishing else preparation_workers(
                rows, competitors, store, m['inputs']['dune'])
            competitors = [r for r in competitors if r not in preparing]
            if competitors:
                raise RuntimeError('competing build/native work: ' + json.dumps(competitors))
            if native_threads > 6 or runnable > 6 or progressing > 6:
                raise RuntimeError('aggregate native thread budget exceeded')
            for key, value in [('native_os_threads', native_threads), ('native_processes', native_count),
                               ('native_runnable_threads', runnable), ('native_cpu_progress_threads', progressing)]:
                peaks[key] = max(peaks[key], value)
            log.write(json.dumps(dict(time_unix=time.time(), containers=accepted,
                 native_os_threads=native_threads, native_runnable_threads=runnable,
                 native_cpu_progress_threads=progressing, preparing_workers=preparing,
                 competing_workers=competitors)) + '\n')
            samples += 1
            if finishing:
                break
            time.sleep(args.interval)
    if running():
        raise RuntimeError('finish requested with container still running')
    if not seen_flow:
        raise RuntimeError('finish without an observed execute_segment container')
    save(out / 'summary.json', dict(completed=True, seen_flow=seen_flow, samples=samples,
          store=str(store), manifest_sha256=manifest_hash, runtime_ceiling_established=True,
          cap_receipt=str(args.cap_receipt.resolve()), cap_receipt_sha256=cap_hash, cap_binding=cap['binding'],
         containers=known, peaks=peaks, interval_seconds=args.interval,
         limitations=['Sampling can miss short processes/threads and is not exhaustive peak proof.',
             'CPU-progress threads in one interval need not have run simultaneously.',
             'Python OS threads include idle executor/controller threads; not native worker count.',
              'Kernel total-task bound includes controllers; six usable executor slots are not promised.',
              'Synthesis success and report acceptance are independently verified by the acceptance harness.']))
    return seen_flow


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('mode', choices=('audit', 'metadata', 'envelope-probe', 'cap-probe', 'watch'))
    p.add_argument('--evidence', type=Path, required=True)
    p.add_argument('--store', type=Path)
    p.add_argument('--activation', type=Path)
    p.add_argument('--finish', type=Path)
    p.add_argument('--cap-receipt', type=Path)
    p.add_argument('--asic-generation', type=Path, help='metadata only: retain installed provider hashes')
    p.add_argument('--interval', type=float, default=.25)
    p.add_argument('--timeout', type=float, default=900)
    args = p.parse_args()
    if args.mode == 'watch' and not all((args.store, args.activation, args.finish, args.cap_receipt)):
        p.error('watch requires --store, --activation, --finish and --cap-receipt')
    if args.mode == 'cap-probe' and not args.store:
        p.error('cap-probe requires --store')
    if not .1 <= args.interval <= 1 or not 1 <= args.timeout <= 3600:
        p.error('interval must be .1..1 and timeout 1..3600')
    out = args.evidence.resolve()
    if not out.is_relative_to(Path('/tmp/opencode')):
        p.error('evidence must be a fresh directory under /tmp/opencode')
    out.mkdir()  # Never overwrite a previous monitoring attempt.
    save(out / 'observer.json', dict(script=str(Path(__file__).resolve()), sha256=digest(__file__),
         argv=sys.argv, image=IMAGE, mode=args.mode, started_at_unix=time.time()))
    try:
        if args.mode == 'audit':
            ok = audit(out)
        elif args.mode == 'metadata':
            ok = metadata(out, args.asic_generation)
        elif args.mode == 'envelope-probe':
            ok = envelope_probe(out)
        elif args.mode == 'cap-probe':
            ok = cap_probe(args, out)
        else:
            ok = watch(args, out)
        return 0 if ok else 2
    except Exception as exc:
        save(out / 'stop-request.json', dict(reason=str(exc), time_unix=time.time(),
             action='acceptance harness must cancel only its exact test-owned workflow',
             observer_sent_signals=False))
        print(str(exc), file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
