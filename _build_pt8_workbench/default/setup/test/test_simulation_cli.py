"""Simulation setup CLI acceptance tests. Run with the already-built executable path.

Fixture providers are tiny shell scripts that append each invocation to a calls file,
proving which provider operations (if any) ran. This script never invokes Dune or git.
"""

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


BINARY = str(Path(sys.argv.pop(1)).resolve())
CONFIG = "hardcaml-workbench-simulation.sexp"
CATALOG = ("((protocol_version 1)(suites(((id fifo)(label FIFO)(cases(((id directed)"
           "(label Directed))((id random)(label Random))))(parameters())(default_seed 7)))))")


class SimulationSetupTests(unittest.TestCase):
    def setUp(self):
        # TMPDIR may sit inside a Dune build tree with its own dune-project ancestor.
        self.temporary = tempfile.TemporaryDirectory(prefix="wb-sim-cli-", dir="/tmp")
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name).resolve()
        self.root = self.base / "project"
        (self.root / "src" / "rtl").mkdir(parents=True)
        (self.root / "dune-project").write_text("(lang dune 3.22)\n")
        (self.root / "src" / "dune").write_text("")
        self.calls = self.base / "calls"
        (self.base / "bin").mkdir()

    def provider(self, body, name="provider.sh"):
        path = self.base / "bin" / name
        path.write_text(f'#!/bin/sh\necho "$*" >> "{self.calls}"\n{body}\n')
        path.chmod(0o755)
        return path

    def recorded(self):
        return self.calls.read_text().splitlines() if self.calls.exists() else []

    def invoke(self, *args, success=True, cwd=None):
        result = subprocess.run([BINARY, *map(str, args)], cwd=cwd, capture_output=True,
                                text=True, timeout=30)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result

    def listing(self):
        return sorted(p.name for p in self.root.iterdir())

    def test_dry_run_previews_without_writing_or_running(self):
        provider = self.provider(f"echo '{CATALOG}'")
        result = self.invoke("init", "--root", self.root, "--provider-executable", provider,
                             "--provider-arg", "--counter", "--provider-arg", "/x y/c.exe",
                             "--run-timeout-seconds", "90", "--dry-run")
        out = result.stdout
        self.assertIn(f"Destination:               {self.root / CONFIG}", out)
        self.assertIn("(provider_args (--counter \"/x y/c.exe\"))", out)
        self.assertIn("(run_timeout_seconds 90)", out)
        self.assertIn("Dry run: nothing was written", out)
        self.assertEqual(self.listing(), ["dune-project", "src"])
        self.assertEqual(self.recorded(), [])

    def test_init_then_check_discovers_from_subdirectory(self):
        provider = self.provider(f"echo '{CATALOG}'")
        created = self.invoke("init", "--discover-project", "--provider-executable", provider,
                              cwd=self.root / "src" / "rtl")
        self.assertIn(f"discovered project root {self.root} ", created.stderr)
        self.assertIn(f"Created {self.root / CONFIG}", created.stdout)
        self.assertIn("No provider or test was run.", created.stdout)
        self.assertEqual(self.recorded(), [])
        preview = created.stdout.split("Rendered configuration:\n", 1)[1]
        self.assertTrue(preview.startswith((self.root / CONFIG).read_text()))
        checked = self.invoke("check", "--discover-project", cwd=self.root / "src")
        self.assertIn("Discovery succeeded: 1 suite, 2 cases.", checked.stdout)
        self.assertIn("case directed - Directed", checked.stdout)
        self.assertIn("case random - Random", checked.stdout)
        self.assertIn("No tests were run", checked.stdout)
        self.assertEqual(self.recorded(), ["discover --protocol-version 1"])

    def test_existing_config_and_links_are_refused(self):
        provider = self.provider("exit 0")
        target = self.root / CONFIG
        for make in [lambda: target.write_text("mine\n"),
                     lambda: target.symlink_to(self.base / "missing"),
                     lambda: target.symlink_to(self.root / "dune-project")]:
            make()
            before = os.readlink(target) if target.is_symlink() else target.read_text()
            for extra in [[], ["--dry-run"]]:
                result = self.invoke("init", "--root", self.root, "--provider-executable",
                                     provider, *extra, success=False)
                self.assertIn("refusing to overwrite", result.stderr)
            after = os.readlink(target) if target.is_symlink() else target.read_text()
            self.assertEqual(before, after)
            target.unlink()
        self.assertEqual((self.root / "dune-project").read_text(), "(lang dune 3.22)\n")
        self.assertEqual(self.recorded(), [])

    def test_check_outcomes_and_exit_status(self):
        missing = self.invoke("check", "--root", self.root, success=False)
        self.assertIn("Simulation is not configured", missing.stdout)
        cases = [
            ("echo '((protocol_version 1)(suites()))'", True, "zero suites"),
            ("echo 'build counter.exe first' >&2; exit 2", False, "build counter.exe first"),
            ("echo garbage", False, "invalid discovery output"),
        ]
        for body, ok, fragment in cases:
            with self.subTest(body=body):
                (self.root / CONFIG).unlink(missing_ok=True)
                self.invoke("init", "--root", self.root, "--provider-executable",
                            self.provider(body))
                result = self.invoke("check", "--root", self.root, success=ok)
                self.assertIn(fragment, result.stdout)
                self.assertIn("No tests were run", result.stdout)
        self.assertTrue(all(c == "discover --protocol-version 1" for c in self.recorded()))

    def test_rejections(self):
        provider = self.provider("exit 0")
        for args in [["init", "--root", self.root, "--provider-executable", "provider.sh"],
                     ["init", "--root", self.root, "--discover-project",
                      "--provider-executable", provider],
                     ["init", "--provider-executable", provider],
                     ["init", "--root", self.root / "src", "--provider-executable", provider],
                     ["init", "--root", self.root, "--provider-executable", provider,
                      "--discovery-timeout-seconds", "0"],
                     ["check", "--root", self.root, "--environment", "conda"],
                     ["init", "--root", self.root]]:
            with self.subTest(args=args):
                self.invoke(*args, success=False)
        self.assertEqual(self.listing(), ["dune-project", "src"])
        self.assertEqual(self.recorded(), [])

    def test_help_explains_provider_prerequisites(self):
        for sub in [[], ["init"], ["check"]]:
            result = self.invoke(*sub, "-help")
            self.assertIn("Provider prerequisites (project-owned)", result.stdout)
            self.assertIn("never builds, installs", result.stdout)


if __name__ == "__main__":
    unittest.main()
