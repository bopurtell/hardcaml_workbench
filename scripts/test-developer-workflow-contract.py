#!/usr/bin/env python3
"""Run under opam exec --switch=5.2.0+ox; no apps, builds, Docker or EDA."""
import argparse
import contextlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('workflow', Path(__file__).with_name('test-developer-workflow.py'))
w = importlib.util.module_from_spec(spec)
spec.loader.exec_module(w)
fixture_spec = importlib.util.spec_from_file_location('resource_contract_fixtures',
    Path(__file__).with_name('test-developer-workflow-resources.py'))
resource_fixtures = importlib.util.module_from_spec(fixture_spec)
fixture_spec.loader.exec_module(resource_fixtures)


class Contract(unittest.TestCase):
    def setUp(self):
        # Reuse the resource owner's synthetic transport/kernel proof fixture;
        # acceptance calls the actual capture()/verify_cap(), without mocking it.
        self.resource_fixture = resource_fixtures.Handshake(methodName='runTest')
        self.addCleanup(self.resource_fixture.doCleanups)
        self.resource_fixture.setUp()
        self.root, self.store = self.resource_fixture.root, self.resource_fixture.store
        self.manifest = json.loads((self.store / 'manifest.json').read_text())
        self.monitor = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'])
        self.addCleanup(self.stop_monitor)
        ticks = Path(f'/proc/{self.monitor.pid}/stat').read_text().rsplit(')', 1)[1].split()[19]
        self.ready = self.root / 'ready.json'
        self.write(self.ready, dict(schema_version=2, ready=True, pid=self.monitor.pid, store=str(self.store),
            manifest_sha256=w.sha(self.store / 'manifest.json'), allocation=6, start_ticks=ticks,
            monitor_start_ticks=ticks, workers=6, endpoint='synthesis',
            asic_generation=self.manifest['inputs']['asic_generation'],
            profile='synthesis-total-tasks-v1', total_container_tasks=6, image=w.resources.IMAGE,
            verifier_sha256=w.sha(Path(w.resources.__file__)), runtime_ceiling_established=True,
            cap_receipt=str(self.resource_fixture.cap_path), cap_receipt_sha256=w.sha(self.resource_fixture.cap_path),
            cap_binding=self.resource_fixture.cap['binding']))
        self.lease = dict(status='activated', workers=6, endpoint='synthesis', store=str(self.store),
            manifest_sha256=w.sha(self.store / 'manifest.json'), expires_unix=w.time.time() + 60,
            runtime_ceiling_established=True, no_competing_eda_or_builds=True,
            runtime_receipt=str(self.ready), runtime_receipt_sha256=w.sha(self.ready),
            monitor_pid=self.monitor.pid, monitor_start_ticks=ticks,
            asic_generation=self.manifest['inputs']['asic_generation'])
        self.lease.update(cap_receipt=str(self.resource_fixture.cap_path),
                          cap_receipt_sha256=w.sha(self.resource_fixture.cap_path))
        self.args = argparse.Namespace(allow_synthesis=True, allocation=self.root / 'lease.json', store=self.store)
        self.write(self.args.allocation, self.lease)

    def stop_monitor(self):
        if self.monitor.poll() is None:
            self.monitor.terminate()
        self.monitor.wait(timeout=5)

    @staticmethod
    def write(path, value):
        path.write_text(json.dumps(value))

    def admit(self):
        return w.allocation(self.args, self.manifest)

    def test_live_exact_admission(self):
        self.assertEqual(self.admit(), self.lease)

    def test_stop_request_with_live_monitor(self):
        (self.root / 'stop-request.json').write_text('{}')
        with self.assertRaisesRegex(AssertionError, 'stop request'):
            self.admit()

    def test_dangling_stop_marker_blocks(self):
        (self.root / 'stop-request.json').symlink_to(self.root / 'missing')
        with self.assertRaisesRegex(AssertionError, 'stop request'):
            self.admit()

    def test_pid_reuse_identity(self):
        self.lease['monitor_start_ticks'] = '0'
        self.write(self.args.allocation, self.lease)
        with self.assertRaisesRegex(AssertionError, 'reused PID'):
            self.admit()

    def test_zombie_is_not_live_monitor(self):
        self.monitor.terminate()
        # waitid WNOWAIT leaves a real zombie for the /proc liveness check.
        os.waitid(os.P_PID, self.monitor.pid, os.WEXITED | os.WNOWAIT)
        with self.assertRaisesRegex(AssertionError, 'zombie'):
            self.admit()

    def test_receipt_hash_and_binding(self):
        ready = json.loads(self.ready.read_text())
        ready['store'] = str(self.root / 'other-store')
        self.write(self.ready, ready)
        with self.assertRaisesRegex(AssertionError, 'exact runtime-owner'):
            self.admit()
        self.lease['runtime_receipt_sha256'] = w.sha(self.ready)
        self.write(self.args.allocation, self.lease)
        with self.assertRaisesRegex(AssertionError, 'readiness bound'):
            self.admit()

    def test_lease_revocation_and_expiry(self):
        for key, value, diagnostic in [('status', 'revoked', 'activated'),
                                       ('expires_unix', 0, 'expired'),
                                       ('workers', 2, 'six-worker')]:
            with self.subTest(key=key):
                changed = dict(self.lease, **{key: value})
                self.write(self.args.allocation, changed)
                with self.assertRaisesRegex(AssertionError, diagnostic):
                    self.admit()

    def test_submit_guard_runs_before_actual_enter(self):
        terminal = object.__new__(w.Terminal)
        keys = []
        def rejected():
            raise AssertionError('monitor revoked at submission')
        terminal.session = argparse.Namespace(launch_guard=rejected, evidence=self.root)
        def palette(_terminal, _title):
            _terminal.key(b'\r')
        with patch.object(w.legacy.Terminal, 'palette', palette), patch.object(
                w.legacy.Terminal, 'key', lambda _t, key: keys.append(key)):
            with self.assertRaisesRegex(AssertionError, 'revoked at submission'):
                terminal.palette('Launch and view planned run in captured context')
        self.assertEqual(keys, [])

    def capture(self):
        project = self.store / 'project'
        generation = self.store / 'generations' / 'test-capture'
        generation.mkdir(parents=True)
        target = 'asics/fifo_demo/cli/project.exe'
        source = project / Path(target).with_suffix('.ml')
        source.parent.mkdir(parents=True)
        source.write_text('source')
        source.with_name('dune').write_text('dune')
        config = project / 'hardcaml-workbench-preparation.sexp'
        config.write_text(w.sexp([['schema_version', 1], ['build_target', target]]))
        # Real captured helpers and their exact declared ownership-v1 roots.
        dirs = ['ip/controlled_fifo', 'asics/fifo_demo', 'asics/program_memory',
                'tooling_acceptance', 'integration/workbench', 'scripts']
        files = ['dune-project', 'asic-dependency.json', 'README.md', 'bootstrap.sh',
                 'asics/fifo_demo/verif/bundle/dune', 'asics/fifo_demo/verif/bundle/export_trace.ml',
                 'asics/fifo_demo/verif/bundle/check_bundle.py', 'asics/fifo_demo/verif/bundle/replay.v']
        for name in dirs:
            (project / name).mkdir(parents=True, exist_ok=True)
        for name in files:
            path = project / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('fixture source')
        for name in ('integration/workbench/workbench_provider.py', 'integration/workbench/wire.py',
                     'scripts/workbench_git.py'):
            shutil.copyfile(w.EXAMPLE / name, project / name)
        shutil.copytree(project, generation / 'source')
        captured = generation / 'captured'
        captured.write_text('capture')
        asic = Path(self.manifest['inputs']['asic_generation'])
        asic.mkdir(exist_ok=True)
        self.write(asic / 'receipt.json', dict(identity='test-asic'))
        manifest = dict(self.manifest, source_layout='ownership-v1', store=str(self.store),
            project_root=str(project), generation=str(generation), max_jobs=2,
            source_roots=files + dirs,
            source_files={str(p.relative_to(project)): w.sha(p) for p in project.rglob('*')
                          if p.is_file() and p != config},
            config_files={config.name: w.sha(config)},
            captured_files={str(p.relative_to(generation)): w.sha(p) for p in generation.rglob('*') if p.is_file()},
            asic_files={'receipt.json': w.sha(asic / 'receipt.json')},
            asic_receipt_sha256=w.sha(asic / 'receipt.json'),
            git_context=dict(real_git='/usr/bin/git', real_git_sha256=w.sha(Path('/usr/bin/git'))))
        self.write(generation / 'manifest.json', manifest)
        (self.store / 'manifest.json').unlink()
        (self.store / 'selected').unlink()
        (self.store / 'selected').symlink_to(generation)
        (self.store / 'manifest.json').symlink_to('selected/manifest.json')
        return project, generation, manifest

    def test_ownership_target_and_source_drift(self):
        project, _, manifest = self.capture()
        identities = w.legacy.validate_capture(self.store, project, manifest)
        self.assertEqual(identities['build_target'], 'asics/fifo_demo/cli/project.exe')
        (project / 'asics/fifo_demo/cli/project.ml').write_text('edited')
        with self.assertRaisesRegex(AssertionError, 'exact captured bytes'):
            w.legacy.validate_capture(self.store, project, manifest)

    def test_legacy_store_refused_without_mutation(self):
        project, generation, manifest = self.capture()
        before = (generation / 'manifest.json').read_bytes()
        manifest.pop('source_layout')
        with self.assertRaisesRegex(AssertionError, 'NEW store'):
            w.legacy.validate_capture(self.store, project, manifest)
        self.assertEqual((generation / 'manifest.json').read_bytes(), before)

    def test_cli_legacy_rejection_retains_failed_receipt_before_store_lock(self):
        _, generation, manifest = self.capture()
        manifest['generation_id'] = generation.name
        manifest.pop('source_layout')
        self.write(generation / 'manifest.json', manifest)
        original = (self.store / 'manifest.json').read_bytes()
        evidence = self.root / 'cli-failure'
        # Exercise the real CLI with a disposable historical-layout fixture.
        result = subprocess.run([sys.executable, '-B', str(Path(w.__file__)),
            '--phase', 'simulations', '--store', str(self.store), '--owner-store', str(self.store),
            '--evidence', str(evidence)], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        receipt = json.loads((evidence / 'receipt.json').read_text())
        self.assertEqual(receipt['status'], 'failed')
        self.assertEqual(receipt['eda_jobs'], 0)
        self.assertIn('NEW store', receipt['error'])
        self.assertEqual((self.store / 'manifest.json').read_bytes(), original)
        self.assertFalse((self.store / 'acceptance.lock').exists())
        self.assertFalse((self.store / 'state').exists())

    def test_same_store_phase_and_identity_fences(self):
        self.args.previous = self.root / 'previous.json'
        self.args.identities = dict(build_target='asics/fifo_demo/cli/project.exe')
        receipt = dict(status='passed', phase='simulations', store=str(self.store),
            manifest_sha256=w.sha(self.store / 'manifest.json'), identities=self.args.identities)
        self.write(self.args.previous, receipt)
        self.assertEqual(w.previous(self.args, 'simulations'), receipt)
        for key, value in [('store', str(self.root / 'other')), ('manifest_sha256', '0' * 64),
                           ('identities', dict(build_target='bin/project.exe'))]:
            with self.subTest(key=key):
                self.write(self.args.previous, dict(receipt, **{key: value}))
                with self.assertRaises(AssertionError):
                    w.previous(self.args, 'simulations')

    def test_prepare_requires_explicit_inputs_before_build(self):
        args = argparse.Namespace(store=self.root / 'new', asic_generation=None, sdk_prefix=None)
        with patch.object(w, 'command') as command:
            with self.assertRaisesRegex(AssertionError, 'explicit'):
                w.prepare(args, self.root)
            command.assert_not_called()

    def test_future_prepare_forwards_task_limit_and_explicit_build_root(self):
        evidence = self.root / 'future-prepare'
        evidence.mkdir()
        args = argparse.Namespace(store=self.root / 'new-store', source_root=w.EXAMPLE,
            launcher=w.EXAMPLE / 'scripts/workbench_dev.py',
            asic_generation=Path(self.manifest['inputs']['asic_generation']),
            sdk_prefix=Path(self.manifest['generation']) / 'sdk', synthesis_task_limit=6)
        with patch.object(w, 'command') as command, patch.object(w, 'sha', return_value='fixture-sha'):
            w.prepare(args, evidence)
        argv = command.call_args_list[1].args[2]
        self.assertEqual(argv[argv.index('--synthesis-task-limit') + 1], '6')
        self.assertEqual(argv[argv.index('--wb-build-root') + 1], str(w.HERE.parent / '_build_pt8_workbench'))

    def test_run_selection_option_wire(self):
        selection = [['flow', 'standard'], ['profile', 'balanced'], ['endpoint', 'synthesis'], ['assignments', []]]
        intent = [['selection', selection]]
        w.verify_run_selection([['selection', [selection]]], intent)
        for value in ([], selection, [selection, selection], [[['flow', 'other']]]):
            with self.subTest(value=value), self.assertRaises(AssertionError):
                w.verify_run_selection([['selection', value]], intent)

    def test_added_source_rejected_but_generated_exclusions_admitted(self):
        project, _, manifest = self.capture()
        generated = project / 'asics/fifo_demo/_build-generated'
        generated.mkdir()
        (generated / 'output.ml').write_text('generated')
        (project / 'scripts/ignored.pyc').write_text('cache')
        w.legacy.validate_capture(self.store, project, manifest)
        (project / 'asics/fifo_demo/new_authored.ml').write_text('added')
        with self.assertRaisesRegex(AssertionError, 'inventory closure'):
            w.legacy.validate_capture(self.store, project, manifest)
        (project / 'asics/fifo_demo/new_authored.ml').unlink()
        (project / 'dune').write_text('added root build rule')
        with self.assertRaisesRegex(AssertionError, 'whole-project source/config closure'):
            w.legacy.validate_capture(self.store, project, manifest)

    def test_post_enter_failure_marks_unknown_before_write(self):
        report = dict(eda_jobs=0)
        terminal = object.__new__(w.Terminal)
        terminal.session = argparse.Namespace(evidence=self.root, launch_guard=lambda: None,
            submission_possible=lambda: w.mark_submission(report))
        def palette(t, _title):
            t.key(b'\r')
            raise AssertionError('capture failed after Enter')
        def key(_terminal, _key):
            self.assertTrue(report['synthesis_submission_possible'])
            self.assertIsNone(report['eda_jobs'])
        with patch.object(w.legacy.Terminal, 'palette', palette), patch.object(w.legacy.Terminal, 'key', key):
            with self.assertRaisesRegex(AssertionError, 'after Enter'):
                terminal.palette('Launch and view planned run in captured context')
        self.assertTrue(report['synthesis_submission_possible'])
        self.assertIsNone(report['eda_jobs'])

    def test_wrong_intent_never_selected_or_cancelled(self):
        intent = [['id', 'ours']]
        foreign = [['id', 'foreign-workflow'], ['intent', [['id', 'theirs']]], ['phase', 'Running']]
        snapshot = [['workflows', [foreign]]]
        self.assertIsNone(w.intent_workflow(snapshot, intent))
        session = Mock()
        session.api.return_value = snapshot
        w.cancel_owned(session, Mock(), self.root, intent)
        session.api.assert_called_once_with(domain='asic')

    def test_synthesis_foreign_workflow_failure_never_cancels_foreign(self):
        intent = [['id', 'ours']]
        foreign = [['id', 'foreign-workflow'], ['intent', [['id', 'theirs']]], ['phase', 'Running']]
        session, terminal = Mock(), Mock()
        session.api.side_effect = [[['workflows', []], ['runs', []], ['launches', []]],
                                   [['workflows', [foreign]], ['runs', []]], [['workflows', [foreign]]]]
        terminal.palette.side_effect = lambda _title: session.submission_possible()
        self.args.previous = self.root / 'previous.json'
        self.write(self.args.previous, {})
        self.args.synthesis_timeout = 0
        prior = dict(attempts=[], simulation_receipt='fixture', simulation_receipt_sha256='fixture')
        report = dict(eda_jobs=0)
        with patch.object(w, 'previous', return_value=prior), patch.object(w, 'native_prerequisite'), patch.object(
                w, 'allocation', return_value=self.lease), patch.object(w, 'stage', return_value=intent), patch.object(
                w, 'pair', return_value=contextlib.nullcontext((session, terminal))):
            with self.assertRaisesRegex(AssertionError, 'workflow deadline'):
                w.synthesis(self.args, self.root, report, self.manifest)
        self.assertTrue(report['synthesis_submission_possible'])
        self.assertIsNone(report['eda_jobs'])
        self.assertNotIn('workflow_id', report)
        self.assertTrue(all('operation' not in call.kwargs for call in session.api.call_args_list))

    def test_cancel_rebinds_exact_intent_and_settles(self):
        intent = [['id', 'ours']]
        active = [['id', 'owned'], ['intent', intent], ['phase', 'Running']]
        terminal = [['id', 'owned'], ['intent', intent], ['phase', 'Cancelled']]
        session = Mock()
        session.api.side_effect = [[['workflows', [active]]], ['ok'], [['workflows', [terminal]]]]
        w.cancel_owned(session, Mock(), self.root, intent)
        self.assertEqual(session.api.call_args_list[1].kwargs['operation'], ['Cancel_workflow', 'owned'])

    def test_ceiling_boolean_without_enforcement_proof_rejected(self):
        self.lease.pop('cap_receipt')
        self.write(self.args.allocation, self.lease)
        with self.assertRaisesRegex(AssertionError, 'boolean is insufficient'):
            self.admit()

    def test_enforcement_hash_binding_and_evidence(self):
        path = Path(self.lease['cap_receipt'])
        original = json.loads(path.read_text())
        for key, value in [('store', str(self.root / 'other-store')),
                           ('asic_generation', str(self.root / 'other-provider')),
                           ('asic_receipt_sha256', 'wrong'), ('total_container_tasks', 7)]:
            with self.subTest(key=key):
                self.write(path, dict(original, binding=dict(original['binding'], **{key: value})))
                self.lease['cap_receipt_sha256'] = w.sha(path)
                self.write(self.args.allocation, self.lease)
                with self.assertRaisesRegex(ValueError, 'cap receipt does not bind'):
                    self.admit()
        self.write(path, original)
        self.lease['cap_receipt_sha256'] = w.sha(path)
        self.write(self.args.allocation, self.lease)
        (path.parent / 'native.stdout').write_text('tampered')
        with self.assertRaisesRegex(ValueError, 'cap proof bytes changed'):
            self.admit()

    def test_schema2_ready_cap_identity_and_ceiling_binding(self):
        original = json.loads(self.ready.read_text())
        for key, value in [('schema_version', 1), ('runtime_ceiling_established', False),
                           ('cap_receipt_sha256', 'wrong'), ('cap_binding', {}),
                           ('monitor_start_ticks', '0'), ('verifier_sha256', 'wrong')]:
            with self.subTest(key=key):
                self.write(self.ready, dict(original, **{key: value}))
                self.lease['runtime_receipt_sha256'] = w.sha(self.ready)
                self.write(self.args.allocation, self.lease)
                with self.assertRaises(AssertionError):
                    self.admit()

    def test_real_cap_hash_and_staleness_not_bypassed(self):
        path = Path(self.lease['cap_receipt'])
        cap = json.loads(path.read_text())
        cap['established_at_unix'] = 0
        self.write(path, cap)
        with self.assertRaisesRegex(AssertionError, 'exact cap receipt bytes'):
            self.admit()
        self.lease['cap_receipt_sha256'] = w.sha(path)
        self.write(self.args.allocation, self.lease)
        with self.assertRaisesRegex(ValueError, 'exact fresh provider'):
            self.admit()

    def test_native_prerequisite_hash_checked_before_pair(self):
        receipt = self.root / 'native.json'
        self.write(receipt, dict(status='passed'))
        prior = dict(simulation_receipt=str(receipt), simulation_receipt_sha256=w.sha(receipt))
        receipt.write_text('changed')
        with self.assertRaisesRegex(AssertionError, 'prerequisite receipt bytes'):
            w.native_prerequisite(self.args, prior)

    def test_native_prerequisite_exact_capture_binding(self):
        receipt = self.root / 'native.json'
        self.args.root = self.store / 'project'
        self.args.identities = dict(source_layout='ownership-v1')
        value = dict(status='passed', store=str(self.store), root=str(self.args.root),
                     manifest_sha256=w.sha(self.store / 'manifest.json'), identities=self.args.identities,
                     attempts=['normal', 'mismatch', 'pt8'])
        self.write(receipt, value)
        prior = dict(value, simulation_receipt=str(receipt), simulation_receipt_sha256=w.sha(receipt))
        self.assertEqual(w.native_prerequisite(self.args, prior), value)
        self.write(receipt, dict(value, store=str(self.root / 'other')))
        prior['simulation_receipt_sha256'] = w.sha(receipt)
        with self.assertRaisesRegex(AssertionError, 'same capture and attempts'):
            w.native_prerequisite(self.args, prior)

    def test_pair_stops_daemon_when_terminal_close_fails(self):
        args = argparse.Namespace(root=self.store / 'project', store=self.store, phase='synthesis')
        evidence = self.root / 'pair'
        evidence.mkdir()
        session = Mock(env={}, metadata={}, process=True)
        terminal = Mock()
        terminal.close.side_effect = RuntimeError('close failed')
        with patch.object(w.legacy, 'Session', return_value=session), patch.object(w, 'Terminal', return_value=terminal):
            with self.assertRaisesRegex(RuntimeError, 'close failed'):
                with w.pair(args, evidence):
                    pass
        session.stop.assert_called_once()

    def test_guard_applies_after_workflow_completion_during_collection_wait(self):
        session = Mock()
        session.resource_guard = Mock(side_effect=AssertionError('monitor revoked during collection'))
        with self.assertRaisesRegex(AssertionError, 'during collection'):
            w.wait(session, Mock(), 'asic', lambda _: True)
        session.api.assert_not_called()

    def test_reopen_display_is_verified_without_cursor_restoration_claim(self):
        w.verify_stacked_display('Waveform\n│ [*] clock [1]\n│   = 0\nCursor 0 ticks')
        with self.assertRaisesRegex(AssertionError, 'Stacked display'):
            w.verify_stacked_display('│ [*] clock [1] = 0\n│ [*] data [8] = 01\nCursor 40 ticks')


if __name__ == '__main__':
    unittest.main()
