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
import stat


def runner_module():
    spec = importlib.util.spec_from_file_location("pyramid_config_contract", Path(__file__).with_name("runner.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def require(condition, message):
    if not condition:
        raise ValueError(message)


def setup_help(root):
    return ("Prepare/refresh the example main installation explicitly (never automatic); "
            "see: python3 -B " + str(Path(root) / "scripts/workbench_main.py") + " prepare --help")


def read_current(path, max_bytes=64 * 1024):
    """WB049 lookup inputs: bounded regular files, no symlink path components."""
    for part in reversed((path, *path.parents)):
        try:
            info = part.lstat()
        except FileNotFoundError:
            return None
        require(not stat.S_ISLNK(info.st_mode), "symlink configuration path: " + str(part))
        require(part == path or stat.S_ISDIR(info.st_mode), "not a configuration directory: " + str(part))
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
    before = os.fstat(fd)
    if not stat.S_ISREG(before.st_mode) or before.st_size > max_bytes:
        os.close(fd)
        raise ValueError("expected bounded regular configuration: " + str(path))
    with os.fdopen(fd, "rb") as stream:
        raw = stream.read(max_bytes + 1)
        after = os.fstat(stream.fileno())
        current = path.lstat()
        def identity(info):
            return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)
        require(len(raw) <= max_bytes and len(raw) == before.st_size and
                identity(before) == identity(after) == identity(current) and path.resolve() == path,
                "configuration changed while reading: " + str(path))
        return raw


def current_companion(root, kind):
    """Common wins only when both copies have identical bytes, before parsing."""
    name = "hardcaml-workbench-" + kind + ".sexp"
    max_bytes = (16 if kind == "simulation" else 64) * 1024
    found = {path: raw for path in (root / ".workbench" / name, root / name)
             if (raw := read_current(path, max_bytes=max_bytes)) is not None}
    require(found, "missing prepared main setup input: current config " + name)
    require(len(set(found.values())) == 1,
            "Conflicting configuration files (different bytes): " + " and ".join(map(str, found)))
    return next(iter(found)), found


def storage_path(runner, root, path, label):
    path = Path(path).resolve()
    nested_excluded = path.is_relative_to(root) and any(
        runner.excluded(part) for part in path.relative_to(root).parts)
    require((not path.is_relative_to(root) or nested_excluded) and not root.is_relative_to(path),
            label + " overlaps example source outside excluded storage")
    return path


def derive(example_root, evidence_root, flow, profile, outer_build_lock=None, current_common=False):
    """Validate a prepared main installation and return config + input hashes."""
    runner = runner_module()
    root = Path(example_root).resolve(strict=True)
    require(root.is_dir(), "example root must be a directory")
    evidence = storage_path(runner, root, evidence_root, "evidence root")
    inputs = {}
    current_configs = {}

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
    if current_common:
        # Main install is the only authority for generation selection. Never scan
        # historical installs or reuse an earlier pyramid JSON. WB049's selected
        # current configs must describe that exact prepared selection.
        for kind in ("preparation", "asic", "simulation"):
            installed = companion(kind)
            path, found = current_companion(root, kind)
            current_configs[kind] = str(path)
            inputs.update({str(p): hashlib.sha256(raw).hexdigest() for p, raw in found.items()})
            value = runner.parse(found[path].decode())
            require(isinstance(value, list) and all(isinstance(p, list) and len(p) == 2 for p in value),
                    "invalid common companion: " + kind)
            require(len(dict(value)) == len(value) and dict(value) == installed,
                    "current common config differs from prepared main install: " + kind + "; prepare main install again")
        simulation = companion("simulation")
        require(simulation["provider_args"][-2:] == ["--manifest", str(manifest_path)],
                "common simulation selects a different manifest")
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
    return config, dict(schema_version=1, example_root=str(root), inputs_sha256=inputs,
                        current_configs=current_configs,
                        prebuilt_apps={name: app["path"] for name, app in install["apps"].items()})


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
        parser.error(str(error) + "; " + setup_help(args.example_root))
    print("Config: " + str(output))
    print("Input identities: " + str(provenance))


if __name__ == "__main__":
    main()
