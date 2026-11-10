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
launcher_spec = importlib.util.spec_from_file_location('recovery_example_launcher', w.EXAMPLE / 'scripts/workbench_dev.py')
launcher = importlib.util.module_from_spec(launcher_spec)
launcher_spec.loader.exec_module(launcher)


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

    def test_collection_allocation_requires_exact_scope_and_execution(self):
        self.args.allow_synthesis = False
        self.args.allow_collection = True
        execution = dict(path=str(self.store / 'execution.json'), sha256='exact-execution-digest')
        with self.assertRaisesRegex(AssertionError, 'collection-only'):
            w.allocation(self.args, self.manifest, collection=execution)
        ready = json.loads(self.ready.read_text())
        for record in (ready, self.lease):
            record.update(operation_scope='collection-only', execution_file=execution['path'], execution_sha256=execution['sha256'])
        self.write(self.ready, ready)
        self.lease['runtime_receipt_sha256'] = w.sha(self.ready)
        self.write(self.args.allocation, self.lease)
        self.assertEqual(w.allocation(self.args, self.manifest, collection=execution), self.lease)
        with self.assertRaisesRegex(AssertionError, 'exact original execution'):
            w.allocation(self.args, self.manifest, collection=dict(execution, sha256='different'))

    def test_recovery_tui_rejects_implementation_and_wrong_collection(self):
        terminal = object.__new__(w.Terminal)
        terminal.session = argparse.Namespace(recovery_only=True, collection_title='Finalize (collect) asic/original')
        with patch.object(w.legacy.Terminal, 'palette') as palette:
            for title in ('Launch and view planned run in captured context', 'Plan ASIC standard / balanced',
                          'Finalize (accept) asic/original', 'Finalize (collect) asic/wrong'):
                with self.subTest(title=title), self.assertRaises(AssertionError):
                    terminal.palette(title)
            palette.assert_not_called()
            terminal.palette('Finalize (collect) asic/original')
            palette.assert_called_once_with('Finalize (collect) asic/original')

    def test_zoom_identity_works_without_visible_tile_title(self):
        snapshot = [['workspaces',[[['id','overview'],['name','Overview'],['zoomed_tile',['tile-synth']]],
                                  [['id','testing'],['name','Testing'],['zoomed_tile',['tile-other']]]]],
                    ['tiles',[[['id','tile-synth'],['workspace','overview'],['kind','synthesis'],['hidden','false']],
                              [['id','tile-other'],['workspace','testing'],['kind','simulation-detail'],['hidden','false']]]]]
        self.assertEqual(w.zoomed_kind(snapshot,'Overview'),'synthesis')
        self.assertEqual(w.zoomed_kind(snapshot,'Testing'),'simulation-detail')

    def test_focus_does_not_require_a_specific_tile_footer(self):
        terminal = Mock()
        terminal.session.api.return_value = [['workspaces',[[['id','overview'],['name','Overview'],['zoomed_tile',['checks']]]]],
            ['tiles',[[['id','checks'],['workspace','overview'],['kind','checks'],['hidden','false']]]]]
        terminal.capture.return_value = 'Overview | connected\nAcceptance: not_evaluated\nSpace c c | Tab focus'
        w.focus(terminal,'checks')
        self.assertEqual(terminal.capture.call_args.args[1],['Overview'])
        terminal.key.assert_not_called()

    def test_inspection_only_terminal_refuses_every_producer_route(self):
        terminal = object.__new__(w.Terminal)
        terminal.session = argparse.Namespace(inspection_only=True)
        with patch.object(w.legacy.Terminal,'palette') as palette:
            for title in ('Launch and view planned run in captured context','Plan ASIC standard / balanced',
                          'Finalize (collect) asic/run','Simulation: Rerun case seeded','Simulation: Launch selected catalog subset'):
                with self.subTest(title=title),self.assertRaisesRegex(AssertionError,'cannot invoke a producer'):
                    terminal.palette(title)
            palette.assert_not_called()

    def test_restart_drops_only_transient_completed_job_handles(self):
        original = [['id','workflow'],['phase','Completed'],['prepared',['exact-bundle']],
                    ['run',['exact-run']],['build_job',[['completed-build']]],['emission_job',[['completed-emit']]]]
        restored = [[key, [] if key in ('build_job','emission_job') else value] for key,value in original]
        self.assertTrue(w.restored_workflow_matches(restored,original))
        self.assertFalse(w.restored_workflow_matches(None,original))
        for key,value in [('phase','Failed'),('prepared',['different-bundle']),('run',['different-run']),
                          ('build_job',[['different-job']])]:
            with self.subTest(key=key):
                changed = [[name,value if name==key else item] for name,item in restored]
                self.assertFalse(w.restored_workflow_matches(changed,original))


