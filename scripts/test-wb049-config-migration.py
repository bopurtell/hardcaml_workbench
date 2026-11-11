#!/usr/bin/env python3
"""Exercise a prebuilt initializer's migration CLI in disposable fixtures.

Usage: python3 -B scripts/test-wb049-config-migration.py --init /path/to/setup/main.exe
No builds, servers, providers, Git operations or real project configuration edits.
"""
import argparse
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--init', required=True, type=Path)
options, remaining = parser.parse_known_args()
INIT = options.init.resolve(strict=True)
NAMES = ('hardcaml-workbench.sexp', 'hardcaml-workbench-asic.sexp',
         'hardcaml-workbench-simulation.sexp', 'hardcaml-workbench-preparation.sexp')


class MigrationCLI(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='wb049-cli-', dir='/tmp/opencode')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'dune-project').write_text('(lang dune 3.22)\n(name fixture)\n')
        self.payloads = {name: ('; exact bytes for ' + name + '\n(unknown future schema)\n').encode()
                         for name in NAMES}

    def run_init(self, *args, success=True):
        result = subprocess.run([str(INIT), '--root', str(self.root), *args],
                                cwd='/', capture_output=True, timeout=20)
        output = (result.stdout + result.stderr).decode(errors='replace')
        self.assertEqual(result.returncode == 0, success, output)
        return output

    def populate(self):
        for name, data in self.payloads.items():
            (self.root / name).write_bytes(data)

    def snapshot(self):
        return {str(path.relative_to(self.root)):
                ('link', path.readlink()) if path.is_symlink() else
                ('dir',) if path.is_dir() else ('file', path.stat().st_ino, path.read_bytes())
                for path in self.root.rglob('*')}

    def test_dry_run_describes_all_copies_without_writes(self):
        self.populate()
        before = self.snapshot()
        output = self.run_init('--migrate-configs', '--dry-run')
        for name in NAMES:
            self.assertIn(str(self.root / name), output)
            self.assertIn(str(self.root / '.workbench' / name), output)
        self.assertEqual(self.snapshot(), before)

    def test_copy_retains_exact_originals_and_is_idempotent(self):
        self.populate()
        originals = {name: (self.root / name).stat().st_ino for name in NAMES}
        self.run_init('--migrate-configs')
        for name, data in self.payloads.items():
            self.assertEqual((self.root / name).read_bytes(), data)
            self.assertEqual((self.root / name).stat().st_ino, originals[name])
            common = self.root / '.workbench' / name
            self.assertEqual(common.read_bytes(), data)
            self.assertNotEqual(common.stat().st_ino, originals[name])
        before = self.snapshot()
        self.run_init('--migrate-configs')
        self.assertEqual(self.snapshot(), before)

    def test_conflict_preflights_whole_set_before_writes(self):
        self.populate()
        (self.root / '.workbench').mkdir()
        conflict = self.root / '.workbench' / NAMES[-1]
        conflict.write_bytes(self.payloads[NAMES[-1]] + b'\n')
        before = self.snapshot()
        for flags in (('--migrate-configs', '--dry-run'), ('--migrate-configs',)):
            output = self.run_init(*flags, success=False)
            self.assertIn(str(conflict), output)
            self.assertIn(str(self.root / NAMES[-1]), output)
            self.assertEqual(self.snapshot(), before)

    def test_unsafe_common_directory_and_dangling_file_fail_closed(self):
        self.populate()
        common = self.root / '.workbench'
        common.symlink_to(self.root / 'missing', target_is_directory=True)
        before = self.snapshot()
        self.run_init('--migrate-configs', success=False)
        self.assertEqual(self.snapshot(), before)
        common.unlink()
        common.mkdir()
        (common / NAMES[0]).symlink_to(self.root / 'missing')
        before = self.snapshot()
        self.run_init('--migrate-configs', success=False)
        self.assertEqual(self.snapshot(), before)

    def test_empty_and_common_only_are_noops(self):
        before = self.snapshot()
        self.run_init('--migrate-configs')
        self.assertEqual(self.snapshot(), before)
        common = self.root / '.workbench'
        common.mkdir()
        for name, data in self.payloads.items():
            (common / name).write_bytes(data)
        before = self.snapshot()
        self.run_init('--migrate-configs')
        self.assertEqual(self.snapshot(), before)

    def test_initializer_writes_common_and_refuses_either_existing_location(self):
        self.run_init('--driver', './app/driver.exe')
        common = self.root / '.workbench' / NAMES[0]
        self.assertIn(b'./app/driver.exe', common.read_bytes())
        self.assertFalse((self.root / NAMES[0]).exists())
        before = self.snapshot()
        self.run_init(success=False)
        self.assertEqual(self.snapshot(), before)
        common.rename(self.root / NAMES[0])
        before = self.snapshot()
        self.run_init(success=False)
        self.assertEqual(self.snapshot(), before)


if __name__ == '__main__':
    unittest.main(argv=[sys.argv[0], *remaining])
