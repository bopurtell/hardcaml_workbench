#!/usr/bin/env python3
"""Configure one installed consumer's private fresh-prefix + PTY reopen journey.

No installs, builds, providers, daemons or EDA are started. Existing outputs are
refused. The runner copies source, writes a generic project manifest only in that
copy, builds the named target, and recomputes its plan there. The captured exporter
is pinned as an input identity; execution uses the freshly built source target.

Run the resulting config with runner.py --endpoint timing --config OUTPUT
--daemon /absolute/prebuilt/daemon --client /absolute/prebuilt/client.
All real work remains opt-in. This helper never reads the owner's main companions.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil


def runner_module():
    spec = importlib.util.spec_from_file_location("private_prefix_runner", Path(__file__).with_name("runner.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def derive(args):
    runner = runner_module()
    source = args.source_root.resolve(strict=True)
    exporter = args.exporter.resolve(strict=True)
    provider = args.provider.resolve(strict=True)
    dune = args.dune.resolve(strict=True)
    toolchain = args.toolchain.resolve(strict=True)
    python = (args.python or toolchain / ".venv/bin/python").absolute()
    support = (args.support_tools or toolchain / "tt").resolve(strict=True)
    pdk = (args.pdk_root or toolchain / "pdk").resolve(strict=True)
    target = runner.relative(args.build_target)
    runner.require(source.is_dir() and (source / "dune-project").is_file(), "complete Dune source root required")
    for path in (exporter, provider, dune, python):
        runner.require(path.is_file() and os.access(path, os.X_OK), "installed executable missing: " + str(path))
    for path in (toolchain, support, pdk):
        runner.require(path.is_dir(), "installed tool directory missing: " + str(path))
    libraries = [Path(p).resolve(strict=True) for p in args.ocamlpath.split(os.pathsep)]
    runner.require(all(path.is_dir() for path in libraries), "OCAMLPATH must contain installed library directories")
    evidence = args.evidence_root.resolve()
    runner.require(not evidence.is_relative_to(source) and not source.is_relative_to(evidence),
                   "private source and evidence must be separate directories")
    keep = {"PATH", "LANG", "LC_ALL", "LC_CTYPE", "OPAM_SWITCH_PREFIX", "CAML_LD_LIBRARY_PATH",
            "OCAMLTOP_INCLUDE_PATH", "OCAML_TOPLEVEL_PATH", "MANPATH"}
    env = {key: value for key, value in os.environ.items() if key in keep}
    env.update(OCAMLPATH=os.pathsep.join(map(str, libraries)), PYTHONDONTWRITEBYTECODE="1",
               GIT_OPTIONAL_LOCKS="0", OMP_NUM_THREADS="1", OPENBLAS_NUM_THREADS="1", MKL_NUM_THREADS="1")
    identities = [exporter, provider, dune, python, *args.identity_file]
    identities = list(dict.fromkeys(str(Path(path).absolute()) for path in identities))
    config = dict(schema_version=1, evidence_root=str(evidence),
        serialization_lock=str(args.serialization_lock.absolute()), build_lock=str(args.build_lock.absolute()),
        source_closure=[dict(source=str(source), destination="consumer")], project="consumer",
        project_name=args.project_name, build_target=str(target), provider=str(provider), dune=str(dune),
        toolchain=str(toolchain), python=str(python), support_tools=str(support), pdk_root=str(pdk),
        environment=env, sdk_identity_files=identities, flow=args.flow, profile=args.profile,
        assignments=args.assignment, verify_reopen=True, stage_timeout=args.stage_timeout)
    runner.validate_config(config)
    for key in ("serialization_lock", "build_lock"):
        path = Path(config[key]).resolve()
        runner.require(path.parent.is_dir() and not path.is_relative_to(source), "lock requires external existing parent: " + key)
    inputs = dict(schema_version=1, captured_exporter=str(exporter),
                  inputs_sha256={path: runner.digest(path) for path in identities},
                  source_root=str(source), build_target=str(target), installs=False,
                  runner=str(Path(__file__).with_name("runner.py").resolve()))
    return config, inputs


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    for name in ("source-root", "exporter", "provider", "toolchain", "evidence-root", "output",
                 "serialization-lock", "build-lock"):
        parser.add_argument("--" + name, type=Path, required=True)
    for name in ("python", "support-tools", "pdk-root"):
        parser.add_argument("--" + name, type=Path)
    parser.add_argument("--dune", type=Path, default=shutil.which("dune"))
    parser.add_argument("--ocamlpath", required=True, help="explicit installed compiler library search path")
    for name in ("build-target", "flow", "profile", "project-name"):
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--assignment", action="append", default=[])
    parser.add_argument("--identity-file", action="append", type=Path, default=[], help="additional installed SDK/provider receipt")
    parser.add_argument("--stage-timeout", type=int, default=600)
    args = parser.parse_args()
    if args.dune is None:
        parser.error("--dune required when Dune is not in PATH")
    output = args.output.absolute()
    sidecar = output.with_name(output.name + ".inputs.json")
    try:
        runner = runner_module()
        runner.require(not output.exists() and not output.is_symlink() and not sidecar.exists() and not sidecar.is_symlink(),
                       "output or identity sidecar already exists; refusing overwrite")
        # Configuration storage must not write into the selected authored source.
        source = args.source_root.resolve(strict=True)
        runner.require(not output.resolve().is_relative_to(source), "config output must be outside source")
        config, inputs = derive(args)
        output.parent.mkdir(parents=True, exist_ok=True)
        Path(config["evidence_root"]).mkdir(parents=True, exist_ok=True)
        for path, value in ((output, config), (sidecar, inputs)):
            with path.open("x") as stream:
                json.dump(value, stream, indent=2)
                stream.write("\n")
        print("Configured (no tools launched): " + str(output))
    except (ValueError, OSError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