class RecoveryContract(unittest.TestCase):
    """Pure file/record fixtures: no launcher, daemon, collection or hardware."""
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='recovery-contract-', dir='/tmp/opencode')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.store = self.root / 'store'
        generation = self.store / 'generations/old'
        generation.mkdir(parents=True)
        sdk = generation / 'sdk/lib/fixture'
        sdk.parent.mkdir(parents=True)
        sdk.write_text('SDK')
        old_daemon = generation / 'apps/daemon.exe'
        old_daemon.parent.mkdir()
        old_daemon.write_text('old daemon')
        old_client = old_daemon.with_name('client.exe')
        old_client.write_text('client')
        asic = self.root / 'asic'
        asic.mkdir()
        self.write(asic / 'receipt.json', dict(provider='fixture'))
        self.old = dict(schema_version=1, generation_id='old', store=str(self.store), project_root=str(self.store / 'project'),
            generation=str(generation), source_layout='ownership-v1', source_files={'source.ml': 'fixture'},
            source_roots=['source.ml'], suite_sources={'suite': {'source.ml': 'fixture'}},
            inputs=dict(asic_generation=str(asic), toolchain='tools', git_dir='git-dir', git='git', dune='dune', python='python'),
            asic_receipt_sha256=w.sha(asic / 'receipt.json'), asic_files={'receipt.json': w.sha(asic / 'receipt.json')},
            captured_files={str(p.relative_to(generation)): w.sha(p) for p in (sdk, old_daemon, old_client)},
            environment={'HARDCAML_ASIC_SYNTHESIS_TASK_LIMIT': '6'}, max_jobs=2,
            provider_command=['retained-provider'], provider_commands={'suite':['retained-provider']},
            git_context=dict(real_git='/usr/bin/git',real_git_sha256=w.sha(Path('/usr/bin/git'))),
            config_files={'hardcaml-workbench-preparation.sexp': 'same-preparation'},
            apps={key:dict(path=str(path), sha256=w.sha(path)) for key,path in (('daemon',old_daemon),('client',old_client))})
        self.write(generation / 'manifest.json', self.old)
        self.failed_dir = self.root / 'failed'
        self.failed_dir.mkdir()
        self.execution_path = self.store / 'execution.json'
        self.execution = dict(status='completed', exit_code=0, attempt_id='original-run',
            plan=dict(stages=['synthesis'], initial_boundary=None), artifacts=[dict(boundary='synthesis')],
            occurrences=[dict(status='completed', exit_code=0)])
        self.write(self.execution_path, self.execution)
        (self.failed_dir / 'execution-original.json').write_bytes(self.execution_path.read_bytes())
        self.reference = [['backend','asic'], ['id','original-run']]
        self.workflow = [['id','original-workflow'], ['phase','Completed'], ['run',[self.reference]],
            ['intent', [['selection', [['flow','standard'],['profile','balanced'],['endpoint','synthesis'],['assignments',[]]]],
                        ['elaboration_only','false']]]]
        self.write(self.failed_dir / 'workflow.json', self.workflow)
        self.collection = [['key','failed-collection'], ['state','failed'], ['attempt',[]], ['acceptance_requested','false'],
            ['run',self.reference], ['execution_file',str(self.execution_path)],
            ['error',['Finalize requires an exact completed fresh physical execution']]]
        self.write(self.failed_dir / 'report-collection.json', self.collection)
        output = self.store / 'original-tool-output.txt'
        output.write_text('original report')
        self.outputs = {str(output): w.sha(output)}
        self.outputs_path = self.root / 'tool-outputs.json'
        self.write(self.outputs_path, self.outputs)
        self.write(self.failed_dir / 'bundle-files.json', self.outputs)
        self.summary_path = self.root / 'resource-summary.json'
        self.summary = dict(completed=True, seen_flow=True, runtime_ceiling_established=True, store=str(self.store),
            manifest_sha256=w.sha(generation / 'manifest.json'), cap_receipt_sha256='old-cap',
            cap_binding=dict(store=str(self.store),manifest_sha256=w.sha(generation / 'manifest.json'),
                asic_generation=str(asic), asic_receipt_sha256=self.old['asic_receipt_sha256']))
        self.write(self.summary_path, self.summary)
        self.failed_path = self.failed_dir / 'receipt.json'
        native_path = self.root/'native-prerequisite.json'
        native = dict(status='passed',store=str(self.store),root=str(self.store/'project'),
            manifest_sha256=w.sha(generation/'manifest.json'),identities={'fixture':'original'},attempts=['original-simulation'])
        self.write(native_path,native)
        self.failed = dict(status='failed', phase='synthesis', eda_jobs=1, store=str(self.store),
            generation=str(generation), manifest_sha256=w.sha(generation / 'manifest.json'), reference=self.reference,
            workflow_id='original-workflow', execution=dict(path=str(self.execution_path), sha256=w.sha(self.execution_path)),
            resource_admission=dict(cap_receipt_sha256='old-cap'),simulation_receipt=str(native_path),
            simulation_receipt_sha256=w.sha(native_path),identities=native['identities'],attempts=native['attempts'])
        self.write(self.failed_path, self.failed)
        self.diagnosis_path = self.root / 'diagnosis.json'
        self.diagnosis = dict(status='blocked_at_production_collection_gate',
            synthesis=dict(run_id='original-run', execution_sha256=w.sha(self.execution_path)),
            receipt_hashes={str(p):w.sha(p) for p in (self.failed_path, self.summary_path,self.outputs_path,
                self.failed_dir / 'report-collection.json')})
        self.write(self.diagnosis_path, self.diagnosis)
        build = self.root / 'reviewed-build'
        self.new_apps = {}
        for key, relative in (('daemon','default/daemon/main.exe'), ('client','default/terminal/main.exe')):
            path = build / relative
            path.parent.mkdir(parents=True)
            path.write_text('reviewed new '+key)
            self.new_apps[key] = dict(path=str(path), sha256=w.sha(path))
        self.descriptor = dict(schema_version=1, kind='workbench-synthesis-collection-recovery-v1', store=str(self.store),
            failed_receipt=self.entry(self.failed_path), diagnosis=self.entry(self.diagnosis_path),
            resource_summary=self.entry(self.summary_path), tool_outputs=self.entry(self.outputs_path),
            wb_build_root=str(build), new_apps=self.new_apps)
        self.descriptor_path = self.root / 'recovery-inputs.json'
        self.write(self.descriptor_path,self.descriptor)

    def new_manifest(self):
        new = json.loads(json.dumps(self.old))
        new.update(generation=str(self.store/'generations/new'), app_recapture=dict(
            previous_generation=self.old['generation'], previous_manifest_sha256=w.sha(Path(self.old['generation'])/'manifest.json'),
            provider_config_environment_preserved=True))
        return new

    @staticmethod
    def write(path, value):
        path.write_text(json.dumps(value))

    @staticmethod
    def entry(path):
        return dict(path=str(path),sha256=w.sha(path))

    def load(self):
        return w.recovery.load_inputs(self.descriptor_path,self.store)

    def test_exact_failed_run_and_proof_admitted_without_launch(self):
        inputs = self.load()
        self.assertEqual(inputs['failed']['execution']['sha256'],w.sha(self.execution_path))

    def test_changed_failed_receipt_or_original_output_rejected(self):
        self.failed_path.write_text('{}')
        with self.assertRaisesRegex(AssertionError,'exact original bytes'):
            self.load()
        self.write(self.failed_path,self.failed)
        Path(next(iter(self.outputs))).write_text('modified report')
        with self.assertRaisesRegex(AssertionError,'preserved original bytes'):
            self.load()

    def test_recovery_rejects_changed_native_prerequisite_before_recapture(self):
        Path(self.failed['simulation_receipt']).write_text('modified native receipt')
        with self.assertRaisesRegex(AssertionError,'native prerequisite receipt bytes'):
            self.load()

    def test_missing_or_wrong_resource_summary_blocks(self):
        self.summary['completed'] = False
        self.write(self.summary_path,self.summary)
        with self.assertRaisesRegex(AssertionError,'exact original bytes'):
            self.load()

    def test_actual_collection_failure_cannot_be_retried(self):
        self.collection = [[k, ['allocated-attempt'] if k=='attempt' else v] for k,v in self.collection]
        self.write(self.failed_dir / 'report-collection.json',self.collection)
        with self.assertRaisesRegex(AssertionError,'unallocated production'):
            self.load()

    def test_execution_changed_or_extended_blocks(self):
        self.execution['plan']['stages'].append('floorplan')
        self.write(self.execution_path,self.execution)
        with self.assertRaisesRegex(AssertionError,'original execution bytes'):
            self.load()

    def test_reviewed_app_hash_and_backend_identity_required(self):
        Path(self.new_apps['daemon']['path']).write_text('unreviewed daemon')
        with self.assertRaisesRegex(AssertionError,'reviewed replacement daemon'):
            self.load()

    def test_captured_recovery_does_not_depend_on_later_build_root_bytes(self):
        Path(self.new_apps['daemon']['path']).write_text('later build')
        w.recovery.load_inputs(self.descriptor_path,self.store,check_app_sources=False)

    def test_transition_allows_new_apps_not_source_provider_or_sdk(self):
        new = self.new_manifest()
        w.recovery.validate_transition(self.old,new,self.store)
        for key,value in [('source_files',{'source.ml':'changed'}), ('asic_files',{}), ('suite_sources',{}),
                          ('environment',{}), ('captured_files',{'sdk/lib/fixture':'changed'}),
                          ('config_files',{'hardcaml-workbench-asic.sexp':'new-scope'}),
                          ('provider_command',['new-provider-scope'])]:
            with self.subTest(key=key), self.assertRaises(AssertionError):
                w.recovery.validate_transition(self.old,dict(new,**{key:value}),self.store)

    def test_history_mutation_detected_before_new_pair(self):
        state = self.store / 'state'
        state.mkdir()
        path = state / 'history.sexp'
        path.write_text('history')
        baseline = w.recovery.history_files(self.store)
        path.write_text('changed')
        self.assertNotEqual(w.recovery.history_files(self.store),baseline)
        with self.assertRaisesRegex(AssertionError,'preserved original bytes'):
            w.recovery.verify_files(baseline,self.store)

    def test_new_collection_must_preserve_failed_record_and_exact_run(self):
        fresh = [['key','new-collection'],['state','completed'],['run',self.reference],['acceptance_requested','false']]
        snapshot = [['finalizations',[self.collection,fresh]]]
        self.assertEqual(w.recovery.fresh_collection(snapshot,[self.collection],self.reference),fresh)
        with self.assertRaisesRegex(AssertionError,'retained failed collection history'):
            w.recovery.fresh_collection([['finalizations',[fresh]]],[self.collection],self.reference)
        with self.assertRaisesRegex(AssertionError,'at most one new collection'):
            w.recovery.fresh_collection([['finalizations',[self.collection,fresh,fresh]]],[self.collection],self.reference)

    def test_recapture_uses_supported_refresh_and_preserves_history(self):
        self.write(self.store / 'manifest.json',self.old)
        state = self.store / 'state'
        state.mkdir()
        history = state / 'history.sexp'
        history.write_text('original history')
        evidence = self.root / 'recapture-evidence'
        evidence.mkdir()
        args = argparse.Namespace(recovery_inputs=self.descriptor_path, store=self.store,root=self.store/'project',
            launcher=Path('/fixture/launcher.py'),source_root=Path('/fixture/source'))
        new = self.new_manifest()
        new['apps'] = self.new_apps
        calls = []
        def refresh(_evidence,_name,argv,**_kwargs):
            calls.append(argv)
            self.write(self.store/'manifest.json',new)
        report = {}
        with patch.object(w,'command',side_effect=refresh),patch.object(w.legacy,'validate_capture',return_value={'capture':'new'}):
            actual = w.recapture(args,evidence,report,self.old)
        self.assertEqual(actual,new)
        self.assertIn('--refresh',calls[0])
        self.assertIn('--apps-only',calls[0])
        self.assertEqual(calls[0][calls[0].index('--synthesis-task-limit')+1],'6')
        self.assertEqual(report['status'],'passed')
        self.assertEqual(history.read_text(),'original history')
        self.assertEqual(report['eda_jobs'],0)
        self.assertTrue(report['history_and_old_capture_unchanged'])

    def test_failed_recovery_admission_precedes_daemon_start(self):
        inputs = self.load()
        args = argparse.Namespace(store=self.store)
        with patch.object(w,'recovery_prerequisite',return_value=({},inputs)),patch.object(
                w,'allocation',side_effect=AssertionError('collection admission absent')),patch.object(w,'pair') as pair:
            with self.assertRaisesRegex(AssertionError,'admission absent'):
                w.recover_collection(args,self.root,{},self.old)
            pair.assert_not_called()

    def test_ordinary_phase_binding_cannot_cross_app_generation(self):
        previous = self.root/'passing-old-phase.json'
        self.write(previous,dict(status='passed',phase='synthesis',store=str(self.store),
            identities={},manifest_sha256=self.failed['manifest_sha256']))
        args = argparse.Namespace(previous=previous,store=self.store,identities={})
        self.write(self.store/'manifest.json',dict(self.old,generation='different-generation'))
        with self.assertRaisesRegex(AssertionError,'same pinned store'):
            w.previous(args,'synthesis')

    def test_transition_rejects_unreviewed_environment_switch(self):
        new = self.new_manifest()
        new['environment']['EXTRA_UNREVIEWED_TOOL_FLAG'] = '1'
        with self.assertRaisesRegex(AssertionError,'exact history scope'):
            w.recovery.validate_transition(self.old,new,self.store)

    def test_real_launcher_app_only_publication_preserves_history_scope(self):
        project = self.store/'project'
        project.mkdir()
        source = project/'source.ml'
        source.write_text('original source')
        self.old['source_files'] = {'source.ml':w.sha(source)}
        self.old['config_files'] = {}
        generation = Path(self.old['generation'])
        for kind in ('simulation','asic','preparation'):
            name = 'hardcaml-workbench-'+kind+'.sexp'
            data = 'retained companion '+kind+' '+str(generation)
            (project/name).write_text(data)
            captured = generation/'config'/name
            captured.parent.mkdir(exist_ok=True)
            captured.write_text(data)
            self.old['config_files'][name] = w.sha(captured)
            self.old['captured_files']['config/'+name] = w.sha(captured)
        self.write(generation/'manifest.json',self.old)
        (self.store/'selected').symlink_to(generation)
        (self.store/'manifest.json').symlink_to('selected/manifest.json')
        state = self.store/'state'
        state.mkdir()
        history = state/'retained-history.sexp'
        history.write_text('original history')
        before = {str(p):w.sha(p) for p in generation.rglob('*') if p.is_file()}
        args = argparse.Namespace(root=self.root,refresh=True,apps_only=True,import_missing_source=False,
            update_owned_support=False,asic_generation=None,sdk_prefix=None,dune=None,git=None,
            wb_build_root=Path(self.descriptor['wb_build_root']),synthesis_task_limit=6,
            expected_daemon_sha256=self.new_apps['daemon']['sha256'],
            expected_client_sha256=self.new_apps['client']['sha256'])
        with patch.object(launcher,'SOURCE_FILES',('source.ml',)),patch.object(launcher,'SOURCE_DIRS',()),patch.object(
                launcher,'show'),patch.object(launcher.subprocess,'run') as native:
            launcher.prepare(args,self.store)
            native.assert_not_called()
        new = json.loads((self.store/'manifest.json').read_text())
        w.recovery.validate_transition(self.old,new,self.store)
        self.assertEqual(history.read_text(),'original history')
        self.assertEqual({str(p):w.sha(p) for p in generation.rglob('*') if p.is_file()},before)
        self.assertEqual(new['apps']['daemon']['sha256'],self.new_apps['daemon']['sha256'])
        self.assertEqual(new['config_files'],self.old['config_files'])
        self.assertEqual(new['provider_command'],self.old['provider_command'])

    def test_app_only_launcher_refuses_dependency_override_before_capture(self):
        args = argparse.Namespace(asic_generation=Path('/other/provider'),sdk_prefix=None,dune=None,git=None)
        receipt = self.root/'new-receipt'
        with self.assertRaisesRegex(RuntimeError,'cannot change dependency'):
            launcher.capture_apps_only(args,self.store,self.old,receipt)
        self.assertFalse((self.store/'generations/new-receipt').exists())

    def test_app_only_launcher_requires_reviewed_pair_before_capture(self):
        args = argparse.Namespace(asic_generation=None,sdk_prefix=None,dune=None,git=None,
            synthesis_task_limit=6,expected_daemon_sha256=None,expected_client_sha256=None)
        with self.assertRaisesRegex(RuntimeError,'both explicit expected app hashes'):
            launcher.capture_apps_only(args,self.store,self.old,self.root/'new-receipt')

    def test_inspection_cannot_recover_missing_or_failed_collection(self):
        self.write(self.store/'manifest.json',self.old)
        args = argparse.Namespace(previous=self.failed_path,store=self.store,root=self.store/'project',
            identities=self.failed['identities'])
        with patch.object(w,'pair') as pair:
            with self.assertRaisesRegex(AssertionError,'already completed collection'):
                w.inspect_completed(args,self.root,{})
            pair.assert_not_called()

    def inspection_fixture(self):
        self.write(self.store/'manifest.json',self.old)
        checkpoint = self.store/'checkpoint'
        checkpoint.mkdir()
        (checkpoint/'state.json').write_text('original checkpoint')
        self.execution['artifacts'][0]['path'] = str(checkpoint)
        self.write(self.execution_path,self.execution)
        (self.failed_dir/'execution-original.json').write_bytes(self.execution_path.read_bytes())
        collected = self.store/'finalizations/collection'
        collected.mkdir(parents=True)
        self.write(collected/'operation.json',dict(status='completed',exit_code=0,acceptance='not_evaluated',
            request=dict(accept=False,execution=str(self.execution_path))))
        self.collection = [[key, 'completed' if key=='state' else [str(collected)] if key=='attempt' else value]
                           for key,value in self.collection]
        self.write(self.failed_dir/'report-collection.json',self.collection)
        self.failed.update(finalization_attempt=str(collected),summary=[],
            execution=dict(path=str(self.execution_path),sha256=w.sha(self.execution_path)))
        self.write(self.failed_path,self.failed)
        return argparse.Namespace(previous=self.failed_path,store=self.store,root=self.store/'project',
            identities=self.failed['identities'],producer_summary=self.summary_path,
            producer_summary_sha256=w.sha(self.summary_path))

    def test_exact_completed_producers_allow_read_only_inspection(self):
        args = self.inspection_fixture()
        prior,workflow,sealed = w.inspection_prerequisite(args)
        self.assertEqual(prior['execution']['sha256'],w.sha(self.execution_path))
        self.assertEqual(workflow,self.workflow)
        self.assertIn(str(self.execution_path),sealed)

    def test_inspection_requires_exact_passing_resource_summary(self):
        args = self.inspection_fixture()
        self.summary_path.write_text('{}')
        with self.assertRaisesRegex(AssertionError,'resource summary exact bytes'):
            w.inspection_prerequisite(args)


if __name__ == '__main__':
    unittest.main()
