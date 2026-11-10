#!/usr/bin/env python3
"""Resource observer negative controls. No Docker, EDA, Dune or retained-state writes."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('resources', Path(__file__).with_name('developer-workflow-resources.py'))
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)


class Controls(unittest.TestCase):
    def setUp(self):
        self.store = Path('/tmp/opencode/resource-control-store')
        self.c = dict(Image=r.IMAGE, Name='/hardcaml-asic-execution-' + 'a' * 32,
            HostConfig=dict(NanoCpus=6_000_000_000, CpuQuota=0, PidsLimit=6),
            Config=dict(Env=[key + '=6' for key in r.LIMIT_ENV]),
            Mounts=[dict(Type='bind', Source=str(self.store / 'work'), Destination=str(self.store / 'work'), RW=True),
                    dict(Type='bind', Source='/readonly/pdk', Destination='/readonly/pdk', RW=False)])

    def test_six_is_admitted(self):
        self.assertEqual(r.validate_container(self.c, self.store), [])

    def test_quota_two_is_not_relabelled_six(self):
        self.c['HostConfig']['NanoCpus'] = 2_000_000_000
        self.assertTrue(r.validate_container(self.c, self.store))

    def test_quota_expansion_and_unlimited_reject(self):
        for cpus in (0, 7_000_000_000, 20_000_000_000):
            with self.subTest(cpus=cpus):
                self.c['HostConfig']['NanoCpus'] = cpus
                self.assertTrue(r.validate_container(self.c, self.store))

    def test_missing_duplicate_or_expanded_environment_reject(self):
        for env in ([], ['OMP_NUM_THREADS=20'], self.c['Config']['Env'] + ['OMP_NUM_THREADS=6']):
            with self.subTest(env=env):
                c = copy.deepcopy(self.c)
                c['Config']['Env'] = env
                self.assertTrue(r.validate_container(c, self.store))

    def test_owner_or_sibling_mount_is_not_owned(self):
        for root in ('/home/wayne/devel/jane/hardcaml_asic_example', str(self.store) + '-other'):
            self.c['Mounts'][0]['Source'] = root
            self.assertFalse(r.owned(self.c, self.store))
            self.assertTrue(r.validate_container(self.c, self.store))

    def test_external_writable_mount_rejects(self):
        self.c['Mounts'][1]['RW'] = True
        self.assertTrue(r.validate_container(self.c, self.store))

    def test_unknown_image_or_name_rejects(self):
        for field, value in [('Image', 'wrong'), ('Name', '/owner-daemon')]:
            c = copy.deepcopy(self.c)
            c[field] = value
            self.assertTrue(r.validate_container(c, self.store))

    def test_prompt_tool_mentions_are_not_worker_processes(self):
        rows = {1: dict(pid=1, ppid=0, argv=['opencode', 'run dune yosys build'], comm='opencode'),
                2: dict(pid=2, ppid=1, argv=['/bin/dune', 'build', '-j2'], comm='dune'),
                3: dict(pid=3, ppid=2, argv=['/bin/ocamlopt', 'x.ml'], comm='ocamlopt')}
        self.assertEqual([p['pid'] for p in r.workers(rows)], [2, 3])
        self.assertEqual(r.descendants(rows, 2), {2, 3})
        self.assertEqual(r.workers(rows, r.descendants(rows, 2)), [])

    def test_native_limits_and_nix_wrappers(self):
        self.assertEqual(r.executable_name('/nix/store/x/bin/.yosys-wrapped'), 'yosys')
        self.assertEqual(r.native_limits(['sta', '-threads', '1', '-exit']), [])
        self.assertEqual(r.native_limits(['yosys', '-y', 'synthesize.py']), [])
        for argv in (['sta', '-exit'], ['sta', '-threads', 'max'], ['yosys', '-j20'],
                     ['verilator', '--threads=20'], ['verilator', '--verilate-jobs', '0'],
                     ['verilator', '--hierarchical-threads=20'], ['verilator', '--trace-threads', '20'],
                     ['verilator', '--build-jobs=20'], ['abc', '--jobs', '0']):
            with self.subTest(argv=argv):
                self.assertTrue(r.native_limits(argv))

    def test_mountless_metadata_is_not_a_flow(self):
        self.c['Mounts'] = []
        self.c['HostConfig'].update(ReadonlyRootfs=True, NetworkMode='none')
        self.c['Config']['Env'] = ['_OPENLANE_MAX_CORES=6', 'OMP_NUM_THREADS=6']
        self.assertEqual(r.validate_container(self.c, self.store, metadata_only=True), [])
        self.assertTrue(r.validate_container(self.c, self.store))
        self.c['HostConfig']['ReadonlyRootfs'] = False
        self.assertTrue(r.validate_container(self.c, self.store, metadata_only=True))

    def test_privileged_transport_rejected(self):
        for key, value in [('Privileged', True), ('PidMode', 'host'), ('CapAdd', ['SYS_ADMIN'])]:
            with self.subTest(key=key):
                c = copy.deepcopy(self.c)
                c['HostConfig'][key] = value
                self.assertTrue(r.validate_container(c, self.store))

    def test_remapped_bind_and_duplicate_optional_cap_reject(self):
        self.c['Mounts'][0]['Destination'] = '/other'
        self.assertTrue(r.validate_container(self.c, self.store))
        self.c['Mounts'][0]['Destination'] = self.c['Mounts'][0]['Source']
        self.c['Config']['Env'] += ['STA_THREADS=20', 'STA_THREADS=1']
        self.assertTrue(r.validate_container(self.c, self.store))


class Handshake(unittest.TestCase):
    """Exercise real observer files/loop with synthetic Docker/proc snapshots."""
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='resource-controls-', dir='/tmp/opencode')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.store = self.root / 'store'
        generation = self.store / 'generations/capture'
        generation.mkdir(parents=True)
        (self.store / 'selected').symlink_to(generation)
        self.helper = self.root / r.GENERATION / 'lib/hardcaml_asic/flow/hardcaml_asic_flow'
        self.helper.mkdir(parents=True)
        self.bridge = self.helper / 'librelane_bridge.py'
        self.bridge.write_text('ThreadPoolExecutor(max_workers=6)\n"STA_THREADS=1"\n')
        (self.helper / 'stage_metadata_probe.py').write_text('import json\n')
        asic = self.root / r.GENERATION
        (asic / 'receipt.json').write_text('{}')
        sdk = generation / 'sdk/lib/fixture'
        sdk.parent.mkdir(parents=True)
        sdk.write_text('fixture SDK')
        manifest = dict(source_layout='ownership-v1', max_jobs=2, store=str(self.store),
            project_root=str(self.store / 'project'), generation=str(generation),
            inputs=dict(asic_generation=str(asic), dune='/bin/dune'), asic_receipt_sha256=r.digest(asic / 'receipt.json'),
            asic_files={str(self.bridge.relative_to(asic)): r.digest(self.bridge)},
            environment={'HARDCAML_ASIC_SYNTHESIS_TASK_LIMIT': '6'},
            captured_files={'sdk/lib/fixture': r.digest(sdk)})
        for path in (self.store / 'manifest.json', generation / 'manifest.json'):
            path.write_text(json.dumps(manifest))
        self.finish = self.root / 'finish'
        self.engine = dict(ID='fixture-engine', Name='fixture-host', ServerVersion='fixture', CgroupVersion='2')
        cap_dir = self.root / 'cap'
        cap_dir.mkdir()
        for name in r.CAP_PROOF_FILES:
            path = cap_dir / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('synthetic fixture proof')
        for name, value in {'engine.json': self.engine,
            'enforcement.json': dict(inspect=dict(Image=r.IMAGE, Mounts=[], HostConfig=dict(PidsLimit=6, NanoCpus=2_000_000_000)), kernel={'pids.max': '6'}),
            'native-result.json': dict(succeeded=True, process=dict(outcome='exited', code=0, cleanup_error=None),
                envelope=dict(schema_version=1, profile='synthesis-total-tasks-v1', total_container_tasks=6,
                              configured_executor_max_workers=6, reduced_usable_executor_concurrency=True)),
            'consumer-exit.json': dict(exit_code=0), 'native.stdout': {'pids.max': '6'},
            'native-launch.json': dict(argv=[r.DOCKER, 'run', '--pids-limit=6', '--cpus=2', r.IMAGE])}.items():
            (cap_dir / name).write_text(json.dumps(value))
        self.cap_path = cap_dir / 'cap.json'
        self.cap = dict(schema_version=1, kind='provider-envelope-cap-receipt-v1',
            binding=r.cap_binding(self.store, manifest), established_at_unix=time.time(),
            verifier_sha256=r.digest(r.__file__),
            cap_enforcement_verified=True, synthesis_compatibility_tested=False)
        self.rehash_cap()
        activation = self.root / 'activation.json'
        activation.write_text(json.dumps(dict(schema_version=2, allocation=6, endpoint='synthesis',
            store=str(self.store), manifest_sha256=r.digest(self.store / 'manifest.json'),
            cap_receipt_sha256=r.digest(self.cap_path), profile='synthesis-total-tasks-v1', total_container_tasks=6,
            activated=True, activated_at_unix=time.time())))
        self.args = SimpleNamespace(store=self.store, finish=self.finish, activation=activation,
                                    interval=.1, timeout=10, cap_receipt=self.cap_path)
        self.out = self.root / 'evidence'
        self.out.mkdir()
        work = self.store / 'different-result-layout/work'
        work.mkdir(parents=True)
        staged = work / 'librelane_bridge.py'
        staged.write_bytes(self.bridge.read_bytes())
        self.request = work / 'request.json'
        self.request.write_text(json.dumps(dict(boundary='synthesis', checkpoint=None, operation='execute_segment')))
        self.c = dict(Id='a' * 64, Image=r.IMAGE, Name='/hardcaml-asic-execution-' + 'b' * 32,
            Path='python3', Args=['-I', '-B', str(staged), str(self.request)], State=dict(Pid=999999),
            HostConfig=dict(NanoCpus=6_000_000_000, CpuQuota=0, PidsLimit=6),
            Config=dict(Env=[key + '=6' for key in r.LIMIT_ENV]),
            Mounts=[dict(Type='bind', Source=str(work), Destination=str(work), RW=True)])
        self.receipt = work / 'launch.json'
        self.write_receipt()
        self.rows = {os.getpid(): dict(pid=os.getpid(), ppid=0, start_ticks=123,
                       argv=['python3'], comm='python3'),
                     999999: dict(pid=999999, ppid=0, start_ticks=456,
                       argv=['python3'], comm='python3', os_threads=1)}

    def write_receipt(self):
        self.receipt.write_text(json.dumps(dict(argv=[r.DOCKER, 'run', '--name',
            self.c['Name'][1:], r.IMAGE, *self.c['Args']])))

    def rehash_cap(self):
        self.cap['proof_files'] = {name: r.digest(self.cap_path.parent / name) for name in r.CAP_PROOF_FILES}
        self.cap_path.write_text(json.dumps(self.cap))

    def run_watch(self, containers=None, rows=None, sleep=None):
        rows = rows or self.rows
        snapshots = iter([{pid: row for pid, row in rows.items() if pid not in r.descendants(rows, 999999)}, rows])
        with patch.object(r, 'running', side_effect=containers or [[], [self.c], [], []]), \
             patch.object(r, 'processes', side_effect=lambda: next(snapshots, rows)), \
             patch.object(r, 'tasks', return_value=[]), \
             patch.object(r, 'command', return_value=json.dumps(self.engine)), \
             patch.object(r, 'kernel_limits', return_value={'pids.max': '6', 'pids.current': '1'}), \
             patch.object(r.time, 'sleep', side_effect=sleep or (lambda _: self.finish.touch())):
            return r.watch(self.args, self.out)

    def test_complete_handshake_and_exact_receipt(self):
        self.assertTrue(self.run_watch())
        ready = json.loads((self.out / 'ready.json').read_text())
        self.assertEqual(ready['monitor_start_ticks'], 123)
        self.assertEqual(ready['asic_generation'], str(self.root / r.GENERATION))
        self.assertTrue(ready['runtime_ceiling_established'])
        self.assertEqual(ready['cap_receipt_sha256'], r.digest(self.cap_path))
        summary = json.loads((self.out / 'summary.json').read_text())
        self.assertTrue(summary['seen_flow'])
        self.assertTrue(summary['runtime_ceiling_established'])

    def test_finish_cannot_bypass_final_competition_check(self):
        def competing(_):
            self.finish.touch()
            self.rows[77] = dict(pid=77, ppid=0, argv=['make', '-j20'], comm='make', cwd=str(self.store))
        with self.assertRaisesRegex(RuntimeError, 'competing build'):
            self.run_watch(sleep=competing)
        self.assertFalse((self.out / 'summary.json').exists())

    def test_finish_with_live_container_rejects(self):
        with self.assertRaisesRegex(RuntimeError, 'finish requested'):
            self.run_watch(containers=[[], [self.c], [self.c]])

    def test_finish_without_execute_is_failure(self):
        with self.assertRaisesRegex(RuntimeError, 'without an observed'):
            self.run_watch(containers=[[], [], [], []])

    def test_competing_nested_build_not_exempted_by_cwd(self):
        self.rows[77] = dict(pid=77, ppid=0, argv=['make', '-j20'], comm='make', cwd=str(self.store))
        with self.assertRaisesRegex(RuntimeError, 'admission blocked'):
            self.run_watch()
        self.assertFalse((self.out / 'ready.json').exists())

    def test_missing_or_forged_receipt_rejects(self):
        self.receipt.unlink()
        with self.assertRaisesRegex(RuntimeError, 'no pre-existing'):
            r.launch_record(self.store, self.c['Name'][1:], self.c['Args'])
        self.write_receipt()
        with self.assertRaisesRegex(RuntimeError, 'payload/image mismatch'):
            r.launch_record(self.store, self.c['Name'][1:], ['-c', 'arbitrary code'])

    def test_probe_role_is_not_sufficient_to_admit_code(self):
        self.c['Args'] = ['-I', '-B', '-c', 'arbitrary code', 'container']
        self.write_receipt()
        with self.assertRaisesRegex(RuntimeError, 'unknown owned container command'):
            self.run_watch()

    def test_mountless_probe_bound_to_exact_receipt(self):
        self.c['Args'] = ['-I', '-B', '-c', (self.helper / 'stage_metadata_probe.py').read_text(), 'metadata-container']
        self.c['Mounts'] = []
        self.c['HostConfig'].update(ReadonlyRootfs=True, NetworkMode='none')
        self.write_receipt()
        with self.assertRaisesRegex(RuntimeError, 'without an observed'):
            self.run_watch()
        self.assertTrue((self.out / (self.c['Id'] + '-inspect.json')).exists())

    def test_publication_is_not_execution(self):
        self.request.write_text(json.dumps(dict(boundary='synthesis', checkpoint=None, operation='validate_publication')))
        with self.assertRaisesRegex(RuntimeError, 'without an observed'):
            self.run_watch()

    def test_second_execution_is_rejected_even_without_overlap(self):
        second = copy.deepcopy(self.c)
        second.update(Id='c' * 64, Name='/hardcaml-asic-execution-' + 'd' * 32)
        other = self.receipt.with_name('second-launch.json')
        other.write_text(json.dumps(dict(argv=[r.DOCKER, 'run', '--name', second['Name'][1:],
                                              r.IMAGE, *second['Args']])))
        with self.assertRaisesRegex(RuntimeError, 'second synthesis execution'):
            self.run_watch(containers=[[], [self.c], [second]], sleep=lambda _: None)

    def test_modified_pin_historical_layout_or_selection_rejected(self):
        self.bridge.write_text('changed')
        with self.assertRaisesRegex(ValueError, 'provider capture bytes changed'):
            r.capture(self.store)
        manifest = json.loads((self.store / 'manifest.json').read_text())
        manifest['source_layout'] = 'historical'
        (self.store / 'manifest.json').write_text(json.dumps(manifest))
        with self.assertRaisesRegex(ValueError, 'ownership-v1'):
            r.capture(self.store)

    def test_activation_expired_future_or_nonfinite_rejected(self):
        original = json.loads(self.args.activation.read_text())
        for stamp in (time.time() - 301, time.time() + 60, float('nan'), float('inf')):
            with self.subTest(stamp=stamp):
                self.args.activation.write_text(json.dumps({**original, 'activated_at_unix': stamp}))
                with self.assertRaisesRegex(ValueError, 'activation is not fresh'):
                    self.run_watch()
                self.assertFalse((self.out / 'ready.json').exists())

    def test_selected_capture_change_after_ready_rejected(self):
        def change_capture(_):
            (self.store / 'manifest.json').write_text('{}')
        with self.assertRaisesRegex(RuntimeError, 'selected capture changed'):
            self.run_watch(containers=[[], [self.c], []], sleep=change_capture)
        self.assertTrue((self.out / 'ready.json').exists())
        self.assertFalse((self.out / 'summary.json').exists())

    def test_expanded_aggregate_native_threads_reject(self):
        for pid in (88, 89):
            self.rows[pid] = dict(pid=pid, ppid=999999, start_ticks=pid,
                argv=['yosys'], comm='yosys', os_threads=4)
        with self.assertRaisesRegex(RuntimeError, 'aggregate native thread budget'):
            self.run_watch()

    def test_main_failure_publishes_stop_without_ready(self):
        self.args.activation.write_text('{}')
        evidence = self.root / 'main-evidence'
        with patch.object(r.sys, 'argv', ['observer', 'watch', '--store', str(self.store),
            '--activation', str(self.args.activation), '--finish', str(self.finish), '--evidence', str(evidence),
            '--cap-receipt', str(self.cap_path)]), patch.object(r, 'command', return_value=json.dumps(self.engine)):
            self.assertEqual(r.main(), 2)
        self.assertTrue((evidence / 'stop-request.json').exists())
        self.assertFalse((evidence / 'ready.json').exists())

    def test_main_violation_after_ready_publishes_stop_and_no_summary(self):
        evidence = self.root / 'main-evidence'
        self.c['HostConfig']['NanoCpus'] = 2_000_000_000
        with patch.object(r.sys, 'argv', ['observer', 'watch', '--store', str(self.store),
            '--activation', str(self.args.activation), '--finish', str(self.finish), '--evidence', str(evidence),
            '--cap-receipt', str(self.cap_path)]), \
             patch.object(r, 'running', side_effect=[[], [self.c]]), \
             patch.object(r, 'command', return_value=json.dumps(self.engine)), \
             patch.object(r, 'processes', return_value=self.rows):
            self.assertEqual(r.main(), 2)
        self.assertTrue((evidence / 'ready.json').exists())
        stop = json.loads((evidence / 'stop-request.json').read_text())
        self.assertIn('exact six-CPU', stop['reason'])
        self.assertFalse(stop['observer_sent_signals'])
        self.assertFalse((evidence / 'summary.json').exists())

    def test_atomic_evidence_cannot_overwrite(self):
        path = self.out / 'receipt.json'
        r.save(path, {'first': True})
        with self.assertRaises(FileExistsError):
            r.save(path, {'first': False})
        self.assertEqual(json.loads(path.read_text()), {'first': True})

    def test_cap_boolean_without_independent_proofs_is_rejected(self):
        self.cap['proof_files'] = {}
        self.cap_path.write_text(json.dumps(self.cap))
        with self.assertRaisesRegex(ValueError, 'independently hashed'):
            self.run_watch()
        self.assertFalse((self.out / 'ready.json').exists())

    def test_hostconfig_without_effective_kernel_limit_is_rejected(self):
        (self.cap_path.parent / 'native.stdout').write_text(json.dumps({'pids.max': 'max'}))
        self.rehash_cap()
        with self.assertRaisesRegex(ValueError, 'HostConfig AND kernel'):
            self.run_watch()

    def test_sdk_cap_identity_cannot_be_substituted(self):
        self.cap['binding']['sdk_inventory_sha256'] = '0' * 64
        self.cap_path.write_text(json.dumps(self.cap))
        with self.assertRaisesRegex(ValueError, 'provider/capture/SDK'):
            self.run_watch()

    def test_effective_kernel_bound_expansion_stops_observer(self):
        with patch.object(r, 'kernel_limits', return_value={'pids.max': '20', 'pids.current': '1'}):
            # run_watch supplies a normal kernel fixture; replace it after its
            # first sample to exercise the live check independently of cap proof.
            def expand(_):
                r.kernel_limits.return_value = {'pids.max': '20', 'pids.current': '1'}
            with self.assertRaisesRegex(RuntimeError, 'effective owned kernel'):
                self.run_watch(containers=[[], [self.c], [self.c]], sleep=expand)

    def test_private_preparation_requires_one_explicit_two_job_tree(self):
        dune = dict(pid=77, ppid=0, argv=['/bin/dune', 'build', '-j2', '--root', str(self.store / 'project')],
                    comm='dune', cwd=str(self.store / 'project'), os_threads=2)
        compiler = dict(pid=78, ppid=77, argv=['ocamlopt'], comm='ocamlopt', os_threads=1)
        rows = {77: dune, 78: compiler}
        self.assertEqual(r.preparation_workers(rows, [dune, compiler], self.store, '/bin/dune'), [dune, compiler])
        for extra in (dict(pid=79, ppid=77, argv=['make', '-j2'], comm='make', os_threads=1),
                      dict(pid=79, ppid=0, argv=['yosys'], comm='yosys', os_threads=1)):
            self.assertEqual(r.preparation_workers({**rows, 79: extra}, [dune, compiler, extra], self.store, '/bin/dune'), [])
        for jobs in ('-j20', '-j0', '-jauto', ''):
            dune['argv'][2] = jobs
            self.assertEqual(r.preparation_workers(rows, [dune, compiler], self.store, '/bin/dune'), [])

    def test_build_after_first_container_cannot_use_preparation_exception(self):
        def build_after_probe(_):
            self.rows[77] = dict(pid=77, ppid=0,
                argv=['/bin/dune', 'build', '-j2', '--root', str(self.store / 'project')],
                comm='dune', cwd=str(self.store / 'project'), os_threads=1)
        with self.assertRaisesRegex(RuntimeError, 'competing build'):
            self.run_watch(containers=[[], [self.c], []], sleep=build_after_probe)


class EnvelopeControls(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='envelope-controls-', dir='/tmp/opencode')
        self.addCleanup(self.tmp.cleanup)
        self.out = Path(self.tmp.name)
        self.info = dict(Name=os.uname().nodename, CgroupVersion='2', CPUSet=True,
                         PidsLimit=True, CpuCfsQuota=True)

    def run_probe(self, mutation=lambda value: None):
        def fake_run(argv, **kwargs):
            if argv[1] == 'rm':
                return subprocess.CompletedProcess(argv, 0, '', '')
            cap = int(next(a.split('=')[1] for a in argv if a.startswith('--pids-limit=')))
            value = dict(affinity=[2, 3], attempted_affinity_expansion=[2, 3], sources={},
                before={'pids.max': str(cap), 'cpu.max': '200000 100000', 'pids.events': 'max 0'},
                after={'pids.current': '1', 'pids.events': 'max 4'},
                thread_saturation=dict(failure="can't start new thread", at_limit={'pids.current': str(cap)}),
                fork_at_thread_limit=dict(errno=11),
                process_saturation=dict(failure=dict(errno=11), at_limit={'pids.current': str(cap)}),
                six_executor_slots=dict(submitted=5 if cap == 6 else 6),
                subprocess_scaffold=dict(returncode=0), native_metadata={'yosys': dict(exit_code=0)})
            mutation(value)
            return subprocess.CompletedProcess(argv, 0, 'library status line\nENVELOPE_RESULT=' + json.dumps(value) + '\n', 'diagnostic stderr\n')
        with patch.object(r, 'command', return_value=json.dumps(self.info)), \
             patch.object(r.os, 'sched_getaffinity', return_value={2, 3, 4}), \
             patch.object(r.subprocess, 'run', side_effect=fake_run):
            return r.envelope_probe(self.out)

    def test_kernel_probe_is_not_runtime_approval_and_retains_output(self):
        self.assertTrue(self.run_probe())
        summary = json.loads((self.out / 'envelope-summary.json').read_text())
        self.assertTrue(summary['probe_checks_passed'])
        self.assertFalse(summary['runtime_ceiling_established'])
        self.assertFalse(summary['synthesis_compatibility_tested'])
        self.assertIn('library status line', (self.out / '6-stdout.txt').read_text())
        self.assertEqual((self.out / '6-stderr.txt').read_text(), 'diagnostic stderr\n')

    def test_affinity_escape_cannot_pass(self):
        self.assertFalse(self.run_probe(lambda v: v.update(attempted_affinity_expansion=[2, 3, 4])))

    def test_limits_without_kernel_denials_cannot_pass(self):
        self.assertFalse(self.run_probe(lambda v: v['after'].update({'pids.events': 'max 0'})))

    def test_remote_engine_rejected_before_any_probe(self):
        self.info['Name'] = 'different-host'
        with patch.object(r, 'command', return_value=json.dumps(self.info)), \
             patch.object(r.subprocess, 'run') as run:
            with self.assertRaisesRegex(RuntimeError, 'local cgroup-v2'):
                r.envelope_probe(self.out)
            run.assert_not_called()


if __name__ == '__main__':
    unittest.main()
