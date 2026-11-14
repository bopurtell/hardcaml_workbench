"""Read-only real setup resolution. No subprocesses, installs, or directory writes."""

import importlib.util
import json
import os
from pathlib import Path


def helper(name):
    spec = importlib.util.spec_from_file_location("pyramid_" + name, Path(__file__).with_name(name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def source_root():
    # Dune supplies the absolute SOURCE root, independent of sandbox/build-dir.
    # Never infer it by stripping _build (external build dirs need not use it).
    dune_root = os.environ.get("DUNE_SOURCEROOT")
    candidates = ([Path(dune_root), Path(dune_root) / "silver"] if dune_root
                  else [Path(__file__).resolve().parents[3]])
    matches = [p.resolve() for p in candidates
               if (p / ".git").exists() and (p / "test/integration/pyramid/runner.py").is_file()
               and (p / "dune-project").is_file()]
    if len(matches) != 1:
        raise ValueError("cannot locate unique Workbench source checkout; run from source or through Dune (DUNE_SOURCEROOT)")
    return matches[0]


def resolve(override):
    runner = helper("runner")
    if override:
        path = Path(override).resolve(strict=True)
        raw = path.read_bytes()
        config = runner.validate_config(json.loads(raw))
        return config, raw, dict(mode="explicit", config_path=str(path),
                                 inputs_sha256={str(path): runner.digest(path)})
    root = source_root()
    example = root.parent / "hardcaml_asic_example"
    configure = helper("configure")
    try:
        config, inputs = configure.derive(
            example, example / ".dev/workbench-pyramid/evidence", "standard", "balanced", current_common=True)
    except (ValueError, OSError, KeyError, TypeError, IndexError) as error:
        raise ValueError(str(error) + "; " + configure.setup_help(example)) from error
    inputs.update(mode="automatic", workbench_source=str(root), flow="standard", profile="balanced",
                  dune_source_root=os.environ.get("DUNE_SOURCEROOT"), resolver_path=str(Path(__file__).resolve()))
    raw = (json.dumps(config, indent=2, sort_keys=True) + "\n").encode()
    return config, raw, inputs
