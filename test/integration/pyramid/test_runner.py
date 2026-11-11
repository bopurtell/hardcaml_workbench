"""Controlled registration and runner regressions; never launch real tools."""

import ast
import contextlib
import importlib.util
import io
import json
import os
import pathlib
import re
import runpy
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[2]
ENDPOINTS = (
    "elaboration", "synthesis", "floorplan", "placement",
    "cts", "routing", "timing", "signoff",
)


def forms(path):
    """Read the small, unquoted Dune selector subset used by these registrations."""
    text = re.sub(r";[^\n]*", "", path.read_text())
    stack = [[]]
    for token in re.findall(r"\(|\)|[^\s()]+", text):
        if token == "(":
            child = []
            stack[-1].append(child)
            stack.append(child)
        elif token == ")":
            stack.pop()
        else:
            stack[-1].append(token)
    if len(stack) != 1:
        raise AssertionError(f"unbalanced registration: {path}")
    return stack[0]


def field(form, name):
    return next((x[1:] for x in form[1:] if isinstance(x, list) and x[0] == name), [])


def flatten(form):
    for value in form:
        if isinstance(value, list):
            yield from flatten(value)
        else:
            yield value


class RegistrationTests(unittest.TestCase):
    def setUp(self):
        self.root = forms(ROOT / "dune")
        self.index = forms(ROOT / "test/dune")
        self.actions = forms(HERE / "dune")

    def test_exact_public_selection_and_forwarding(self):
        for endpoint in (*ENDPOINTS, "pyramid"):
            name = "real-" + endpoint
            root = next(f for f in self.root if field(f, "name") == ["test-" + name])
            self.assertEqual(field(root, "deps"), [["alias", "test/" + name]])
            index = next(f for f in self.index if field(f, "name") == [name])
            self.assertEqual(field(index, "deps"), [["alias", "integration/pyramid/" + name]])

    def test_external_rules_are_fresh_locked_and_explicit(self):
        rules = [f for f in self.actions if f[0] == "rule" and field(f, "alias")[0].startswith("real-")]
        self.assertEqual(len(rules), 9)
        locks = set()
        for rule in rules:
            with self.subTest(alias=field(rule, "alias")):
                self.assertIn(["universe"], field(rule, "deps"))
                self.assertIn(["sandbox", "none"], field(rule, "deps"))
                locks.add(tuple(field(rule, "locks")))
                action = list(flatten(field(rule, "action")))
                self.assertEqual(action.count("%{dep:runner.py}"), 1)
                self.assertIn("%{env:HARDCAML_WORKBENCH_REAL_TEST_CONFIG=}", action)
                for app in ("daemon", "terminal"):
                    self.assertIn("%{exe:../../../" + app + "/main.exe}", action)
        self.assertEqual(locks, {("real-eda",)})

    def test_pyramid_is_one_serial_runner_invocation(self):
        for endpoint in (*ENDPOINTS, "pyramid"):
            rule = next(f for f in self.actions if field(f, "alias") == ["real-" + endpoint])
            action = list(flatten(field(rule, "action")))
            self.assertEqual(action.count("run"), 1)
            if endpoint == "pyramid":
                self.assertIn("--pyramid", action)
                self.assertNotIn("--endpoint", action)
            else:
                self.assertEqual(action[action.index("--endpoint") + 1], endpoint)
            self.assertEqual(
                [d for d in field(rule, "deps") if isinstance(d, list) and d[0] == "alias"],
                [["alias", "real-inputs"]],
            )

    def test_declared_runner_source_closure_is_self_contained(self):
        tree = ast.parse((HERE / "runner.py").read_text())
        imports = set()
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                imports.update(alias.name.split(".")[0] for alias in node.names)
            elif isinstance(node, ast.ImportFrom):
                self.assertEqual(node.level, 0, "relative helper import needs a Dune dependency")
                imports.add(node.module.split(".")[0])
        self.assertLessEqual(imports, sys.stdlib_module_names,
                             "repository helpers must be declared in real actions and controlled sandbox deps")

    def test_default_local_and_contract_closures_exclude_real_actions(self):
        # Follow root/index selector edges, including the controlled-test edge.
        graph = {}
        for directory, entries in ((ROOT, self.root), (ROOT / "test", self.index), (HERE, self.actions)):
            for form in entries:
                names = field(form, "name") if form[0] == "alias" else field(form, "alias")
                if not names:
                    continue
                key = (directory / names[0]).resolve()
                graph[key] = [
                    (directory / dep[1]).resolve()
                    for dep in field(form, "deps")
                    if isinstance(dep, list) and dep[0] in ("alias", "alias_rec")
                ]
        # Dune's recursive @runtest selects descendant runtest aliases even
        # without an explicit root stanza. Model that edge rather than treating
        # a nonexistent root alias as an empty (vacuously safe) graph.
        graph.setdefault(ROOT / "runtest", []).extend(
            key for key in tuple(graph) if key.name == "runtest" and key != ROOT / "runtest"
        )
        for entry in (ROOT / "test-local", ROOT / "test-contracts", ROOT / "runtest", HERE / "runtest"):
            pending, seen = [entry], set()
            while pending:
                key = pending.pop()
                if key in seen:
                    continue
                seen.add(key)
                self.assertNotIn(key.name, {
                    prefix + endpoint
                    for prefix in ("real-", "test-real-")
                    for endpoint in (*ENDPOINTS, "pyramid")
                }, str(key))
                pending.extend(graph.get(key, []))
            self.assertIn(HERE / "runtest", seen, "controlled regression must be selected")
        # Rules with real external work have only explicit real aliases and no
        # targets: @all cannot select them as file-producing build rules.
        for rule in self.actions:
            action = list(flatten(field(rule, "action")))
            if "%{dep:runner.py}" in action and "--self-test" not in action:
                self.assertTrue(field(rule, "alias")[0].startswith("real-"))
                self.assertEqual(field(rule, "targets"), [])
            if "--self-test" in action:
                self.assertEqual(field(rule, "alias"), ["runtest"])
                self.assertNotIn("--endpoint", action)
                self.assertNotIn("--pyramid", action)


