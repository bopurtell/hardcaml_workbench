#!/usr/bin/env python3
"""WB-049 real example consumers, with inert temporary fixtures only.

No build, daemon, EDA, live configuration, evidence or Git mutation. Run from
any cwd; --example-root can select a separate hardcaml_asic_example checkout.
"""
import argparse
import importlib.util
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--example-root', type=Path,
                    default=Path(__file__).resolve().parents[2] / 'hardcaml_asic_example')
options, remaining = parser.parse_known_args()
EXAMPLE = options.example_root.resolve(strict=True)
sys.path.insert(0, str(EXAMPLE / 'integration/workbench'))
sys.path.insert(0, str(EXAMPLE / 'scripts'))
import config_location as location
import workbench_dev as dev


def load(name, relative):
    spec = importlib.util.spec_from_file_location(name, EXAMPLE / relative)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


main_tests = load('wb049_main_tests', 'scripts/test_workbench_main.py')
installer_tests = load('wb049_installer_tests', 'scripts/test-install-fifo-simulation.py')
main = main_tests.main
installer = installer_tests.installer
temporary_directory = tempfile.TemporaryDirectory


def private_temp(*args, **kwargs):
    kwargs['dir'] = '/tmp/opencode'
    return temporary_directory(*args, **kwargs)


