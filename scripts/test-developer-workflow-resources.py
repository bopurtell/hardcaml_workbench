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
            Path='python3', Args=['-I', '-B', str(staged), str(self.request)],
            State=dict(Pid=999999, Running=True, Status='running', StartedAt='2026-11-10T00:00:00Z',
                       FinishedAt='0001-01-01T00:00:00Z'),
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

    def run_watch(self, containers=None, rows=None, sleep=None, proc_snapshots=None, inspections=None, tasks_fn=None):
        rows = rows or self.rows
        snapshots = iter(proc_snapshots or [{pid: row for pid, row in rows.items() if pid not in r.descendants(rows, 999999)}, rows])
        def finished(_):
            self.rows.pop(999999, None)
            self.finish.touch()
        with patch.object(r, 'running', side_effect=containers or [[], [self.c], [], []]), \
             patch.object(r, 'inspect_container', side_effect=inspections, return_value=None), \
             patch.object(r, 'processes', side_effect=lambda: next(snapshots, rows)), \
             patch.object(r, 'tasks', side_effect=tasks_fn or (lambda row, _: [dict(tid=row['pid'], state='S', cpu_ticks=0, delta_ticks=None)])), \
             patch.object(r, 'command', return_value=json.dumps(self.engine)), \
             patch.object(r, 'kernel_limits', return_value=self.kernel()), \
             patch.object(r.time, 'sleep', side_effect=sleep or finished):
            return r.watch(self.args, self.out)

    def kernel(self, maximum='6'):
        return {'path': '/sys/fs/cgroup/docker-' + self.c['Id'] + '.scope',
                'pids.max': maximum, 'pids.current': '1'}

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
            self.rows.pop(999999, None)
            self.rows[77] = dict(pid=77, ppid=0, argv=['make', '-j20'], comm='make', cwd=str(self.store))
        with self.assertRaisesRegex(RuntimeError, 'competing build'):
            self.run_watch(sleep=competing)
        self.assertFalse((self.out / 'summary.json').exists())

    def test_finish_with_live_container_rejects(self):
        with self.assertRaisesRegex(RuntimeError, 'finish requested'):
            self.run_watch(containers=[[], [self.c], [self.c]], sleep=lambda _: self.finish.touch())

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
            self.run_watch(containers=[[], [self.c], [second]], sleep=lambda _: self.rows.pop(999999, None))

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
                r.kernel_limits.return_value = self.kernel('20')
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
            self.rows.pop(999999, None)
            self.rows[77] = dict(pid=77, ppid=0,
                argv=['/bin/dune', 'build', '-j2', '--root', str(self.store / 'project')],
                comm='dune', cwd=str(self.store / 'project'), os_threads=1)
        with self.assertRaisesRegex(RuntimeError, 'competing build'):
            self.run_watch(containers=[[], [self.c], []], sleep=build_after_probe)

    def test_removing_pid_zero_after_live_sample_is_exit_with_explicit_gap(self):
        terminal = copy.deepcopy(self.c)
        terminal['State'].update(Pid=0, Running=False, Status='removing', FinishedAt='2026-11-10T00:00:01Z')
        def finished(_):
            self.rows.pop(999999, None)
            self.finish.touch()
        self.assertTrue(self.run_watch(containers=[[], [self.c], [terminal], []], sleep=finished))
        summary = json.loads((self.out / 'summary.json').read_text())
        self.assertEqual(summary['coverage']['partial_samples'], 1)
        lines = [json.loads(line) for line in (self.out / 'samples.jsonl').read_text().splitlines()]
        partial = next(x for x in lines if x.get('sample_coverage') == 'partial')
        self.assertIsNone(partial['native_os_threads'])
        self.assertIsNone(partial['native_runnable_threads'])
        self.assertEqual(partial['containers'][0]['status'], 'confirmed-exit')

    def test_restarted_terminal_in_ordinary_inventory_cannot_complete_watch(self):
        terminal = copy.deepcopy(self.c)
        terminal['State'].update(Pid=0, Running=False, Status='removing',
            StartedAt='2026-11-10T00:00:02Z', FinishedAt='2026-11-10T00:00:03Z')
        with self.assertRaisesRegex(RuntimeError, 'restarted: StartedAt'):
            self.run_watch(containers=[[], [self.c], [terminal], []])
        self.assertFalse((self.out / 'summary.json').exists())

    def test_restarted_terminal_at_final_check_cannot_complete_watch(self):
        terminal = copy.deepcopy(self.c)
        terminal['State'].update(Pid=0, Running=False, Status='removing',
            StartedAt='2026-11-10T00:00:02Z', FinishedAt='2026-11-10T00:00:03Z')
        with self.assertRaisesRegex(RuntimeError, 'restarted: StartedAt'):
            self.run_watch(containers=[[], [self.c], [], [terminal]])
        self.assertFalse((self.out / 'summary.json').exists())

    def test_same_epoch_terminal_pid_zero_is_valid_at_final_check(self):
        terminal = copy.deepcopy(self.c)
        terminal['State'].update(Pid=0, Running=False, Status='removing', FinishedAt='2026-11-10T00:00:01Z')
        self.assertTrue(self.run_watch(containers=[[], [self.c], [], [terminal]]))
        summary = json.loads((self.out / 'summary.json').read_text())
        self.assertEqual(summary['coverage']['gaps'][-1]['reason'], 'terminal-container-at-final-check')

    def test_restarted_terminal_after_ps_omission_is_rejected(self):
        terminal = copy.deepcopy(self.c)
        terminal['State'].update(Pid=0, Running=False, Status='removing',
            StartedAt='2026-11-10T00:00:02Z', FinishedAt='2026-11-10T00:00:03Z')
        with self.assertRaisesRegex(RuntimeError, 'restarted: StartedAt'):
            self.run_watch(containers=[[], [self.c], []], inspections=[terminal])
        self.assertFalse((self.out / 'summary.json').exists())

    def test_policy_valid_fixed_contract_drift_is_rejected_in_inventory_and_final_check(self):
        for final_check in (False, True):
            with self.subTest(final_check=final_check):
                terminal = copy.deepcopy(self.c)
                terminal['State'].update(Pid=0, Running=False, Status='removing', FinishedAt='2026-11-10T00:00:01Z')
                terminal['Config']['Env'].append('RESOURCE_MARKER=changed')
                self.assertEqual(r.validate_container(terminal, self.store), [])
                # Each attempt needs new append-only monitoring evidence.
                self.out = self.root / ('drift-' + str(final_check))
                self.out.mkdir()
                self.finish.unlink(missing_ok=True)
                self.rows[999999] = dict(pid=999999, ppid=0, start_ticks=456,
                    argv=['python3'], comm='python3', os_threads=1)
                containers = [[], [self.c], [], [terminal]] if final_check else [[], [self.c], [terminal]]
                with self.assertRaisesRegex(RuntimeError, 'identity/resource contract changed'):
                    self.run_watch(containers=containers)
                self.assertFalse((self.out / 'summary.json').exists())

    def test_known_auto_removal_between_ps_and_inspect_is_retained(self):
        def finished(_):
            self.rows.pop(999999, None)
            self.finish.touch()
        self.assertTrue(self.run_watch(containers=[[], [self.c], r.ContainerSnapshot(missing_ids=[self.c['Id']]), []], sleep=finished))
        summary = json.loads((self.out / 'summary.json').read_text())
        self.assertEqual(summary['coverage']['gaps'][0]['disposition'], 'previously-owned-removed')

    def test_unknown_auto_removal_cannot_hide_unowned_container(self):
        with self.assertRaisesRegex(RuntimeError, 'before ownership could be established'):
            self.run_watch(containers=[[], r.ContainerSnapshot(missing_ids=['f' * 64])])
        self.assertFalse((self.out / 'summary.json').exists())

    def test_audit_missing_inspect_is_not_clear(self):
        with patch.object(r, 'running', return_value=r.ContainerSnapshot(missing_ids=['f' * 64])), \
             patch.object(r, 'processes', return_value={}):
            self.assertFalse(r.audit(self.out))
        self.assertEqual(json.loads((self.out / 'admission.json').read_text())['uninspected_container_ids'], ['f' * 64])

    def test_ps_omission_of_still_running_owned_container_is_recovered(self):
        sleeps = []
        def finish_after_recovery(_):
            sleeps.append(True)
            if len(sleeps) == 2:
                self.rows.pop(999999, None)
                self.finish.touch()
        self.assertTrue(self.run_watch(containers=[[], [self.c], [], [], []],
            inspections=[self.c, None], sleep=finish_after_recovery))
        gaps = json.loads((self.out / 'summary.json').read_text())['coverage']['gaps']
        self.assertIn('recovered-by-direct-inspect', [g['disposition'] for g in gaps])

    def test_ps_omission_cannot_hide_a_persistently_unobservable_live_root(self):
        with self.assertRaisesRegex(RuntimeError, 'unobservable after bounded reinspection'):
            self.run_watch(containers=[[], [self.c], []], inspections=[self.c, self.c, self.c],
                           sleep=lambda _: self.rows.pop(999999, None))

    def test_unowned_terminal_metadata_is_validated_before_exit_is_accepted(self):
        c = copy.deepcopy(self.c)
        c['Name'] = '/hardcaml-asic-execution-' + 'f' * 32
        c['State'].update(Pid=0, Running=False, Status='removing', FinishedAt='2026-11-10T00:00:01Z')
        c['Args'] = ['-I', '-B', '-c', (self.helper / 'stage_metadata_probe.py').read_text(), 'metadata-container']
        c['Mounts'] = []
        c['HostConfig'].update(ReadonlyRootfs=True, NetworkMode='none')
        with self.assertRaisesRegex(RuntimeError, 'no pre-existing test-store launch'):
            self.run_watch(containers=[[], [c]])
        self.assertFalse((self.out / 'summary.json').exists())

    def test_child_disappearance_is_unknown_task_coverage_not_zero_counts(self):
        self.rows[88] = dict(pid=88, ppid=999999, start_ticks=88, argv=['yosys'], comm='yosys', os_threads=1)
        def sample_tasks(row, _):
            if row['pid'] == 88:
                raise FileNotFoundError()
            return [dict(tid=row['pid'], state='S', cpu_ticks=0, delta_ticks=None)]
        def finished(_):
            self.rows.pop(999999, None); self.rows.pop(88, None)
            self.finish.touch()
        self.assertTrue(self.run_watch(tasks_fn=sample_tasks, sleep=finished))
        records = [json.loads(line) for line in (self.out / 'samples.jsonl').read_text().splitlines()]
        child = next(x for x in records if x.get('kind') == 'process' and x['process']['pid'] == 88)
        self.assertIsNone(child['process']['tasks'])
        partial = next(x for x in records if x.get('sample_coverage') == 'partial')
        self.assertIsNone(partial['native_os_threads'])
        self.assertEqual(partial['observed_native_os_threads'], 1)

    def test_recovery_preserves_competition_from_initial_snapshot(self):
        initial = {os.getpid(): self.rows[os.getpid()],
                   77: dict(pid=77, ppid=0, start_ticks=77, argv=['yosys'], comm='yosys', os_threads=1)}
        own = {os.getpid(): self.rows[os.getpid()]}
        with self.assertRaisesRegex(RuntimeError, 'competing build/native'):
            self.run_watch(proc_snapshots=[own, own, initial, self.rows], inspections=[self.c])