class PrelaunchTests(unittest.TestCase):
    def reject_without_launch(self, arguments, expected):
        """Run the real CLI with process creation trapped, including imports."""
        output = io.StringIO()
        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.dict(os.environ))
            os.environ.pop("HARDCAML_WORKBENCH_REAL_TEST_CONFIG", None)
            stack.enter_context(mock.patch.object(sys, "argv", [
                str(HERE / "runner.py"), *arguments,
                "--daemon", sys.executable,
                "--client", sys.executable,
            ]))
            stack.enter_context(contextlib.redirect_stdout(output))
            stack.enter_context(contextlib.redirect_stderr(output))
            launches = [stack.enter_context(mock.patch(target, side_effect=AssertionError("process creation before validation")))
                        for target in ("subprocess.Popen", "os.system", "os.fork", "os.posix_spawn", "os.posix_spawnp")]
            with self.assertRaises((SystemExit, ValueError)) as error:
                runpy.run_path(str(HERE / "runner.py"), run_name="__main__")
            if isinstance(error.exception, SystemExit):
                self.assertNotEqual(error.exception.code, 0)
            for launch in launches:
                launch.assert_not_called()
        self.assertRegex((output.getvalue() + str(error.exception)).lower(), expected)

    def test_missing_config_rejected_for_every_selection_without_process_creation(self):
        for endpoint in ENDPOINTS:
            with self.subTest(endpoint=endpoint):
                self.reject_without_launch(["--endpoint", endpoint, "--config", ""], "config")
        self.reject_without_launch(["--pyramid", "--config", ""], "config")

    def test_unset_config_environment_does_not_fall_back_to_a_real_project(self):
        self.reject_without_launch(["--endpoint", "elaboration"], "config")

    def test_missing_selection_is_not_an_implicit_full_flow(self):
        self.reject_without_launch([], "required|selection|endpoint|pyramid")

    def test_invalid_endpoint_cannot_launch(self):
        self.reject_without_launch(["--endpoint", "not-a-stage"], "invalid choice|endpoint")

    def test_endpoint_and_pyramid_are_mutually_exclusive(self):
        self.reject_without_launch(["--endpoint", "elaboration", "--pyramid"], "not allowed|exclusive|selection")


