#!/usr/bin/env python3
"""Derive a real-pyramid config from an already prepared example main install.

Reads installed metadata only: no builds, provider probes, or session changes.
Creates only the explicitly requested evidence directory/output parents and two
exclusive files: OUTPUT and OUTPUT.inputs.json. Existing outputs are refused.

Output schema: runner schema_version=1; source_closure selects the current
example source, installed paths/SDK identities come from prepared main metadata,
and environment contains selected compiler settings without repository context.
evidence_root and output may live below a runner-excluded subtree (for example
.dev/workbench-pyramid), never in an ordinary authored source directory.
build_lock is the shared sibling .workbench-example-build.lock; outer_build_lock
defaults to the distinct persistent sibling .workbench-build.lock. The latter
may be explicitly selected with --outer-build-lock to match an outer Dune flock.
serialization_lock is the shared sibling .workbench-pyramid-execution.lock,
outside the source closure and common to configs/example roots in this workspace.
"""

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path


def runner_module():
    spec = importlib.util.spec_from_file_location("pyramid_config_contract", Path(__file__).with_name("runner.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def require(condition, message):
    if not condition:
        raise ValueError(message)


def storage_path(runner, root, path, label):
    path = Path(path).resolve()
    nested_excluded = path.is_relative_to(root) and any(
        runner.excluded(part) for part in path.relative_to(root).parts)
    require((not path.is_relative_to(root) or nested_excluded) and not root.is_relative_to(path),
            label + " overlaps example source outside excluded storage")
    return path


def derive(example_root, evidence_root, flow, profile, outer_build_lock=None):
    """Validate a prepared main installation and return config + input hashes."""
    runner = runner_module()
    root = Path(example_root).resolve(strict=True)
    require(root.is_dir(), "example root must be a directory")
    evidence = storage_path(runner, root, evidence_root, "evidence root")
    inputs = {}

    def read(path):
        path = Path(path)
        require(path.is_file(), "missing prepared main setup input: " + str(path))
        raw = path.read_bytes()
        inputs[str(path)] = hashlib.sha256(raw).hexdigest()
        return raw

    def absolute(value):
        require(isinstance(value, str) and Path(value).is_absolute(), "installed path must be absolute")
        return Path(value)

    install_path = root / ".dev/workbench-main/install.json"
    install = json.loads(read(install_path))
    require(install.get("schema_version") == 1, "unsupported main install schema")
    require(absolute(install["project_root"]).resolve(strict=True) == root, "foreign main project root")
    selection = absolute(install["selection"])
    manifest_path = absolute(install["simulation_manifest"])
    manifest = json.loads(read(manifest_path))
    require(absolute(manifest["project_root"]).resolve(strict=True) == root, "foreign simulation source root")
    generation = absolute(install["asic_generation"]).resolve(strict=True)
    sdk = absolute(install["sdk_prefix"]).resolve(strict=True)
    require(absolute(manifest["asic_generation"]).resolve(strict=True) == generation,
            "main and simulation ASIC generations differ")
    require((generation / "lib").is_dir() and (sdk / "lib").is_dir(), "missing installed SDK libraries")

    def companion(kind):
        path = selection / "config" / ("hardcaml-workbench-" + kind + ".sexp")
        raw = read(path)
        require(inputs[str(path)] == install["config_sha256"][kind], "prepared companion identity mismatch: " + kind)
        value = runner.parse(raw.decode())
        require(isinstance(value, list) and all(isinstance(p, list) and len(p) == 2 for p in value),
                "invalid prepared companion: " + kind)
        result = dict(value)
        require(len(result) == len(value), "duplicate companion field: " + kind)
        require(result.get("schema_version") == "1", "unsupported companion schema: " + kind)
        return result

    preparation, asic = companion("preparation"), companion("asic")
    target = str(runner.relative(preparation["build_target"]))
    project_executable = root / "_build/default" / target
    require(absolute(asic["project_executable"]) == project_executable,
            "preparation target differs from installed ASIC companion")
    require(absolute(manifest["project_executable"]) == project_executable,
            "simulation project target differs from prepared main target")
    provider = absolute(asic["provider_executable"])
    require(provider == generation / "bin/hardcaml-asic-flow", "companion selects a foreign provider")
    tools = {key: absolute(install["tools"][key]) for key in ("dune", "git", "python")}
    for name, app in install["apps"].items():
        path = absolute(app["path"])
        read(path)
        require(inputs[str(path)] == app["sha256"], "installed app identity mismatch: " + name)
    for path in (provider, *tools.values()):
        require(path.is_file() and os.access(path, os.X_OK), "missing installed executable: " + str(path))
        read(path)

    companions = {}
    for key in ("toolchain", "python", "support_tools", "pdk_root"):
        value = asic[key]
        if key != "toolchain":
            require(isinstance(value, list) and len(value) == 1, "explicit companion option required: " + key)
            value = value[0]
        path = absolute(value)
        require(path.is_file() and os.access(path, os.X_OK) if key == "python" else path.is_dir(),
                "missing installed toolchain field: " + key)
        companions[key] = str(path)
    read(companions["python"])

    # Preserve compiler/switch settings, never captured session or repository
    # context. PATH and OCAMLPATH are reconstructed from the selected install.
    inherited = manifest["environment"]
    require(isinstance(inherited, dict) and all(isinstance(v, str) for v in inherited.values()),
            "invalid simulation environment")
    keep = {"LANG", "LC_ALL", "LC_CTYPE", "OPAM_SWITCH_PREFIX", "CAML_LD_LIBRARY_PATH",
            "OCAMLTOP_INCLUDE_PATH", "OCAML_TOPLEVEL_PATH", "MANPATH"}
    env = {key: value for key, value in inherited.items() if key in keep}
    env.update(PATH=os.pathsep.join(dict.fromkeys(map(str, (
        tools["dune"].parent, tools["git"].parent, generation / "bin", Path("/usr/bin"), Path("/bin"))))),
        OCAMLPATH=os.pathsep.join(map(str, (generation / "lib", sdk / "lib"))),
        HARDCAML_ASIC_GENERATION=str(generation), PYTHONDONTWRITEBYTECODE="1",
        GIT_OPTIONAL_LOCKS="0", GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null")
    identities = [generation / "receipt.json"]
    sdk_metadata = sorted([*(sdk / "lib").glob("*/META"), *(sdk / "lib").glob("*/dune-package")])
    require(sdk_metadata, "missing installed SDK package identities")
    identities.extend(sdk_metadata)
    for path in identities:
        read(path)
    config = dict(schema_version=1, evidence_root=str(evidence),
                  serialization_lock=str(root.parent / ".workbench-pyramid-execution.lock"),
                  build_lock=str(root.parent / ".workbench-example-build.lock"),
                  outer_build_lock=str(storage_path(runner, root,
                                       outer_build_lock if outer_build_lock is not None
                                       else root.parent / ".workbench-build.lock", "outer build lock")),
                  source_closure=[dict(source=str(root), destination=root.name)], project=root.name,
                  build_target=target, provider=str(provider), dune=str(tools["dune"]),
                  environment=env, sdk_identity_files=list(inputs), flow=flow, profile=profile,
                  assignments=[], **companions)
    runner.validate_config(config)
    require(all(runner.digest(path) == expected for path, expected in inputs.items()),
            "prepared main setup changed while deriving configuration; retry")
    return config, dict(schema_version=1, example_root=str(root), inputs_sha256=inputs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("example-root", "evidence-root", "output"):
        parser.add_argument("--" + name, required=True, type=Path)
    parser.add_argument("--flow", required=True)
    parser.add_argument("--profile", required=True)
    parser.add_argument("--outer-build-lock", type=Path,
                        help="outer Workbench flock; default: example parent's .workbench-build.lock")
    args = parser.parse_args()
    output = args.output.absolute()
    provenance = output.with_name(output.name + ".inputs.json")
    try:
        require(not output.exists() and not output.is_symlink() and not provenance.exists() and not provenance.is_symlink(),
                "output or input-identity sidecar already exists; refusing overwrite")
        config, inputs = derive(args.example_root, args.evidence_root, args.flow, args.profile, args.outer_build_lock)
        runner = runner_module()
        root = Path(config["source_closure"][0]["source"])
        storage_path(runner, root, output, "config output")
        storage_path(runner, root, provenance, "identity sidecar")
        protected = [Path(config["source_closure"][0]["source"]),
                     *[Path(p) for p in config["sdk_identity_files"]]]
        require(output not in protected and provenance not in protected, "output collides with installed input")
        raw = json.dumps(config, indent=2, sort_keys=True, allow_nan=False) + "\n"
        inputs["config_sha256"] = hashlib.sha256(raw.encode()).hexdigest()
        # Finish all validation before creating even the requested directories.
        Path(config["evidence_root"]).mkdir(parents=True, exist_ok=True)
        output.parent.mkdir(parents=True, exist_ok=True)
        with output.open("x") as stream:
            stream.write(raw)
        try:
            with provenance.open("x") as stream:
                stream.write(json.dumps(inputs, indent=2, sort_keys=True) + "\n")
        except BaseException:
            output.unlink()
            raise
    except (ValueError, OSError, KeyError, TypeError) as error:
        parser.error(str(error))
    print("Config: " + str(output))
    print("Input identities: " + str(provenance))


if __name__ == "__main__":
    main()
