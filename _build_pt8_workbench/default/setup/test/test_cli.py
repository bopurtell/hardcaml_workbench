"""Initializer acceptance tests. Run with the already-built main.exe path.

This script never invokes Dune, git, a driver, or a provider.
"""

import concurrent.futures
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


BINARY = str(Path(sys.argv.pop(1)).resolve())
MANIFEST = "hardcaml-workbench.sexp"


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
        return {p.name: p.read_bytes() for p in self.root.iterdir() if p.is_file()}

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
        self.assertEqual((self.root / MANIFEST).read_text(), preview.stdout)
        self.assertEqual(self.snapshot(), {**before, MANIFEST: preview.stdout.encode()})
        self.assertEqual(set(p.name for p in self.root.iterdir()), set(self.snapshot()))

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
        self.assertTrue((child / MANIFEST).is_file())
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
        self.assertIn(str(self.root.resolve() / MANIFEST), created.stdout)
        self.assertEqual((self.root / MANIFEST).read_text(), preview.stdout)
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
        actual = (self.root / MANIFEST).read_text()
        self.assertIn(f"(name project-{winners[0]})", actual)
        for result in results:
            if result.returncode != 0:
                self.assertIn("refusing to overwrite", result.stderr)
        self.assertEqual(self.snapshot(), {**before, MANIFEST: actual.encode()})
        self.assertEqual(set(p.name for p in self.root.iterdir()), set(self.snapshot()))


if __name__ == "__main__":
    unittest.main()
