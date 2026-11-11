"""Initializer acceptance tests. Run with the already-built main.exe path.

This script never invokes Dune, git, a driver, or a provider.
"""

import concurrent.futures
import os
import resource
import signal
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


BINARY = str(Path(sys.argv.pop(1)).resolve())
MANIFEST = "hardcaml-workbench.sexp"
COMMON_MANIFEST = Path(".workbench") / MANIFEST
CONFIGS = [MANIFEST, "hardcaml-workbench-asic.sexp",
           "hardcaml-workbench-simulation.sexp", "hardcaml-workbench-preparation.sexp"]


class InitializationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="workbench-init-test-")
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.root = self.base / "existing project"
        self.root.mkdir()
        (self.root / "dune-project").write_text("(lang dune 3.22)\n")
        (self.root / "owned.txt").write_bytes(b"user data\x00\n")

    def invoke(self, *args, success=True, cwd=None):
        result = subprocess.run(
            [BINARY, *map(str, args)],
            cwd=cwd,
            capture_output=True,
            text=True,
            timeout=15,
        )
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result

    def snapshot(self):
        return {str(p.relative_to(self.root)): p.read_bytes()
                for p in self.root.rglob("*") if p.is_file()}

    def test_defaults_dry_run_and_preservation(self):
        before = self.snapshot()
        preview = self.invoke("--root", self.root, "--dry-run")
        self.assertEqual(self.snapshot(), before)
        self.assertIn('(name "existing project")', preview.stdout)
        self.assertIn("(lang hardcaml-workbench 1)", preview.stdout)
        self.assertIn("(build_alias @all)", preview.stdout)
        self.assertIn("(test_alias @runtest)", preview.stdout)
        self.assertNotIn("(driver", preview.stdout)
        self.invoke("--root", self.root)
        self.assertEqual((self.root / COMMON_MANIFEST).read_text(), preview.stdout)
        self.assertEqual(self.snapshot(), {**before, str(COMMON_MANIFEST): preview.stdout.encode()})
        self.assertEqual(set(p.name for p in self.root.iterdir()), {*before, ".workbench"})

    def test_explicit_options_and_relative_root(self):
        result = self.invoke(
            "--root", self.root.name, "--project-name", 'chip "quoted" (name)',
            "--driver", "./not-built/driver.exe", "--build-alias", "src/@build",
            "--test-alias", "@check", "--dry-run", cwd=self.base,
        )
        self.assertIn('(name "chip \\"quoted\\" (name)")', result.stdout)
        self.assertIn("(driver ./not-built/driver.exe)", result.stdout)
        self.assertIn("(build_alias src/@build)", result.stdout)
        self.assertIn("(test_alias @check)", result.stdout)
        self.assertFalse((self.root / MANIFEST).exists())

    def test_invalid_options_never_write(self):
        before = self.snapshot()
        for option, value in [
            ("--project-name", ""), ("--project-name", " \t"),
            ("--driver", ""), ("--driver", "/tmp/driver.exe"),
            ("--driver", "./../driver.exe"), ("--driver", "driver.exe"),
            ("--build-alias", "all"), ("--build-alias", "../@all"),
            ("--test-alias", "@"), ("--test-alias", "src//@test"),
        ]:
            with self.subTest(option=option, value=value):
                result = self.invoke("--root", self.root, option, value, success=False)
                self.assertTrue(result.stderr)
                self.assertEqual(self.snapshot(), before)
        for args in [[], ["--unknown"], ["--root", self.root, "--driver"],
                     ["--root", self.root, "--root", self.root],
                     ["--root", self.root, "unexpected"]]:
            self.invoke(*args, success=False)
        self.assertEqual(self.snapshot(), before)

    def test_invalid_directories_and_no_ancestor_search(self):
        child = self.root / "child"
        child.mkdir()
        for path in ["", self.base / "missing", self.root / "owned.txt", child]:
            with self.subTest(path=path):
                self.invoke("--root", path, success=False)
        (child / "dune-project").mkdir()
        self.invoke("--root", child, success=False)
        (child / "dune").write_text("(alias (name local))\n")
        self.invoke("--root", child, success=False)
        self.assertFalse((child / MANIFEST).exists())
        (child / "dune-project").rmdir()
        self.invoke("--root", child, success=False)
        (child / "dune-project").write_text("(lang dune 3.22)\n")
        self.invoke("--root", child)
        self.assertTrue((child / COMMON_MANIFEST).is_file())
        self.assertFalse((self.root / MANIFEST).exists())

    def test_existing_configs_are_preserved_including_invalid(self):
        target = self.root / MANIFEST
        for contents in [b"", b"broken manifest\x00", b"(lang hardcaml-workbench 999)\n"]:
            target.write_bytes(contents)
            for extra in [[], ["--dry-run"]]:
                result = self.invoke("--root", self.root, *extra, success=False)
                self.assertIn("refusing to overwrite", result.stderr)
                self.assertEqual(target.read_bytes(), contents)
        target.unlink()
        self.invoke("--root", self.root)
        target = self.root / COMMON_MANIFEST
        contents = target.read_bytes()
        self.invoke("--root", self.root, success=False)
        self.assertEqual(target.read_bytes(), contents)

    def test_existing_directory_and_symlinks_are_preserved(self):
        target = self.root / MANIFEST
        target.mkdir()
        self.invoke("--root", self.root, success=False)
        self.assertTrue(target.is_dir())
        target.rmdir()
        for destination in [self.base / "missing", self.root / "owned.txt"]:
            target.symlink_to(destination)
            before = os.readlink(target)
            self.invoke("--root", self.root, success=False)
            self.invoke("--root", self.root, "--dry-run", success=False)
            self.assertEqual(os.readlink(target), before)
            target.unlink()
        self.assertEqual((self.root / "owned.txt").read_bytes(), b"user data\x00\n")

    def test_discover_project_from_subdirectory(self):
        deep = self.root / "src" / "rtl"
        deep.mkdir(parents=True)
        (deep / "dune").write_text("(library (name rtl))\n")
        before = self.snapshot()
        preview = self.invoke("--discover-project", "--dry-run", cwd=deep)
        self.assertIn('(name "existing project")', preview.stdout)
        self.assertIn(f"discovered project root {self.root.resolve()} ", preview.stderr)
        self.assertEqual(self.snapshot(), before)
        created = self.invoke("--discover-project", cwd=deep)
        self.assertIn(str(self.root.resolve() / COMMON_MANIFEST), created.stdout)
        self.assertEqual((self.root / COMMON_MANIFEST).read_text(), preview.stdout)
        self.assertFalse((deep / MANIFEST).exists())

    def test_discover_project_conflicts_and_no_marker(self):
        result = self.invoke("--root", self.root, "--discover-project", success=False)
        self.assertIn("cannot be combined", result.stderr)
        result = self.invoke(success=False, cwd=self.root)
        self.assertIn("--root DIR or --discover-project", result.stderr)
        # TMPDIR may sit inside a Dune build tree; /tmp has no dune-project ancestor.
        with tempfile.TemporaryDirectory(prefix="workbench-init-nomarker-", dir="/tmp") as plain:
            (Path(plain) / "dune").write_text("")
            result = self.invoke("--discover-project", "--dry-run", success=False, cwd=plain)
            self.assertIn("no Dune project found", result.stderr)
            self.assertIn("--root DIR", result.stderr)
            self.assertEqual(sorted(p.name for p in Path(plain).iterdir()), ["dune"])
        self.assertFalse((self.root / MANIFEST).exists())

    def test_symlink_root_uses_resolved_basename(self):
        link = self.base / "linked"
        link.symlink_to(self.root, target_is_directory=True)
        result = self.invoke("--root", link, "--dry-run")
        self.assertIn('(name "existing project")', result.stdout)
        self.assertFalse((self.root / MANIFEST).exists())

    def test_concurrent_initialization_has_exactly_one_winner(self):
        before = self.snapshot()

        def run(index):
            return subprocess.run(
                [BINARY, "--root", str(self.root), "--project-name", f"project-{index}"],
                capture_output=True, text=True, timeout=15,
            )

        with concurrent.futures.ThreadPoolExecutor(max_workers=12) as executor:
            results = list(executor.map(run, range(12)))
        winners = [i for i, result in enumerate(results) if result.returncode == 0]
        self.assertEqual(len(winners), 1, [(r.returncode, r.stderr) for r in results])
        actual = (self.root / COMMON_MANIFEST).read_text()
        self.assertIn(f"(name project-{winners[0]})", actual)
        for result in results:
            if result.returncode != 0:
                self.assertIn("refusing to overwrite", result.stderr)
        self.assertEqual(self.snapshot(), {**before, str(COMMON_MANIFEST): actual.encode()})
        self.assertEqual(set(p.name for p in self.root.iterdir()), {*before, ".workbench"})

    def seed_configs(self):
        # Copy bytes, including future/invalid schemas, without changing provider identity.
        for index, name in enumerate(CONFIGS):
            (self.root / name).write_bytes(f"provider-{index} ./root-relative\n".encode() + b"\x00")

    def migrate(self, *args, **kwargs):
        return self.invoke("--root", self.root, "--migrate-configs", *args, **kwargs)

    def test_migration_dry_run_copies_all_four_and_repeat(self):
        self.seed_configs()
        before = self.snapshot()
        preview = self.migrate("--dry-run")
        self.assertEqual(self.snapshot(), before)
        self.assertFalse((self.root / ".workbench").exists())
        self.assertIn("Create directory", preview.stdout)
        self.assertEqual(preview.stdout.count("Copy "), 4)
        for name in CONFIGS:
            self.assertIn(f"{self.root / name} -> {self.root / '.workbench' / name}", preview.stdout)
        self.migrate()
        after = self.snapshot()
        for name in CONFIGS:
            self.assertEqual(after[name], before[name])
            self.assertEqual(after[str(Path('.workbench') / name)], before[name])
        self.assertIn("No configuration copies needed", self.migrate().stdout)
        self.assertIn("No configuration copies needed", self.migrate("--dry-run").stdout)
        self.assertEqual(self.snapshot(), after)

    def test_migration_preflights_entire_set_and_accepts_equal_targets(self):
        self.seed_configs()
        common = self.root / ".workbench"
        common.mkdir()
        last = common / CONFIGS[-1]
        last.write_bytes(b"conflicting bytes")
        before = self.snapshot()
        for args in [[], ["--dry-run"]]:
            result = self.migrate(*args, success=False)
            self.assertIn("Conflicting configuration", result.stderr)
            self.assertEqual(self.snapshot(), before)
        last.write_bytes((self.root / CONFIGS[-1]).read_bytes())
        self.assertEqual(self.migrate("--dry-run").stdout.count("Copy "), 3)
        self.migrate()
        self.assertEqual(last.read_bytes(), (self.root / CONFIGS[-1]).read_bytes())

    def test_migration_rejects_unsafe_directories_and_entries(self):
        self.seed_configs()
        common = self.root / ".workbench"
        external = self.base / "external"
        external.mkdir()
        for kind in ["file", "symlink", "dangling"]:
            with self.subTest(kind=kind):
                if kind == "file":
                    common.write_text("not a directory")
                else:
                    common.symlink_to(external if kind == "symlink" else self.base / "missing")
                self.migrate("--dry-run", success=False)
                self.migrate(success=False)
                common.unlink()
        common.mkdir()
        for parent in [self.root, common]:
            for name in CONFIGS:
                original = parent / name
                saved = original.read_bytes() if original.exists() else None
                if saved is not None:
                    original.unlink()
                original.symlink_to(self.base / "missing")
                self.migrate(success=False)
                self.assertTrue(original.is_symlink())
                original.unlink()
                if saved is not None:
                    original.write_bytes(saved)
        self.assertEqual(list(external.iterdir()), [])

    def test_migration_partial_io_failure_retains_usable_legacy_and_can_resume(self):
        (self.root / CONFIGS[0]).write_bytes(b"first configuration\n")
        (self.root / CONFIGS[1]).write_bytes(b"x" * 4096)
        before = self.snapshot()

        def limit_writes():
            signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
            resource.setrlimit(resource.RLIMIT_FSIZE, (128, 128))

        result = subprocess.run(
            [BINARY, "--root", str(self.root), "--migrate-configs"],
            capture_output=True, text=True, timeout=15, preexec_fn=limit_writes)
        self.assertNotEqual(result.returncode, 0)
        for name, data in before.items():
            self.assertEqual((self.root / name).read_bytes(), data)
        common = self.root / ".workbench"
        self.assertEqual((common / CONFIGS[0]).read_bytes(), before[CONFIGS[0]])
        self.assertFalse((common / CONFIGS[1]).exists())
        self.assertEqual(sorted(p.name for p in common.iterdir()), [CONFIGS[0]])
        self.migrate()
        self.assertEqual((common / CONFIGS[1]).read_bytes(), before[CONFIGS[1]])

    def test_migration_rejects_nonregular_files_before_any_copy(self):
        (self.root / CONFIGS[0]).write_bytes(b"first configuration")
        target = self.root / CONFIGS[-1]
        target.mkdir()
        self.migrate(success=False)
        self.assertFalse((self.root / ".workbench").exists())
        target.rmdir()
        os.mkfifo(target)
        self.migrate(success=False)
        self.assertFalse((self.root / ".workbench").exists())

    def test_migration_empty_common_only_discovery_and_invalid_options(self):
        self.assertIn("No configuration copies needed", self.migrate().stdout)
        self.assertFalse((self.root / ".workbench").exists())
        common = self.root / ".workbench"
        common.mkdir()
        (common / CONFIGS[2]).write_bytes(b"common-only provider identity")
        before = self.snapshot()
        self.invoke("--discover-project", "--migrate-configs", cwd=self.root)
        self.assertEqual(self.snapshot(), before)
        for option in ["--project-name", "--driver", "--build-alias", "--test-alias"]:
            self.migrate(option, "value", success=False)
            self.assertEqual(self.snapshot(), before)

    def test_init_common_directory_safety_and_legacy_compatibility(self):
        common = self.root / ".workbench"
        common.symlink_to(self.base, target_is_directory=True)
        self.invoke("--root", self.root, "--dry-run", success=False)
        self.invoke("--root", self.root, success=False)
        self.assertFalse((self.base / MANIFEST).exists())
        common.unlink()
        common.mkdir()
        (common / CONFIGS[2]).write_bytes(b"existing provider")
        self.invoke("--root", self.root, "--driver", "./bin/driver.exe")
        self.assertIn("(driver ./bin/driver.exe)", (common / MANIFEST).read_text())
        self.assertEqual((common / CONFIGS[2]).read_bytes(), b"existing provider")
        self.assertFalse((self.root / MANIFEST).exists())
        self.invoke("--root", self.root, success=False)


if __name__ == "__main__":
    unittest.main()