class ContainerExitRaces(unittest.TestCase):
    def setUp(self):
        self.cid = 'a' * 64
        self.c = dict(Id=self.cid, Name='/hardcaml-asic-execution-' + 'b' * 32, Image=r.IMAGE,
            Path='python3', Args=['-B', '-c', 'metadata', 'container'], Mounts=[], HostConfig=dict(PidsLimit=6), Config={},
            State=dict(Pid=42, Running=True, Status='running', StartedAt='2026-11-10T00:00:00Z',
                       FinishedAt='0001-01-01T00:00:00Z'))
        self.rows = {42: dict(pid=42, ppid=0, start_ticks=100, state='S', argv=['python3'], comm='python3', os_threads=1)}
        self.limits = {'path': '/sys/fs/cgroup/system.slice/docker-' + self.cid + '.scope',
                       'pids.max': '6', 'pids.current': '1'}
        self.ts = [dict(tid=42, state='S', cpu_ticks=0, delta_ticks=None)]
        self.events, self.snapshots = [], []

    def terminal(self, status='removing'):
        c = copy.deepcopy(self.c)
        c['State'].update(Pid=0, Running=False, Status=status, Dead=True, ExitCode=0, FinishedAt='2026-11-10T00:00:01Z')
        return c

    def observe(self, initial=None, rows=None, inspections=(), proc=(), kernels=None, task_samples=None, identity=None):
        with patch.object(r, 'inspect_container', side_effect=inspections) as inspect, \
             patch.object(r, 'processes', side_effect=proc), \
             patch.object(r, 'kernel_limits', side_effect=kernels or [self.limits] * 3), \
             patch.object(r, 'tasks', side_effect=task_samples or [self.ts] * 3):
            result = r.observe_container(initial or self.c, {} if rows is None else rows, {},
                                         self.events.append, self.snapshots, identity)
        return result, inspect.call_count

    def test_exact_retained_removing_state_never_looks_for_pid_zero(self):
        (c, _, limits, ts), calls = self.observe(initial=self.terminal())
        self.assertIsNone(c)
        self.assertIsNone(limits)
        self.assertIsNone(ts)
        self.assertEqual(calls, 0)
        self.assertEqual(self.events[-1]['disposition'], 'confirmed-terminal')
        self.assertFalse(self.events[-1]['native_counts_observed'])

    def test_missing_root_reinspect_confirms_exit_or_auto_removal(self):
        for fresh in (self.terminal('exited'), None):
            with self.subTest(fresh=fresh):
                result, calls = self.observe(inspections=[fresh])
                self.assertIsNone(result[0])
                self.assertEqual(calls, 1)
                self.assertIn(self.events[-1]['disposition'], ('confirmed-terminal', 'confirmed-auto-removed'))

    def test_missing_root_recovers_only_with_fresh_proc_kernel_and_tasks(self):
        result, calls = self.observe(inspections=[self.c], proc=[self.rows])
        self.assertEqual(calls, 1)
        self.assertEqual(result[2], self.limits)
        self.assertEqual(result[3], self.ts)
        self.assertEqual(self.events[-1]['disposition'], 'recovered-live-root')

    def test_persistent_missing_live_root_stops_after_two_reinspections(self):
        with self.assertRaisesRegex(RuntimeError, 'unobservable after bounded reinspection'):
            self.observe(inspections=[self.c, self.c], proc=[{}, {}])
        self.assertEqual(sum(e['kind'] == 'container-reinspection' for e in self.events), 2)
        self.assertEqual(self.events[-1]['disposition'], 'unresolved-live-or-unknown')

    def test_created_state_is_not_misclassified_as_exit(self):
        c = copy.deepcopy(self.c)
        c['State'].update(Pid=0, Running=False, Status='created')
        with self.assertRaisesRegex(RuntimeError, 'unobservable after bounded reinspection'):
            self.observe(initial=c, inspections=[c, c], proc=[{}, {}])

    def test_kernel_disappears_after_proc_snapshot_then_exit_confirmed(self):
        result, _ = self.observe(rows=self.rows, kernels=[FileNotFoundError()],
                                 inspections=[self.terminal()], proc=[{}])
        self.assertIsNone(result[0])
        self.assertEqual(self.events[-1]['disposition'], 'confirmed-terminal')

    def test_root_tasks_disappear_then_exit_confirmed(self):
        result, _ = self.observe(rows=self.rows, task_samples=[[]], inspections=[None], proc=[{}])
        self.assertIsNone(result[0])

    def test_root_task_race_can_recover_without_inventing_gap_counts(self):
        result, _ = self.observe(rows=self.rows, task_samples=[[], self.ts], inspections=[self.c], proc=[self.rows])
        self.assertIsNotNone(result[0])
        self.assertEqual(self.events[-1]['disposition'], 'recovered-live-root')
        self.assertFalse(self.events[-1]['native_counts_observed'])

    def test_unreadable_still_live_root_is_not_ignored(self):
        unreadable = {42: dict(pid=42, unreadable=True)}
        with self.assertRaisesRegex(RuntimeError, 'unobservable after bounded reinspection'):
            self.observe(rows=unreadable, inspections=[self.c, self.c], proc=[unreadable, unreadable])

    def test_pid_reuse_and_foreign_cgroup_are_rejected(self):
        with self.assertRaisesRegex(RuntimeError, 'PID/start identity changed'):
            self.observe(rows=self.rows, identity=(42, 99))
        with self.assertRaisesRegex(RuntimeError, 'cgroup does not match'):
            self.observe(rows=self.rows, kernels=[dict(self.limits, path='/sys/fs/cgroup/unrelated')])

    def test_resource_or_root_identity_changes_during_reinspection_stop(self):
        variants = []
        c = copy.deepcopy(self.c); c['HostConfig']['PidsLimit'] = 20; variants.append(c)
        c = copy.deepcopy(self.c); c['Id'] = 'f' * 64; variants.append(c)
        c = copy.deepcopy(self.c); c['State']['Pid'] = 43; variants.append(c)
        c = copy.deepcopy(self.c); c['State']['StartedAt'] = '2026-11-10T00:00:01Z'; variants.append(c)
        for c in variants:
            with self.subTest(c=c), self.assertRaisesRegex(RuntimeError, 'changed|restarted'):
                self.observe(inspections=[c])

    def test_restarted_terminal_during_reinspection_is_rejected(self):
        c = self.terminal()
        c['State']['StartedAt'] = '2026-11-10T00:00:02Z'
        with self.assertRaisesRegex(RuntimeError, 'restarted: StartedAt'):
            self.observe(inspections=[c])

    def test_shared_identity_validator_checks_all_fixed_fields_before_terminal_state(self):
        for key in ('Id', 'Name', 'Image', 'Path', 'Args', 'Mounts', 'HostConfig', 'Config'):
            with self.subTest(key=key):
                c = self.terminal()
                c[key] = {'changed': key}
                with self.assertRaisesRegex(RuntimeError, 'identity/resource contract changed'):
                    r.validate_inspection_identity(self.c, c)

    def test_terminal_inspect_cannot_conceal_persistently_live_prior_root(self):
        with self.assertRaisesRegex(RuntimeError, 'prior root remains live'):
            self.observe(initial=self.terminal(), rows=self.rows, identity=(42, 100), proc=[self.rows])

    def test_inspect_only_accepts_exact_confirmed_absence(self):
        for stderr in ('Error: No such object: ' + self.cid,
                       'Error response from daemon: No such container: ' + self.cid):
            with patch.object(r.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, '[]\n', stderr)):
                self.assertIsNone(r.inspect_container(self.cid))
        for stderr in ('permission denied', 'Cannot connect to Docker daemon',
                       'Error: No such object: different-id', 'Error: No such object: ' + self.cid + '\nother error'):
            with patch.object(r.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, '', stderr)):
                with self.assertRaisesRegex(RuntimeError, 'Docker inspect'):
                    r.inspect_container(self.cid)

    def test_ps_to_inspect_removal_remains_visible_in_inventory(self):
        with patch.object(r, 'command', return_value=self.cid), patch.object(r, 'inspect_container', return_value=None):
            snapshot = r.running()
        self.assertTrue(snapshot)
        self.assertEqual(list(snapshot), [])
        self.assertEqual(snapshot.missing_ids, [self.cid])


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
