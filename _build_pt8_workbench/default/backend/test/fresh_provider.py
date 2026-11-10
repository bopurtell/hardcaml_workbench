#!/usr/bin/env python3
"""Exact prepared-input fixture. No tools/EDA; rejects project flow commands."""
import hashlib
import json
import os
import signal
import sys
import time

args = sys.argv[1:]
with open("physical-calls", "a") as out:
    out.write(json.dumps(args) + "\n")


def env(kind, version=1, **fields):
    return dict(contract="hardcaml-asic." + kind, schema_version=version, **fields)


def emit(value):
    print(json.dumps(value), flush=True)


def option(flag):
    return args[args.index(flag) + 1]


if args == ["--version", "--json"]:
    def stop_probe(_sig, _frame):
        with open("probe-stopped", "w") as out:
            out.write(str(os.getpid()))
        sys.exit(130)

    signal.signal(signal.SIGTERM, stop_probe)
    with open("probe-entered", "w") as out:
        out.write(str(os.getpid()))
    while os.path.exists("hold-probe") and not os.path.exists("probe-release"):
        time.sleep(0.01)
    if os.path.exists("fail-probe"):
        print("fixture capability probe failure", file=sys.stderr)
        sys.exit(9)
    emit(dict(cli_contract=dict(version=4, capabilities=dict(namedflow1=True, timing_stage1=True))))
elif args[:1] == ["stages"]:
    bundle = args[1]
    with open(option("--methodology-plan")) as src:
        plan = json.load(src)
    assert plan["plan_identity"] == option("--expected-plan-identity")
    assert "--endpoint" not in args and "--checkpoint" not in args
    with open(os.path.join(bundle, "manifest.json")) as src:
        manifest = json.load(src)
    assert manifest == json.loads(plan["bundle_manifest"])
    assert manifest["identity"] == plan["bundle_identity"]
    for member in manifest["files"]:
        with open(os.path.join(bundle, member["path"]), "rb") as src:
            assert hashlib.sha256(src.read()).hexdigest() == member["sha256"]
    with open(os.path.join(bundle, "src/config.json")) as src:
        assert src.read() == plan["configuration_bytes"]
    recipe = plan["methodology"]["recipe"]
    stages = recipe["stages"]
    prefix = ["synthesis", "floorplan", "placement", "cts", "routing", "timing", "signoff"]
    assert recipe["initial_boundary"] is None and stages == prefix[:len(stages)]
    workspace = option("--workspace")
    os.makedirs(workspace)
    attempt = os.path.join(workspace, "observation")
    os.mkdir(attempt)
    stream = os.path.basename(workspace)
    execution_file = os.path.join(attempt, "execution.json")
    method = env("historical-methodology", state="recorded",
                 plan_identity=plan["plan_identity"], bundle_identity=plan["bundle_identity"],
                 reference=dict(attempt_id=stream))

    def save(status=None):
        execution = dict(attempt_id=stream, status=status or "running",
                         exit_code=130 if status == "interrupted" else 0,
                         plan=recipe, artifacts=[], occurrences=[
                             dict(action_key="implementation." + stage,
                                  occurrence_id=stream + "/implementation." + stage,
                                  status=status or "running",
                                  exit_code=(None if status is None else (130 if status == "interrupted" else 0)),
                                  best_effort=False, verdict=None)
                             for stage in stages])
        with open(execution_file, "w") as out:
            json.dump(execution, out)
        inspection = env("stage-observation", 2, stream_id=stream, cursor=0,
                         writer_active=status is None, observation_status="final" if status else "active",
                         state=dict(execution, outcome=dict(status=status, exit_code=execution["exit_code"]) if status else None),
                         methodology=method, execution_file=execution_file if status else None)
        with open(os.path.join(attempt, "inspection.pending"), "w") as out:
            json.dump(inspection, out)
        os.replace(os.path.join(attempt, "inspection.pending"), os.path.join(attempt, "inspection.json"))

    def stop(_sig, _frame):
        save("interrupted")
        with open("physical-stopped", "w") as out:
            out.write(stream)
        emit(env("stage-observation", event="observation_terminal", execution_file=execution_file))
        sys.exit(130)

    signal.signal(signal.SIGTERM, stop)
    save()
    emit(env("stage-observation", event="observation_allocated", attempt=attempt, stream_id=stream))
    time.sleep(30 if os.path.exists("hold-physical") else 0.2)
    save("completed")
    emit(env("stage-observation", event="observation_terminal", execution_file=execution_file))
elif args[:2] == ["observation", "inspect"]:
    with open(os.path.join(args[2], "inspection.json")) as src:
        emit(json.load(src))
elif args[:2] == ["observation", "read-updates"]:
    emit(env("stage-observation", 2, stream_id=option("--stream-id"), after=int(option("--after")), cursor=0, events=[]))
elif args[:1] == ["report"]:
    with open(args[1]) as src:
        execution = json.load(src)
    with open(os.path.join(os.path.dirname(args[1]), "inspection.json")) as src:
        method = json.load(src)["methodology"]
    emit(env("report", execution=execution, checkpoints=[], methodology=method,
             completion=dict(physical="partial"), acceptance="not_evaluated"))
else:
    raise RuntimeError("Unexpected call (pinned project execution forbidden): " + repr(args))