class LookupTests(unittest.TestCase):
    def setUp(self):
        self.temp = private_temp(prefix='wb049-lookup-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_all_four_basenames_legacy_common_equal_and_byte_conflict(self):
        for name in location.BASENAMES:
            with self.subTest(name=name):
                old, common = self.root / name, self.root / '.workbench' / name
                self.assertEqual(location.copies(self.root, name), {})
                self.assertEqual(location.destinations(self.root, name), (old,))
                old.write_bytes(b'same\x00bytes\n')
                self.assertEqual(location.selected(self.root, name), old)
                common.parent.mkdir(exist_ok=True)
                common.write_bytes(old.read_bytes())
                self.assertEqual(location.selected(self.root, name), common)
                self.assertEqual(location.destinations(self.root, name), (common, old))
                common.write_bytes(old.read_bytes() + b'\n')
                with self.assertRaisesRegex(RuntimeError, 'Conflicting configuration files') as error:
                    location.selected(self.root, name)
                self.assertIn(str(old), str(error.exception))
                self.assertIn(str(common), str(error.exception))
                old.unlink()
                self.assertEqual(location.selected(self.root, name), common)

    def test_unsafe_common_never_falls_back(self):
        name = location.BASENAMES[0]
        old, common = self.root / name, self.root / '.workbench' / name
        old.write_bytes(b'legacy')
        common.parent.mkdir()
        for kind in ('dangling', 'symlink', 'directory', 'fifo', 'large'):
            with self.subTest(kind=kind):
                if kind in ('dangling', 'symlink'):
                    common.symlink_to(old if kind == 'symlink' else self.root / 'missing')
                elif kind == 'directory':
                    common.mkdir()
                elif kind == 'fifo':
                    os.mkfifo(common)
                else:
                    common.write_bytes(b'x' * (1024 * 1024 + 1))
                with self.assertRaises(RuntimeError):
                    location.selected(self.root, name)
                common.rmdir() if kind == 'directory' else common.unlink()
        common.parent.rmdir()
        common.parent.symlink_to(self.root, target_is_directory=True)
        with self.assertRaisesRegex(RuntimeError, 'symlink'):
            location.selected(self.root, name)


class MainConsumers(unittest.TestCase):
    # Reuse inert launcher fixtures without inheriting tests that probe tools.
    file = main_tests.MainTest.file
    prepare = main_tests.MainTest.prepare
    publish = main_tests.MainTest.publish

    def setUp(self):
        with patch.object(tempfile, 'TemporaryDirectory', side_effect=private_temp):
            main_tests.MainTest.setUp(self)

    def common(self, duplicate=False):
        for kind in main.KINDS:
            old = self.root / ('hardcaml-workbench-' + kind + '.sexp')
            common = self.root / '.workbench' / old.name
            self.file(common, old.read_bytes())
            if not duplicate:
                old.unlink()

    def test_common_only_prepare_publish_and_verify_preserve_root_meaning(self):
        self.common()
        value = self.prepare()
        self.publish()
        main.verify_install(self.root, self.store, published=True)
        for kind in main.KINDS:
            path = main.companion(self.root, kind)
            self.assertEqual(path.parent, self.root / '.workbench')
            self.assertFalse((self.root / path.name).exists())
        fields = dict(main.parse(main.companion(self.root, 'asic').read_text()))
        self.assertEqual(fields['project_executable'], str(self.root / '_build/default' / main.TARGETS[0]))
        self.assertEqual(value['project_root'], str(self.root))

    def test_identical_duplicates_publish_both_and_select_common(self):
        self.common(duplicate=True)
        self.prepare()
        result = self.publish()
        main.verify_install(self.root, self.store, published=True)
        for kind in main.KINDS:
            common = main.companion(self.root, kind)
            self.assertEqual(common.parent, self.root / '.workbench')
            self.assertEqual(common.read_bytes(), (self.root / common.name).read_bytes())
            self.assertEqual(len(result['config_paths'][kind]), 2)

    def test_conflict_blocks_publish_before_any_write(self):
        self.common(duplicate=True)
        self.prepare()
        common = main.companion(self.root, 'asic')
        common.write_bytes(b'unknown edit')
        with self.assertRaisesRegex(RuntimeError, 'Conflicting'):
            self.publish()
        self.assertFalse((self.store / 'publications').exists())
        self.assertEqual(common.read_bytes(), b'unknown edit')
        for kind in main.KINDS:
            self.assertEqual((self.root / ('hardcaml-workbench-' + kind + '.sexp')).read_bytes(), self.originals[kind])

    def test_dual_publication_partial_failure_restores_both_locations(self):
        self.common(duplicate=True)
        self.prepare()
        write = main.write
        failed = False
        def fail(path, data):
            nonlocal failed
            if path == self.root / 'hardcaml-workbench-asic.sexp' and not failed:
                failed = True
                raise OSError('injected dual-copy failure')
            return write(path, data)
        with patch.object(main, 'write', side_effect=fail):
            with self.assertRaisesRegex(OSError, 'injected dual-copy'):
                self.publish()
        for kind in main.KINDS:
            common = main.companion(self.root, kind)
            self.assertEqual(common.read_bytes(), self.originals[kind])
            self.assertEqual((self.root / common.name).read_bytes(), self.originals[kind])
        self.assertFalse((self.store / 'publication-pending.json').exists())


class InstallerConsumers(unittest.TestCase):
    def install(self, args=None):
        with patch.object(installer.subprocess, 'run', side_effect=AssertionError('unexpected build')), \
             patch.object(installer.subprocess, 'Popen', side_effect=AssertionError('unexpected process')):
            return installer_tests.InstallerTests.install(self, args)

    def setUp(self):
        with patch.object(tempfile, 'TemporaryDirectory', side_effect=private_temp):
            installer_tests.InstallerTests.setUp(self)

    def test_common_only_owned_refresh_does_not_recreate_legacy(self):
        self.install()
        common = self.root / '.workbench' / self.config.name
        common.parent.mkdir()
        self.config.rename(common)
        result = self.install()
        self.assertFalse(self.config.exists())
        self.assertEqual(installer.digest(common.read_bytes()), result['config_sha256'])

    def test_identical_duplicates_refresh_both(self):
        self.install()
        common = self.root / '.workbench' / self.config.name
        common.parent.mkdir()
        common.write_bytes(self.config.read_bytes())
        result = self.install()
        self.assertEqual(common.read_bytes(), self.config.read_bytes())
        self.assertEqual(installer.digest(common.read_bytes()), result['config_sha256'])

    def test_conflict_refused_before_build_or_receipt(self):
        self.install()
        common = self.root / '.workbench' / self.config.name
        common.parent.mkdir()
        common.write_bytes(b'edited')
        before = set(self.root.rglob('*'))
        with patch.object(installer.subprocess, 'run', side_effect=AssertionError('unexpected build')):
            with self.assertRaisesRegex(RuntimeError, 'Conflicting'):
                self.install(['--build'])
        self.assertEqual(set(self.root.rglob('*')), before)
        self.assertEqual(common.read_bytes(), b'edited')

    def test_dual_refresh_failure_restores_owned_config_and_manifest(self):
        self.install()
        common = self.root / '.workbench' / self.config.name
        common.parent.mkdir()
        old = self.config.read_bytes()
        common.write_bytes(old)
        ownership = self.root / '.dev/fifo-simulation-install.json'
        before = ownership.read_bytes()
        replace = installer.replace_bytes
        failed = False
        def fail(path, data):
            nonlocal failed
            if path == self.config and not failed:
                failed = True
                raise OSError('injected duplicate refresh failure')
            return replace(path, data)
        with patch.object(installer, 'replace_bytes', side_effect=fail):
            with self.assertRaisesRegex(OSError, 'duplicate refresh failure'):
                self.install()
        self.assertEqual(common.read_bytes(), old)
        self.assertEqual(self.config.read_bytes(), old)
        self.assertEqual(ownership.read_bytes(), before)


class DevelopmentPublication(unittest.TestCase):
    def setUp(self):
        self.temp = private_temp(prefix='wb049-dev-')
        self.addCleanup(self.temp.cleanup)
        self.store = Path(self.temp.name)
        self.project = self.store / 'project'
        self.project.mkdir()
        self.old = self.generation('old', b'old')
        self.new = self.generation('new', b'new')
        dev.select_generation(self.store, self.old['generation'])
        (self.project / '.workbench').mkdir()
        for kind in dev.CONFIGS:
            name = dev.config_name(kind)
            for path in (self.project / name, self.project / '.workbench' / name):
                path.write_bytes(b'old')
        self.receipt = self.store / 'receipts/new'
        self.receipt.mkdir(parents=True)

    def generation(self, key, data):
        generation = self.store / 'generations' / key
        (generation / 'config').mkdir(parents=True)
        for kind in dev.CONFIGS:
            (generation / 'config' / dev.config_name(kind)).write_bytes(data)
        return dict(generation=str(generation),
                    config_files={dev.config_name(kind): dev.sha(generation / 'config' / dev.config_name(kind))
                                  for kind in dev.CONFIGS})

    def test_publish_and_crash_recovery_cover_both_locations(self):
        # Source inventories are outside this transaction test; its durable
        # journal, file replacement and explicit recovery are exercised for real.
        replace = dev.replace_regular
        calls = 0
        def crash(path, data):
            nonlocal calls
            calls += 1
            if calls == 2:
                raise KeyboardInterrupt('injected crash')
            replace(path, data)
        with patch.object(dev, 'verify'), patch.object(dev, 'replace_regular', side_effect=crash):
            with self.assertRaises(KeyboardInterrupt):
                dev.publish(self.store, self.old, self.new, self.receipt)
        with self.assertRaisesRegex(RuntimeError, 'interrupted configuration publication'):
            dev.unsettled(self.store)
        dev.recover_publication(self.store)
        for kind in dev.CONFIGS:
            for path in dev.config_paths(self.project, kind):
                self.assertEqual(path.read_bytes(), b'old')
        receipt = self.store / 'receipts/retry'
        receipt.mkdir()
        with patch.object(dev, 'verify'):
            dev.publish(self.store, self.old, self.new, receipt)
        for kind in dev.CONFIGS:
            self.assertEqual(dev.config_paths(self.project, kind)[0].parent, self.project / '.workbench')
            for path in dev.config_paths(self.project, kind):
                self.assertEqual(path.read_bytes(), b'new')

    def test_common_only_publication_does_not_recreate_root_copies(self):
        for kind in dev.CONFIGS:
            (self.project / dev.config_name(kind)).unlink()
        with patch.object(dev, 'verify'):
            dev.publish(self.store, self.old, self.new, self.receipt)
        for kind in dev.CONFIGS:
            self.assertFalse((self.project / dev.config_name(kind)).exists())
            self.assertEqual(dev.config_paths(self.project, kind)[0].read_bytes(), b'new')

    def test_development_verifier_selects_common_and_rejects_conflicts(self):
        manifest = dict(self.old, project_root=str(self.project), store=str(self.store),
                        captured_files={'config/' + name: digest for name, digest in self.old['config_files'].items()},
                        inputs=dict(asic_generation=self.old['generation']),
                        asic_files={}, asic_receipt_sha256='receipt')
        sha = dev.sha
        def digest(path):
            return 'receipt' if Path(path).name == 'receipt.json' else sha(path)
        with patch.object(dev, 'require_source_layout'), patch.object(dev, 'verify_hashes'), \
             patch.object(dev, 'sha', side_effect=digest):
            dev.verify(manifest)
            common = self.project / '.workbench' / dev.config_name('simulation')
            common.write_bytes(b'unknown edit')
            with self.assertRaisesRegex(RuntimeError, 'Conflicting'):
                dev.verify(manifest)


if __name__ == '__main__':
    unittest.main(argv=[sys.argv[0], *remaining])