def load_runner():
    spec = importlib.util.spec_from_file_location("controlled_pyramid_runner", HERE / "runner.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ControlledExecutionTests(unittest.TestCase):
    def setUp(self):
        self.runner = load_runner()
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        self.source = self.root / "source"
        self.evidence = self.root / "evidence"
        self.source.mkdir()
        self.evidence.mkdir()
        identity = self.root / "controlled-sdk-receipt.json"
        identity.write_text('{"controlled": true}\n')
        self.config = dict(
            schema_version=1, evidence_root=str(self.evidence),
            serialization_lock=str(self.root / "execution.lock"),
            build_lock=str(self.root / "build.lock"),
            source_closure=[dict(source=str(self.source), destination="project")],
            project="project", build_target="bin/project.exe",
            provider=sys.executable, dune=sys.executable, python=sys.executable,
            toolchain=str(self.source), support_tools=str(self.source), pdk_root=str(self.source),
            environment={"PATH": "/usr/bin"}, sdk_identity_files=[str(identity)],
            flow="standard", profile="balanced", assignments=[],
        )
        self.config_path = self.root / "config.json"

    @contextlib.contextmanager
    def cli(self, arguments):
        self.config_path.write_text(json.dumps(self.config))
        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.object(sys, "argv", [
                str(HERE / "runner.py"), *arguments, "--config", str(self.config_path),
                "--daemon", sys.executable, "--client", sys.executable,
            ]))
            stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
            stack.enter_context(mock.patch.object(self.runner.signal, "signal"))
            stack.enter_context(mock.patch.object(self.runner.os, "umask"))
            launches = [stack.enter_context(mock.patch(target, side_effect=AssertionError("unexpected process creation")))
                        for target in ("subprocess.Popen", "os.system", "os.fork", "os.posix_spawn", "os.posix_spawnp")]
            yield
            for launch in launches:
                launch.assert_not_called()

    def exercise_selection(self, arguments, expected, fail=None):
        events = []
        prior_reports = set(self.evidence.glob("pyramid-*/result.json"))

        class FakeRung:
            def __init__(self, config, args, base, endpoint, result):
                self.endpoint = endpoint
                events.append(("init", endpoint))

            def execute(self):
                events.append(("execute", self.endpoint))
                if self.endpoint == fail:
                    raise ValueError("controlled rung failure")

            def close(self):
                events.append(("close", self.endpoint))

        with self.cli(arguments), mock.patch.object(self.runner, "Rung", FakeRung):
            if fail:
                with self.assertRaisesRegex(ValueError, "controlled rung failure"):
                    self.runner.main()
            else:
                self.runner.main()
        self.assertEqual(events, [(event, endpoint) for endpoint in expected
                                  for event in ("init", "execute", "close")])
        report_path, = set(self.evidence.glob("pyramid-*/result.json")) - prior_reports
        return json.loads(report_path.read_text())

    def test_each_endpoint_selects_one_fresh_rung_with_no_successor(self):
        for endpoint in ENDPOINTS:
            with self.subTest(endpoint=endpoint):
                report = self.exercise_selection(["--endpoint", endpoint], [endpoint])
                self.assertEqual(report["status"], "passed")
                self.assertEqual([r["endpoint"] for r in report["rungs"]], [endpoint])

    def test_pyramid_completes_each_rung_and_cleanup_before_next(self):
        report = self.exercise_selection(["--pyramid"], ENDPOINTS)
        self.assertEqual(report["status"], "passed")
        self.assertEqual([r["status"] for r in report["rungs"]], ["passed"] * 8)

    def test_failed_rung_is_closed_and_successors_never_started(self):
        report = self.exercise_selection(["--pyramid"], ENDPOINTS[:3], fail="floorplan")
        self.assertEqual(report["status"], "failed")
        self.assertEqual([r["status"] for r in report["rungs"]],
                         ["passed", "passed", "failed", *(["not_run"] * 5)])

    def test_exact_physical_prefixes_exclude_successors(self):
        expected = {
            "elaboration": [], "synthesis": ["synthesis"],
            "floorplan": ["synthesis", "floorplan"],
            "placement": ["synthesis", "floorplan", "placement"],
            "cts": ["synthesis", "floorplan", "placement", "cts"],
            "routing": ["synthesis", "floorplan", "placement", "cts", "routing"],
            "timing": ["synthesis", "floorplan", "placement", "cts", "routing", "timing"],
            "signoff": ["synthesis", "floorplan", "placement", "cts", "routing", "timing", "signoff"],
        }
        for endpoint, prefix in expected.items():
            self.assertEqual(self.runner.select_prefix(endpoint), prefix)
        with self.assertRaises(ValueError):
            self.runner.select_prefix("resume")

    def test_invalid_budgets_fail_before_preflight_allocation_or_launch(self):
        for key in ("preparation_timeout", "stage_timeout", "startup_timeout", "rpc_timeout", "lock_timeout", "endpoint_timeouts"):
            for invalid in (0, -1, True, "30", float("nan"), float("inf")):
                with self.subTest(key=key, value=invalid):
                    self.config[key] = {"signoff": invalid} if key == "endpoint_timeouts" else invalid
                    with self.cli(["--pyramid"]), mock.patch.object(self.runner, "preflight") as preflight:
                        with self.assertRaisesRegex(ValueError, "positive finite timeout"):
                            self.runner.main()
                        preflight.assert_not_called()
                    del self.config[key]
                    self.assertEqual(list(self.evidence.iterdir()), [])

    def test_runner_lock_excludes_another_process_and_releases(self):
        code = (
            "import runpy,sys; m=runpy.run_path(sys.argv[1]); "
            "c=m['locked'](sys.argv[2],.02); c.__enter__(); c.__exit__(None,None,None)"
        )
        command = [sys.executable, "-B", "-c", code, str(HERE / "runner.py"), self.config["serialization_lock"]]
        with self.runner.locked(self.config["serialization_lock"], 1):
            blocked = subprocess.run(command, capture_output=True, text=True, timeout=5)
            self.assertNotEqual(blocked.returncode, 0)
            self.assertIn("lock timeout", blocked.stderr)
        released = subprocess.run(command, capture_output=True, text=True, timeout=5)
        self.assertEqual(released.returncode, 0, released.stderr)


class ConfigureTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = pathlib.Path(self.temp.name)
        self.root = self.base / "ordinary example"
        self.root.mkdir()
        self.store = self.root / ".dev/workbench-main"
        self.generation = self.root / ".dev/installed-generation"
        self.sdk = self.root / ".dev/installed-sdk"
        self.selection = self.store / "installs/selected"
        self.evidence = self.base / "requested/evidence"
        self.output = self.base / "requested/configs/pyramid.json"
        self.runner = load_runner()

    def file(self, path, text, executable=False):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        if executable:
            path.chmod(0o700)
        return path

    def prepare(self):
        self.file(self.generation / "lib/hardcaml_asic/META", "installed asic")
        self.file(self.sdk / "lib/provider/META", "installed sdk")
        self.file(self.generation / "receipt.json", '{"installed": true}')
        provider = self.file(self.generation / "bin/hardcaml-asic-flow", "never run", True)
        tools = {name: str(self.file(self.base / "selected-tools/bin" / name, "never run", True))
                 for name in ("dune", "git", "python")}
        toolchain = self.root / "installed-toolchain"
        for path in (toolchain / "tt", toolchain / "pdk"):
            path.mkdir(parents=True)
        python = self.file(toolchain / ".venv/bin/python", "never run", True)
        target = "asics/current/cli/project.exe"
        project = self.root / "_build/default" / target
        preparation = [["schema_version", "1"], ["build_target", target]]
        asic = [["schema_version", "1"], ["project_executable", str(project)],
                ["provider_executable", str(provider)], ["toolchain", str(toolchain)],
                ["python", [str(python)]], ["support_tools", [str(toolchain / "tt")]],
                ["pdk_root", [str(toolchain / "pdk")]]]
        hashes = {}
        for kind, value in (("preparation", preparation), ("asic", asic)):
            path = self.file(self.selection / "config" / ("hardcaml-workbench-" + kind + ".sexp"),
                             self.runner.sexp(value))
            hashes[kind] = self.runner.digest(path)
        manifest = self.store / "simulation/manifest.json"
        self.file(manifest, json.dumps(dict(
            project_root=str(self.root), asic_generation=str(self.generation), project_executable=str(project),
            environment={"PATH": "/tmp/capture/bin", "OCAMLPATH": "/tmp/provisioning/lib",
                         "GIT_DIR": "/owner/.git", "GIT_WORK_TREE": "/owner",
                         "GIT_CONFIG_COUNT": "1", "HARDCAML_ASIC_SYNTHESIS_TASK_LIMIT": "6",
                         "PT8_SESSION": "/tmp/capture/session", "TMPDIR": "/tmp/capture/tmp",
                         "OPAM_SWITCH_PREFIX": "/installed/switch", "LANG": "C.UTF-8"})))
        apps = {}
        for name in ("daemon", "client"):
            path = self.file(self.selection / "apps" / (name + ".exe"), "installed app " + name, True)
            apps[name] = dict(path=str(path), sha256=self.runner.digest(path))
        self.file(self.store / "install.json", json.dumps(dict(
            schema_version=1, project_root=str(self.root), selection=str(self.selection),
            simulation_manifest=str(manifest), asic_generation=str(self.generation), sdk_prefix=str(self.sdk),
            config_sha256=hashes, apps=apps, tools=tools)))
        # Owner root companions deliberately differ: derive from the prepared
        # immutable selection without adopting or rewriting active owner config.
        self.owner = self.file(self.root / "hardcaml-workbench-asic.sexp", "owner config: untouched")

    def invoke(self, succeeds=True):
        output = io.StringIO()
        argv = [str(HERE / "configure.py"), "--example-root", str(self.root),
                "--evidence-root", str(self.evidence), "--output", str(self.output),
                "--flow", "standard", "--profile", "balanced"]
        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.object(sys, "argv", argv))
            stack.enter_context(contextlib.redirect_stdout(output))
            stack.enter_context(contextlib.redirect_stderr(output))
            launches = [stack.enter_context(mock.patch(target, side_effect=AssertionError("configuration must not launch processes")))
                        for target in ("subprocess.Popen", "os.system", "os.fork", "os.posix_spawn", "os.posix_spawnp")]
            if succeeds:
                runpy.run_path(str(HERE / "configure.py"), run_name="__main__")
            else:
                with self.assertRaises(SystemExit) as error:
                    runpy.run_path(str(HERE / "configure.py"), run_name="__main__")
                self.assertNotEqual(error.exception.code, 0)
            for launch in launches:
                launch.assert_not_called()
        return output.getvalue()

    def test_prepared_main_yields_valid_exact_installed_config_without_processes(self):
        self.prepare()
        self.invoke()
        raw = self.output.read_text()
        config = json.loads(raw)
        self.runner.validate_config(config)
        self.assertEqual(config["source_closure"], [dict(source=str(self.root), destination=self.root.name)])
        self.assertEqual(config["build_target"], "asics/current/cli/project.exe")
        self.assertEqual(config["provider"], str(self.generation / "bin/hardcaml-asic-flow"))
        self.assertEqual(config["dune"], str(self.base / "selected-tools/bin/dune"))
        self.assertEqual(config["toolchain"], str(self.root / "installed-toolchain"))
        self.assertEqual(config["python"], str(self.root / "installed-toolchain/.venv/bin/python"))
        self.assertEqual(config["support_tools"], str(self.root / "installed-toolchain/tt"))
        self.assertEqual(config["pdk_root"], str(self.root / "installed-toolchain/pdk"))
        self.assertIn(str(self.sdk / "lib/provider/META"), config["sdk_identity_files"])
        self.assertEqual(config["build_lock"], str(self.root.parent / ".workbench-example-build.lock"))
        self.assertEqual(config["outer_build_lock"], str(self.root.parent / ".workbench-build.lock"))
        self.assertEqual(config["serialization_lock"], str(self.root.parent / ".workbench-pyramid-execution.lock"))
        self.assertNotEqual(config["build_lock"], "/tmp/opencode/workbench-pt8-build.lock")
        self.assertEqual(config["environment"]["OCAMLPATH"], str(self.generation / "lib") + ":" + str(self.sdk / "lib"))
        self.assertEqual(config["environment"]["OPAM_SWITCH_PREFIX"], "/installed/switch")
        for name in ("GIT_DIR", "GIT_WORK_TREE", "GIT_CONFIG_COUNT", "HARDCAML_ASIC_SYNTHESIS_TASK_LIMIT", "TMPDIR", "PT8_SESSION"):
            self.assertNotIn(name, config["environment"])
        for captured in ("/tmp/capture", "/tmp/provisioning"):
            self.assertNotIn(captured, raw)
        sidecar = json.loads(self.output.with_name(self.output.name + ".inputs.json").read_text())
        self.assertEqual(sidecar["config_sha256"], self.runner.digest(self.output))
        self.assertEqual(set(sidecar["inputs_sha256"]), set(config["sdk_identity_files"]))
        for path, digest in sidecar["inputs_sha256"].items():
            self.assertEqual(self.runner.digest(path), digest)
        self.assertEqual(self.owner.read_text(), "owner config: untouched")
        self.assertTrue(self.evidence.is_dir())
        self.assertFalse(pathlib.Path(config["build_lock"]).exists())

    def test_missing_main_setup_fails_before_processes_or_requested_directory_creation(self):
        diagnostic = self.invoke(succeeds=False)
        self.assertIn("prepared main setup", diagnostic)
        self.assertFalse(self.output.parent.exists())
        self.assertFalse(self.evidence.exists())

    def test_existing_output_is_never_overwritten(self):
        self.prepare()
        self.file(self.output, "user owned output")
        self.assertIn("refusing overwrite", self.invoke(succeeds=False))
        self.assertEqual(self.output.read_text(), "user owned output")
        self.assertFalse(self.evidence.exists())

    def test_existing_identity_sidecar_is_never_overwritten(self):
        self.prepare()
        sidecar = self.file(self.output.with_name(self.output.name + ".inputs.json"), "user owned identities")
        self.assertIn("refusing overwrite", self.invoke(succeeds=False))
        self.assertEqual(sidecar.read_text(), "user owned identities")
        self.assertFalse(self.output.exists())

    def test_changed_companions_fail_without_writes(self):
        self.prepare()
        companion = self.selection / "config/hardcaml-workbench-asic.sexp"
        companion.write_text("changed owner selection")
        self.assertIn("identity mismatch", self.invoke(succeeds=False))
        self.assertFalse(self.output.parent.exists())
        self.assertFalse(self.evidence.exists())

    def test_foreign_simulation_root_is_rejected(self):
        self.prepare()
        path = self.store / "simulation/manifest.json"
        manifest = json.loads(path.read_text())
        manifest["project_root"] = str(self.base)
        path.write_text(json.dumps(manifest))
        self.assertIn("foreign simulation source root", self.invoke(succeeds=False))
        self.assertFalse(self.output.parent.exists())

    def test_excluded_persistent_storage_is_not_recopied_and_existing_evidence_is_untouched(self):
        self.prepare()
        self.evidence = self.root / ".dev/workbench-pyramid/evidence"
        self.output = self.root / ".dev/workbench-pyramid/real-tests.json"
        owner_evidence = self.file(self.evidence / "existing-result.json", "owner evidence")
        prior_config = self.file(self.output.with_name("real-elaboration.json"), "owner configuration")
        self.invoke()
        config = json.loads(self.output.read_text())
        self.assertEqual(config["evidence_root"], str(self.evidence))
        self.assertEqual(config["serialization_lock"], str(self.root.parent / ".workbench-pyramid-execution.lock"))
        self.assertEqual(owner_evidence.read_text(), "owner evidence")
        self.assertEqual(prior_config.read_text(), "owner configuration")
        copied = self.base / "private-copy"
        self.runner.copy_closure(config, copied)
        self.assertFalse((copied / self.root.name / ".dev").exists())

    def test_authored_evidence_storage_is_rejected_before_writes(self):
        self.prepare()
        self.evidence = self.root / "authored/evidence"
        self.assertIn("outside excluded storage", self.invoke(succeeds=False))
        self.assertFalse(self.evidence.exists())
        self.assertFalse(self.output.exists())

    def test_generated_persistent_config_passes_actual_runner_preflight_without_processes(self):
        self.prepare()
        self.evidence = self.root / ".dev/workbench-pyramid/evidence"
        self.output = self.root / ".dev/workbench-pyramid/real-tests-v2.json"
        self.invoke()
        config = json.loads(self.output.read_text())
        args = mock.Mock(daemon=self.selection / "apps/daemon.exe", client=self.selection / "apps/client.exe")
        with contextlib.ExitStack() as stack:
            lock = stack.enter_context(mock.patch.object(self.runner, "locked", return_value=contextlib.nullcontext()))
            launches = [stack.enter_context(mock.patch(target, side_effect=AssertionError("preflight must not launch processes")))
                        for target in ("subprocess.Popen", "os.system", "os.fork", "os.posix_spawn", "os.posix_spawnp")]
            self.runner.preflight(config, args)
            lock.assert_called_once_with(config["build_lock"], 120)
            # Reproduce the reviewed failure with the old layout: actual
            # preflight must reject it before attempting any lock operation.
            lock.reset_mock()
            with self.assertRaisesRegex(ValueError, "locks must not mutate source closure"):
                self.runner.preflight(dict(config, serialization_lock=str(self.evidence / "pyramid.lock")), args)
            lock.assert_not_called()
            for launch in launches:
                launch.assert_not_called()
        for key in ("serialization_lock", "build_lock", "outer_build_lock"):
            self.assertFalse(pathlib.Path(config[key]).is_relative_to(self.root))
            self.assertFalse(pathlib.Path(config[key]).exists())

    def test_authored_config_output_is_rejected_before_writes(self):
        self.prepare()
        self.output = self.root / "authored/real-tests.json"
        self.assertIn("config output overlaps", self.invoke(succeeds=False))
        self.assertFalse(self.output.parent.exists())
        self.assertFalse(self.evidence.exists())

    def test_resolved_symlink_cannot_hide_authored_storage(self):
        self.prepare()
        authored = self.root / "authored"
        authored.mkdir()
        (self.root / ".dev/evidence-link").symlink_to(authored, target_is_directory=True)
        self.evidence = self.root / ".dev/evidence-link/evidence"
        self.assertIn("outside excluded storage", self.invoke(succeeds=False))
        self.assertFalse((authored / "evidence").exists())

    def test_manifest_drift_during_derivation_is_rejected(self):
        self.prepare()
        helper = runpy.run_path(str(HERE / "configure.py"))
        derive = helper["derive"]
        original_validate = self.runner.validate_config
        manifest = self.store / "simulation/manifest.json"

        def validate_then_drift(config):
            original_validate(config)
            manifest.write_text(manifest.read_text() + "\n")

        with mock.patch.dict(derive.__globals__, runner_module=lambda: self.runner), \
                mock.patch.object(self.runner, "validate_config", side_effect=validate_then_drift):
            with self.assertRaisesRegex(ValueError, "setup changed while deriving"):
                derive(self.root, self.evidence, "standard", "balanced")
        self.assertFalse(self.evidence.exists())
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
