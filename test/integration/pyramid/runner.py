#!/usr/bin/env python3
"""Opt-in real fresh-prefix acceptance. No imports from synthetic fixtures.

Configuration is JSON, schema_version=1. Required keys:
 evidence_root, serialization_lock, build_lock (absolute paths; parents exist),
 source_closure ([{"source": absolute directory, "destination": relative path}]),
 project (relative to copied closure), build_target (relative Dune target),
 provider, dune, toolchain, python, support_tools, pdk_root (installed paths),
 environment (explicit complete environment, including PATH),
 flow, profile, assignments (string list).
Optional: sdk_identity_files (absolute installed SDK/provider receipt paths),
 endpoint_timeouts (seconds by endpoint), preparation_timeout (600),
 stage_timeout (7200), startup_timeout (120), rpc_timeout (30), lock_timeout (120),
 outer_build_lock (absolute Workbench build lock; must differ from build_lock).
Signoff defaults to 7200 seconds; a positive explicit override is permitted.
--daemon/--client are the prebuilt production applications supplied by Dune.
--self-test performs controlled runner checks only, without external tools.
With no config override, resolve the sibling example's current common configs
and prepared main install afresh. --preflight-only validates setup read-only.
"""

import argparse
from contextlib import contextmanager
from datetime import datetime
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import pty
import re
import select
import shutil
import signal
import struct
import subprocess
import sys
import termios
import time
import traceback
import uuid
import unicodedata


ENDPOINTS = ("elaboration", "synthesis", "floorplan", "placement", "cts", "routing", "timing", "signoff")
PHYSICAL = ENDPOINTS[1:]
DEFAULT_TIMEOUTS = dict(zip(ENDPOINTS, (900, 1800, 2700, 3600, 3600, 5400, 5400, 7200)))
EXCLUDED = {".git", ".dev", ".workbench", "results", "_flow_results", "_flow_tools",
            "hardcaml-workbench-simulation.sexp", "hardcaml-workbench-asic.sexp",
            "hardcaml-workbench-preparation.sexp"}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def select_prefix(endpoint):
    """The exact fresh recipe, never a resume or suffix."""
    require(endpoint in ENDPOINTS, "unknown endpoint: " + str(endpoint))
    return list(PHYSICAL[:ENDPOINTS.index(endpoint)])


def relative(value):
    require(isinstance(value, str) and value, "nonempty relative path required")
    path = Path(value)
    require(not path.is_absolute() and ".." not in path.parts, "unsafe relative path: " + value)
    return path


def excluded(name):
    return name in EXCLUDED or name.startswith(("_build", ".dev"))


def validate_config(value):
    """Pure shape/path validation: does not inspect or mutate the filesystem."""
    required = {"schema_version", "evidence_root", "serialization_lock", "build_lock", "source_closure",
                "project", "build_target", "provider", "dune", "toolchain", "python", "support_tools",
                "pdk_root", "environment", "flow", "profile", "assignments"}
    optional = {"sdk_identity_files", "endpoint_timeouts", "preparation_timeout", "stage_timeout", "startup_timeout", "rpc_timeout", "lock_timeout", "outer_build_lock"}
    require(isinstance(value, dict), "configuration must be an object")
    require(required <= value.keys(), "missing configuration keys: " + str(sorted(required - value.keys())))
    require(not value.keys() - required - optional, "unknown configuration keys: " + str(sorted(value.keys() - required - optional)))
    require(type(value["schema_version"]) is int and value["schema_version"] == 1, "schema_version must be 1")
    for key in ("evidence_root", "serialization_lock", "build_lock", "provider", "dune", "toolchain", "python", "support_tools", "pdk_root"):
        require(isinstance(value[key], str) and Path(value[key]).is_absolute(), key + " must be absolute")
    relative(value["project"])
    relative(value["build_target"])
    require(value["build_target"].endswith(".exe") and not value["build_target"].startswith(("-", "@")),
            "build_target must name an executable .exe target")
    require(isinstance(value["source_closure"], list) and value["source_closure"], "source_closure must be nonempty")
    destinations = []
    for item in value["source_closure"]:
        require(isinstance(item, dict) and set(item) == {"source", "destination"}, "invalid source_closure entry")
        require(isinstance(item["source"], str) and Path(item["source"]).is_absolute(), "source must be absolute")
        dest = relative(item["destination"])
        require(not any(excluded(p) for p in dest.parts), "excluded closure destination")
        require(not any(dest.is_relative_to(p) or p.is_relative_to(dest) for p in destinations), "overlapping closure destinations")
        destinations.append(dest)
    require(any(Path(value["project"]).is_relative_to(p) for p in destinations), "project outside source closure")
    for key in ("flow", "profile"):
        require(isinstance(value[key], str) and value[key], key + " must be nonempty")
    require(isinstance(value["assignments"], list) and all(isinstance(x, str) for x in value["assignments"]), "assignments must be strings")
    env = value["environment"]
    require(isinstance(env, dict) and all(isinstance(k, str) and isinstance(v, str) and "\0" not in k + v and "=" not in k for k, v in env.items()), "invalid environment")
    require(bool(env.get("PATH")), "explicit environment.PATH required")
    require(not any(k in env for k in ("GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES")),
            "global Git repository selectors are forbidden; source contexts are scoped")
    require(isinstance(value.get("sdk_identity_files", []), list) and
            all(isinstance(p, str) and Path(p).is_absolute() for p in value.get("sdk_identity_files", [])),
            "sdk_identity_files must identify installed SDK/provider receipts")
    require(not any(k.startswith("HARDCAML_ASIC_SYNTHESIS") for k in env), "synthesis-only envelope is forbidden")
    if "outer_build_lock" in value:
        require(isinstance(value["outer_build_lock"], str) and Path(value["outer_build_lock"]).is_absolute(), "outer_build_lock must be absolute")
        require(Path(value["outer_build_lock"]) != Path(value["build_lock"]), "outer_build_lock and build_lock must differ to prevent deadlock")
    times = value.get("endpoint_timeouts", {})
    require(isinstance(times, dict) and set(times) <= set(ENDPOINTS), "unknown endpoint timeout")
    for key, seconds in {**times, **{k: value[k] for k in optional - {"endpoint_timeouts", "sdk_identity_files", "outer_build_lock"} if k in value}}.items():
        require(type(seconds) in (int, float) and 0 < seconds < float("inf"), "positive finite timeout required: " + key)
    return value


def digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def save(path, value):
    temporary = path.with_suffix(path.suffix + ".pending")
    temporary.write_text(json.dumps(value, indent=2) + "\n")
    temporary.replace(path)


def sexp(value):
    if isinstance(value, (list, tuple)):
        return "(" + " ".join(map(sexp, value)) + ")"
    return json.dumps(str(value), ensure_ascii=False)


def parse(text):
    tokens = re.findall(r'"(?:\\.|[^"\\])*"|[()]|[^\s()]+', text)
    stack, result = [], []
    current = result
    for token in tokens:
        if token == "(":
            child = []
            current.append(child)
            stack.append(current)
            current = child
        elif token == ")":
            require(bool(stack), "unbalanced S-expression")
            current = stack.pop()
        else:
            if token.startswith('"'):
                # Sexplib uses decimal byte escapes, unlike JSON's Unicode escapes.
                def escape(match):
                    if match[1] is None:
                        return match[0]
                    byte = int(match[1])
                    require(byte <= 255, "invalid Sexplib byte escape")
                    return "\\u%04x" % (byte if byte < 128 else 0xdc00 + byte)
                token = re.sub(r'\\(?:([0-9]{3})|.)', escape, token)
                current.append(json.loads(token).encode("utf-8", "surrogateescape").decode("utf-8", "surrogateescape"))
            else:
                current.append(token)
    require(not stack and len(result) == 1, "invalid S-expression response")
    return result[0]


def field(record, key):
    for entry in record:
        if isinstance(entry, list) and len(entry) == 2 and entry[0] == key:
            return entry[1]
    raise ValueError("missing typed field: " + key)


def validate_journal(records, prefix, stream_id, emission_finished=None, artifacts=None):
    """Sequence/elapsed and publication checks. Provider inspect validates crypto.

    recorded_at is retained evidence, never an intra-stream ordering clock.
    emission_finished is a legacy argument, deliberately not compared to wall time.
    """
    require(bool(records), "missing native observation journal")
    expected = ["implementation." + stage for stage in prefix]
    starts, finishes, publications = [], [], []
    active = None
    previous = None
    previous_elapsed = 0
    for index, event in enumerate(records, 1):
        require(event["stream_id"] == stream_id and event["sequence"] == index, "journal stream/sequence mismatch")
        require(event["previous_sha256"] == previous, "journal hash-chain link mismatch")
        previous = event["sha256"]
        elapsed = event["elapsed_seconds"]
        require(type(elapsed) in (int, float) and previous_elapsed <= elapsed < float("inf"), "journal elapsed clock regressed/invalid")
        previous_elapsed = elapsed
        if event["event"] == "started":
            occurrence = event["data"]["occurrence"]
            key = occurrence["action_key"]
            require(active is None and key in expected, "overlapping or successor occurrence")
            require(occurrence["occurrence_id"] == stream_id + "/" + key, "wrong occurrence stream identity")
            active = key
            starts.append(key)
        elif event["event"] == "published":
            occurrence = event["data"]["occurrence"]
            artifact = event["data"]["artifact"]
            require(active == occurrence["action_key"] and artifact["boundary"] == active.removeprefix("implementation."), "publication is not associated with active stage")
            publications.append(artifact)
        elif event["event"] == "finished":
            occurrence = event["data"]["occurrence"]
            require(active == occurrence["action_key"] and active is not None, "finish without exact preceding start")
            require(occurrence["status"] == "completed" and occurrence["exit_code"] == 0, "native occurrence did not complete exit0")
            finishes.append(active)
            active = None
    require(records[0]["event"] == "allocated" and records[-1]["event"] == "outcome", "journal lacks allocation/terminal outcome")
    require(active is None and starts == finishes == expected, "journal differs from exact ordered prefix")
    require(records[-1]["data"]["status"] == "completed" and records[-1]["data"]["exit_code"] == 0, "journal outcome not completed exit0")
    require([a["boundary"] for a in publications] == prefix, "journal must publish each exact stage once")
    if artifacts is not None:
        require(publications == artifacts, "journal publications differ from inspected artifacts")


def validate_report(report, observation, recipe, stream_id):
    """Full public report, not merely a terminal observation envelope."""
    require(recipe["schema_version"] == 4 and recipe["initial_boundary"] is None, "fresh schema4 recipe required")
    execution = report["execution"]
    require(execution["attempt_id"] == stream_id and execution["plan"] == recipe and
            execution["status"] == "completed" and execution["exit_code"] == 0, "report execution identity/plan/completion mismatch")
    require(execution["occurrences"] == observation["state"]["occurrences"], "report occurrence mismatch")
    artifacts = execution["artifacts"]
    require(artifacts == observation["state"]["artifacts"] == [c["reference"] for c in report["checkpoints"]],
            "report/observation/checkpoint artifact associations differ")
    require([a["boundary"] for a in artifacts] == recipe["stages"], "exact ordered artifact prefix required, including Timing")
    endpoint = recipe["stages"][-1]
    require(report["completion"] == dict(requested=endpoint, physical="full" if endpoint == "signoff" else endpoint),
            "report requested/physical completion differs")
    require(report["methodology"] == observation["methodology"], "report methodology differs from exact observation")
    require(report["acceptance"] == report["external_postcheck"] == "not_evaluated", "execution must not imply acceptance/external postcheck")


def validate_historical_plan(plan_path, historical, stream_id, base):
    """Validate both byte identities and the complete provider-canonical JSON value."""
    snapshot = Path(historical["snapshot_path"])
    require(snapshot.resolve().is_relative_to(base.resolve()), "historical snapshot outside private rung")
    require(historical["attempt_id"] == stream_id and digest(snapshot) == historical["snapshot_sha256"], "historical snapshot byte digest/stream mismatch")
    emitted = json.loads(Path(plan_path).read_text())
    captured = json.loads(snapshot.read_text())
    encode = lambda value: json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False)
    require(encode(emitted) == encode(captured), "provider canonical snapshot differs from full emitted plan JSON")
    require(historical["plan_identity"] == historical["expected_plan_identity"] == emitted["plan_identity"] and
            historical["bundle_identity"] == emitted["bundle_identity"], "historical expected/actual plan or bundle identity differs")
    return dict(emitted_sha256=digest(plan_path), historical_sha256=digest(snapshot), historical_path=str(snapshot),
                equality="complete JSON value including types; provider canonical serialization may differ in bytes")


def validate_timing(analysis, report, execution_file, base):
    raw = report["timing_analysis"]
    target = field(analysis, "target")
    stream = report["execution"]["attempt_id"]
    require(raw["schema_version"] == 2 and raw["stage"] == "timing" and raw["status"] == "completed", "native schema2 Timing analysis required")
    require(raw["attempt_id"] == stream and raw["occurrence_id"] == stream + "/implementation.timing" and
            raw["analysis_id"] == stream + "/post-pnr-sta", "Timing analysis identities differ")
    for key in ("attempt_id", "occurrence_id", "analysis_id", "source_digest", "execution_sha256", "stage"):
        require(field(target, key) == raw[key], "typed/provider Timing target mismatch: " + key)
    require(re.fullmatch(r"[0-9a-f]{64}", raw["source_digest"]) is not None, "invalid provider-validated Timing digest")
    require(json.loads(field(analysis, "evidence")) == raw, "typed Timing evidence differs from provider-validated report")
    require(raw["producer"]["class_id"] == "OpenROAD.STAPostPNR" and
            json.loads(field(analysis, "producer")[0]) == raw["producer"], "Timing native producer differs")
    source = Path(raw["execution_file"])
    require(field(target, "execution_file") == [str(source)] and
            str(source) in (str(execution_file), str(execution_file) + ".timing-source") and
            source.resolve().is_relative_to(base.resolve()), "unexpected Timing execution source")
    require(digest(source) == raw["execution_sha256"], "Timing source bytes changed")
    frozen = json.loads(source.read_text())
    require(frozen["attempt_id"] == stream and frozen["plan"] == report["execution"]["plan"] and
            frozen["status"] == raw["enclosing_status"] == field(analysis, "enclosing_status"), "Timing frozen source binding mismatch")
    prefix = select_prefix("timing")
    require([o["action_key"] for o in frozen["occurrences"][:len(prefix)]] == ["implementation." + s for s in prefix] and
            all(o["status"] == "completed" and o["exit_code"] == 0 for o in frozen["occurrences"][:len(prefix)]), "Timing source has incomplete prefix")
    require([a["boundary"] for a in frozen["artifacts"]] == prefix, "Timing source artifacts are not the exact Timing prefix")
    for key, identity_key, wanted in (("occurrences", "occurrence_id", raw["occurrence_id"]), ("artifacts", "boundary", "timing")):
        a = [v for v in frozen[key] if v[identity_key] == wanted]
        b = [v for v in report["execution"][key] if v[identity_key] == wanted]
        require(len(a) == 1 and a == b, "Timing frozen/main occurrence or checkpoint differs")
    for entry in raw["inventory"]:
        path = Path(entry["path"])
        require(path.resolve().is_relative_to(base.resolve()) and digest(path) == entry["sha256"], "Timing inventory bytes changed")
    return dict(source_path=str(source), source_sha256=digest(source), source_digest=raw["source_digest"],
                source_digest_validation="successful installed provider report", enclosing_status=raw["enclosing_status"])


def screen_text(data, width=240, height=55):
    """Current ANSI cells, not substring matching stale transcript frames."""
    cells = [[" " for _ in range(width)] for _ in range(height)]
    x = y = 0
    for token in re.findall(r'\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1b\\)|.)|[^\x1b]+', data.decode("utf-8", "replace")):
        if token.startswith("\x1b["):
            values, code = token[2:-1], token[-1]
            if values.startswith("?") or not re.fullmatch(r"[0-9;]*", values):
                continue
            args = [int(v or 0) for v in values.split(";")]
            n = args[0] or 1
            if code in "Hf": y, x = n - 1, (args[1] or 1) - 1 if len(args) > 1 else 0
            elif code == "A": y = max(0, y - n)
            elif code == "B": y = min(height - 1, y + n)
            elif code == "C": x = min(width - 1, x + n)
            elif code == "D": x = max(0, x - n)
            elif code == "G": x = n - 1
            elif code in "JKX":
                for yy in range(height):
                    for xx in range(width):
                        erase = (code == "J" and (args[0] in (2, 3) or (args[0] == 0 and (yy, xx) >= (y, x)) or (args[0] == 1 and (yy, xx) <= (y, x))))
                        erase |= (yy == y and code == "K" and (args[0] == 2 or (args[0] == 0 and xx >= x) or (args[0] == 1 and xx <= x)))
                        erase |= (yy == y and code == "X" and x <= xx < x + n)
                        if erase: cells[yy][xx] = " "
        elif not token.startswith("\x1b"):
            for char in token:
                if char == "\r": x = 0
                elif char == "\n": y = min(height - 1, y + 1)
                elif char == "\b": x = max(0, x - 1)
                elif unicodedata.combining(char):
                    if 0 < x <= width and 0 <= y < height: cells[y][x - 1] += char
                elif char >= " ":
                    if 0 <= y < height and 0 <= x < width: cells[y][x] = char
                    x += 2 if unicodedata.east_asian_width(char) in ("W", "F") else 1
    return "\n".join("".join(row).rstrip() for row in cells)


def enabled_command(text, title):
    # Palette overlays share screen rows with background tiles. Fence its cell
    # segment, rather than treating the entire terminal row as one command.
    return any(segment.strip() == "> " + title for line in text.splitlines()
               for segment in re.split("[│┃║]", line))


def owned_processes(token):
    """Exact inherited capability token plus kernel PID/start identity; no argv matching."""
    result = []
    expected = ("HARDCAML_WORKBENCH_PYRAMID_OWNER=" + token).encode()
    for entry in Path("/proc").iterdir():
        if not entry.name.isdigit(): continue
        try:
            if expected not in (entry / "environ").read_bytes().split(b"\0"): continue
            stat = (entry / "stat").read_text().rsplit(")", 1)[1].split()
            result.append(dict(pid=int(entry.name), start=stat[19], state=stat[0]))
        except (FileNotFoundError, ProcessLookupError):
            pass
        except PermissionError:
            # Different user's processes cannot inherit this private capability.
            continue
    return result


def child_identities():
    result = []
    for pid in (Path("/proc/self/task") / str(os.getpid()) / "children").read_text().split():
        try:
            stat = (Path("/proc") / pid / "stat").read_text().rsplit(")", 1)[1].split()
            result.append(dict(pid=int(pid), start=stat[19], state=stat[0], proof="subreaper-adoption"))
        except FileNotFoundError: pass
    return result


def signal_owned(identity, token, signum):
    """pidfd prevents PID reuse between verification and signaling."""
    try:
        fd = os.pidfd_open(identity["pid"])
    except ProcessLookupError:
        return
    try:
        candidates = child_identities() if identity.get("proof") == "subreaper-adoption" else owned_processes(token)
        if any(p["pid"] == identity["pid"] and p["start"] == identity["start"] for p in candidates):
            signal.pidfd_send_signal(fd, signum)
    finally:
        os.close(fd)


def reap_owned(token, timeout=10, baseline=None):
    history = []
    tracked = {}
    # Only enable ancestry proof after the synchronous runner's direct producer
    # roots have been waited. Pre-existing children are explicitly excluded.
    baseline = None if baseline is None else {(p["pid"], p["start"]) for p in baseline}
    def inventory():
        values = owned_processes(token)
        if baseline is not None:
            values += [p for p in child_identities() if (p["pid"], p["start"]) not in baseline]
        return list({(p["pid"], p["start"]): p for p in values}.values())
    for signum in (signal.SIGTERM, signal.SIGKILL):
        deadline = time.monotonic() + timeout
        while True:
            live = inventory()
            tracked.update({p["pid"]: p for p in live})
            history.append(dict(signal=int(signum), processes=live))
            for identity in live: signal_owned(identity, token, signum)
            # The runner is a subreaper. Direct children have already been waited;
            # remaining children are adopted private descendants, never owner jobs.
            pending = False
            for pid, identity in list(tracked.items()):
                try:
                    stat = (Path("/proc") / str(pid) / "stat").read_text().rsplit(")", 1)[1].split()
                    if stat[19] != identity["start"]:
                        del tracked[pid]
                        continue
                    waited, _ = os.waitpid(pid, os.WNOHANG)
                    if waited: del tracked[pid]
                    else: pending = True
                except (ChildProcessError, FileNotFoundError):
                    del tracked[pid]
            if not inventory() and not pending: return history
            require(time.monotonic() < deadline or signum == signal.SIGTERM, "owned detached descendants remain")
            if time.monotonic() >= deadline: break
            time.sleep(.05)
    require(not inventory(), "owned descendants remain after bounded cleanup")
    return history


@contextmanager
def locked(path, timeout):
    with Path(path).open("a") as stream:
        deadline = time.monotonic() + timeout
        while True:
            try:
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                require(time.monotonic() < deadline, "lock timeout: " + str(path))
                time.sleep(.1)
        try:
            yield
        finally:
            fcntl.flock(stream, fcntl.LOCK_UN)


def copy_closure(config, destination, deadline=None):
    """Copy regular source bytes only. Reject escaping symlinks and special files."""
    inventory = []
    for item in config["source_closure"]:
        source = Path(item["source"]).resolve(strict=True)
        target = destination / item["destination"]

        def visit(src, dst, ancestry):
            require(deadline is None or time.monotonic() < deadline, "endpoint timeout copying source closure")
            resolved = src.resolve(strict=True)
            require(resolved.is_relative_to(source), "source symlink escapes closure: " + str(src))
            require(resolved not in ancestry, "source symlink cycle: " + str(src))
            if resolved.is_dir():
                dst.mkdir(parents=True, exist_ok=True)
                for child in sorted(resolved.iterdir()):
                    if not excluded(child.name):
                        visit(child, dst / child.name, ancestry | {resolved})
            else:
                require(resolved.is_file(), "source special file: " + str(src))
                raw = resolved.read_bytes()
                dst.parent.mkdir(parents=True, exist_ok=True)
                dst.write_bytes(raw)
                dst.chmod(resolved.stat().st_mode & 0o777)
                inventory.append(dict(source=str(src), resolved=str(resolved), destination=str(dst.relative_to(destination)),
                                      sha256=hashlib.sha256(raw).hexdigest(), bytes=len(raw)))
        visit(source, target, set())
    return inventory


def stop(process):
    if process is None:
        return
    # Popen retains the direct child's PID until wait. Detached descendants are
    # separately capability-verified, never killed by a reused process-group ID.
    if process.poll() is None:
        process.terminate()
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=10)


class Rung:
    def __init__(self, config, args, base, endpoint, result):
        self.c, self.args, self.base, self.endpoint, self.result = config, args, base, endpoint, result
        self.root = base / "source" / config["project"]
        self.daemon = self.client = None
        self.master = None
        self.url = None
        self.sequence = 0
        self.owner_token = uuid.uuid4().hex
        self.foreign_children = child_identities()
        self.started_wall = time.time()
        self.data = bytearray()
        self.capture_screen = True
        self.docker = None
        import ctypes
        require(ctypes.CDLL(None, use_errno=True).prctl(36, 1, 0, 0, 0) == 0, "Linux child subreaper required")
        self.deadline = time.monotonic() + config.get("endpoint_timeouts", {}).get(endpoint, DEFAULT_TIMEOUTS[endpoint])
        self.env = dict(config["environment"])
        for key, name in (("HOME", "home"), ("XDG_CONFIG_HOME", "config"), ("XDG_STATE_HOME", "client-state"), ("TMPDIR", "scratch")):
            path = base / name
            path.mkdir()
            self.env[key] = str(path)
        self.env.update(TERM="xterm-256color", PYTHONDONTWRITEBYTECODE="1", HARDCAML_WORKBENCH_PYRAMID_OWNER=self.owner_token)
        self.result["native_resource_environment"] = {k: self.env[k] for k in ("OMP_NUM_THREADS", "OPENROAD_THREADS", "_OPENLANE_MAX_CORES", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS") if k in self.env}
        self.result["source_build_budget"] = dict(coordinator_jobs=2, adapter_arguments="recorded in dune-invocations.jsonl", override=True)

    def check(self, condition, message):
        self.result.setdefault("checks", []).append(dict(passed=bool(condition), assertion=message))
        require(condition, message)

    def remaining(self, cap=30):
        left = self.deadline - time.monotonic()
        require(left > 0, "endpoint timeout: " + self.endpoint)
        return min(cap, left)

    def command(self, argv, label, timeout=30):
        self.sequence += 1
        stem = self.base / f"{self.sequence:05d}-{label}"
        save(stem.with_suffix(".argv.json"), list(map(str, argv)))
        with stem.with_suffix(".stdout").open("wb") as out, stem.with_suffix(".stderr").open("wb") as err:
            process = subprocess.Popen(list(map(str, argv)), cwd=self.root, env=self.env, stdout=out, stderr=err, start_new_session=True)
            try:
                code = process.wait(timeout=self.remaining(timeout))
            finally:
                stop(process)
        require(code == 0, label + " failed: see " + str(stem))
        return stem.with_suffix(".stdout").read_text()

    def containers(self):
        if self.docker is None: return []
        ids = self.command([self.docker, "ps", "-aq", "--no-trunc"], "container-ids").split()
        require(len(ids) <= 4096 and all(re.fullmatch(r"[0-9a-f]{64}", i) for i in ids), "invalid/unbounded Docker inventory")
        if not ids: return []
        # A concurrent deletion may make inspect fail. Fail closed; never infer
        # absence from a failed engine query or abbreviated name match.
        values = json.loads(self.command([self.docker, "inspect", *ids], "container-inspect"))
        return [v for v in values if any(Path(m["Source"]).resolve().is_relative_to(self.base.resolve())
                                        for m in v.get("Mounts", []) if m.get("Source"))]

    def cleanup_containers(self):
        history = []
        if self.docker is None: return history
        for _ in range(3):
            owned = self.containers()
            history.append(owned)
            if not owned: return history
            for container in owned:
                identity = container["Id"]
                require(re.fullmatch(r"[0-9a-f]{64}", identity), "full owned container ID required")
                # Revalidate the exact immutable ID and private mount capability
                # immediately before any mutation. Names/ancestor image are not ownership.
                current = next((c for c in self.containers() if c["Id"] == identity), None)
                if current is None: continue
                if current["State"]["Running"]:
                    self.command([self.docker, "stop", "--time", "5", identity], "stop-owned-container", 15)
                self.command([self.docker, "rm", identity], "remove-owned-container", 15)
        require(not self.containers(), "owned containers remain")
        return history

    def rpc(self, operation="Get", domain="asic", cleanup=False):
        old = self.deadline
        if cleanup:
            self.deadline = time.monotonic() + 15
        try:
            response = parse(self.command([self.args.client, "--plain", "--connect", self.url,
                "--project-root", self.root, "--environment", "inherited", "--api", "--" + domain + "-operation", operation],
                domain, self.c.get("rpc_timeout", 30)))
            require(response[0] == "Ok", "typed RPC rejected: " + str(response))
            return response[1]
        finally:
            self.deadline = old

    def wait(self, predicate, label, cap=None):
        end = min(self.deadline, time.monotonic() + cap) if cap else self.deadline
        while True:
            value = predicate()
            if value:
                return value
            self.drain(.1)
            require(time.monotonic() < end, "timeout: " + label)
            require(self.daemon is None or self.daemon.poll() is None, "private daemon exited")
            time.sleep(.2)

    def prepare(self):
        inventory = copy_closure(self.c, self.base / "source", self.deadline)
        save(self.base / "source-identity.json", inventory)
        self.result["source_manifest_sha256"] = digest(self.base / "source-identity.json")
        require(self.root.is_dir(), "copied project missing")
        self.docker = shutil.which("docker", path=self.env["PATH"])
        require(self.docker, "real-run cleanup admission requires Docker CLI in explicit PATH, including elaboration")
        self.containers()  # Read-only engine admission before any source producer.
        # No installed root companions or ownership manifests are adopted.
        target = self.root / "_build/default" / self.c["build_target"]
        prep = [["schema_version", 1], ["build_target", self.c["build_target"]],
                ["results_root", str(self.base / "preparation")], ["timeout_seconds", self.c.get("preparation_timeout", 600)]]
        asic = [["schema_version", 1], ["project_executable", str(target)], ["provider_executable", self.c["provider"]],
                ["results_root", str(self.base / "results")], ["toolchain", self.c["toolchain"]],
                *[[k, [self.c[k]]] for k in ("python", "support_tools", "pdk_root")],
                ["stage_timeout_seconds", [str(self.c.get("stage_timeout", 7200))]]]
        for name, content in (("preparation", prep), ("asic", asic)):
            path = self.root / ("hardcaml-workbench-" + name + ".sexp")
            path.write_text(sexp(content) + "\n")
            self.result[name + "_config_sha256"] = digest(path)
        # Inherit_daemon resolves only this locked wrapper. Override the adapter's
        # -j6 with the task's -j2 budget; never build in the installed source tree.
        bindir = self.base / "bin"
        bindir.mkdir()
        self.prepare_git(bindir)
        wrapper = bindir / "dune"
        wrapper.write_text("#!" + sys.executable + "\nimport os,sys,fcntl\n"
            "import time\nlock=open(" + repr(self.c["build_lock"]) + ",'a')\n"
            "deadline=time.monotonic()+" + repr(self.c.get("lock_timeout", 120)) + "\n"
            "while True:\n"
            " try: fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB); break\n"
            " except BlockingIOError:\n"
            "  if time.monotonic()>=deadline: raise TimeoutError('source build lock timeout')\n"
            "  time.sleep(.1)\n"
            "os.set_inheritable(lock.fileno(),True)\na=sys.argv[1:]\n"
            "original=list(a)\n"
            "if a and a[0]=='build':\n"
            " a=[x for x in a if not x.startswith('-j')]\n a[1:1]=['-j2']\n"
            " if '--root' not in a: a[1:1]=['--root'," + repr(str(self.root)) + "]\n"
            "import json\nwith open(" + repr(str(self.base / "dune-invocations.jsonl")) + ",'a') as out:\n"
            " out.write(json.dumps(dict(requested=original,executed=[" + repr(self.c["dune"]) + "]+a,coordinator_jobs=2))+'\\n')\n"
            "os.execv(" + repr(self.c["dune"]) + ", [" + repr(self.c["dune"]) + "]+a)\n")
        wrapper.chmod(0o700)
        self.env["PATH"] = str(bindir) + os.pathsep + self.env["PATH"]
        save(self.base / "effective-environment.json", self.env)
        # Discovery needs the project CLI. This private bootstrap is not counted
        # as the workflow build: the launch still submits its own build/emission jobs.
        self.command([wrapper, "build", "-j2", self.c["build_target"]], "bootstrap-build", self.c.get("preparation_timeout", 600))
        self.result["source_cli_sha256"] = digest(target)
        version = json.loads(self.command([self.c["provider"], "--version", "--json"], "provider-version"))
        save(self.base / "provider-version.json", version)
        contract = version["cli_contract"]
        self.check(contract["version"] == 4 and contract["capabilities"].get("namedflow1") is True,
                   "installed CLI4 namedflow provider")
        if self.endpoint in ("timing", "signoff"):
            self.check(contract["capabilities"].get("timing_stage1") is True, "installed explicit Timing stage capability")

    def prepare_git(self, bindir):
        """Private metadata copies; the existing dispatcher scopes them to source roots."""
        git = shutil.which("git", path=self.env["PATH"])
        require(git is not None, "explicit environment PATH must resolve real Git")
        git = str(Path(git).resolve(strict=True))
        contexts = {}
        self.env.update(GIT_OPTIONAL_LOCKS="0", GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull)
        for index, item in enumerate(self.c["source_closure"]):
            source = Path(item["source"]).resolve(strict=True)
            if not (source / ".git").is_dir():
                continue
            metadata = self.base / "git-metadata" / str(index)
            metadata.parent.mkdir(exist_ok=True)
            self.command([git, "clone", "--bare", "--no-hardlinks", str(source), str(metadata)], "copy-source-git", 120)
            # Carry the index privately for faithful tracked/dirty queries. No
            # command ever uses the owner's metadata as its writable Git context.
            if (source / ".git/index").is_file():
                shutil.copyfile(source / ".git/index", metadata / "index")
            contexts[str((self.base / "source" / item["destination"]).resolve())] = str(metadata)
        if not contexts:
            return
        dispatcher = self.root / "scripts/workbench_git.py"
        require(dispatcher.is_file(), "Git source closure requires its existing scripts/workbench_git.py dispatcher")
        shutil.copyfile(dispatcher, bindir / "git")
        (bindir / "git").chmod(0o700)
        context = dict(schema_version=1, real_git=git, real_git_sha256=digest(git), source_roots=contexts)
        save(bindir / "git-context.json", context)
        save(self.base / "git-context.json", dict(context, dispatcher_sha256=digest(dispatcher)))
        self.result["git_context_sha256"] = digest(self.base / "git-context.json")
        for source_root, metadata in contexts.items():
            observed = self.command([bindir / "git", "-C", source_root, "rev-parse", "--absolute-git-dir"], "source-git-context").strip()
            self.check(observed == metadata, "source Git selects only private copied metadata")
        for key in ("support_tools", "pdk_root"):
            observed = self.command([bindir / "git", "-C", self.c[key], "rev-parse", "--show-toplevel"], key + "-git-context").strip()
            self.check(Path(observed).resolve() == Path(self.c[key]).resolve(), key + " Git remains independent of source context")

    def start(self):
        discovery = self.base / "discovery"
        discovery.mkdir()
        with (self.base / "daemon.log").open("wb") as log:
            argv = [str(self.args.daemon), "--port", "0", "--discovery-dir", str(discovery), "--state-dir", str(self.base / "state")]
            save(self.base / "daemon-argv.json", argv)
            self.daemon = subprocess.Popen(argv, env=self.env, cwd=self.root, stdout=log, stderr=log, start_new_session=True)
        metadata = discovery / "daemon.sexp"
        self.wait(metadata.exists, "private daemon discovery", self.c.get("startup_timeout", 120))
        self.url = field(parse(metadata.read_text()), "endpoint")
        from urllib.parse import urlsplit
        parsed = urlsplit(self.url)
        require(parsed.hostname in ("127.0.0.1", "::1", "localhost") and parsed.port not in (None, 41735), "not a private daemon endpoint")
        snap = self.rpc("Discover")
        self.check(not field(snap, "runs") and not field(snap, "workflows"), "new private state has no runs/workflows")
        self.wait(lambda: field(self.rpc(), "flows"), "installed flow discovery", self.c.get("startup_timeout", 120))
        flow = next(f for f in field(self.rpc(), "flows") if field(f, "id") == self.c["flow"])
        self.check(self.c["profile"] in field(flow, "profiles"), "configured profile advertised by installed flow")
        endpoint = "synthesis" if self.endpoint == "elaboration" else self.endpoint
        self.check(endpoint in field(flow, "fresh_stage_endpoints"), "installed normal provider advertises requested fresh endpoint")
        selection = [["flow", self.c["flow"]], ["profile", self.c["profile"]], ["endpoint", endpoint], ["assignments", self.c["assignments"]]]
        # Stage inputs via typed RPC; the actual production launch form consumes
        # them through its dispatcher, not Launch_fresh from the harness.
        staged = self.rpc("(Stage_fresh (selection %s) (elaboration_only %s) (expected_plan_identity ()))" % (sexp(selection), str(self.endpoint == "elaboration").lower()))
        self.intent_id = field(field(staged, "fresh_intent")[0], "id")
        self.selection = selection
        self.master, slave = pty.openpty()
        try:
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 55, 240, 0, 0))
            argv = [str(self.args.client), "--connect", self.url, "--project-root", str(self.root), "--environment", "inherited"]
            save(self.base / "client-argv.json", argv)
            self.client = subprocess.Popen(argv, cwd=self.root, env=self.env, stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
        finally:
            os.close(slave)
        self.wait(lambda: "stage checklist" in self.current_screen().lower(), "visible initialized production workspace", 120)
        workspace = self.rpc(domain="workspace")
        overview = next(w for w in field(workspace, "workspaces") if field(w, "preset") == ["overview"])
        self.launch_workspace = field(overview, "id")
        self.launch_context = field(overview, "context")
        self.workspace_before = workspace
        save(self.base / "workspace-before-launch.json", workspace)
        title = "Launch and view planned run in captured context"
        for key in (b" ", b"c", b"c"):
            self.key(key)
        self.wait(lambda: "COMMAND PALETTE" in self.current_screen(), "actual command palette visible", 30)
        self.key(title.encode())
        self.key(b"\x1b[A" * 100)
        full_title = title + " — " + ("Elaboration" if self.endpoint == "elaboration" else self.endpoint)
        self.wait(lambda: enabled_command(self.current_screen(), full_title),
                  "selected exact enabled production launch command", 30)
        self.check("overview" in self.current_screen().lower(), "intended Overview context visible before launch")
        current = self.rpc()
        self.check(field(field(current, "fresh_intent")[0], "id") == self.intent_id, "visible launch still uses exact current staged intent")
        before_return = self.rpc(domain="workspace")
        self.check(field(before_return, "contexts") == field(workspace, "contexts"), "intended workspace context unchanged before Return")
        (self.base / "enabled-launch.screen.txt").write_text(self.current_screen())
        self.key(b"\r")
        self.capture_screen = False
        self.data.clear()

    def current_screen(self):
        self.drain(.1)
        text = screen_text(bytes(self.data))
        (self.base / "current.screen.txt").write_text(text)
        return text

    def drain(self, seconds=.1):
        if self.master is None:
            return
        end = time.monotonic() + seconds
        with (self.base / "client.ansi").open("ab") as log:
            while time.monotonic() < end:
                if select.select([self.master], [], [], max(0, min(.05, end - time.monotonic())))[0]:
                    try:
                        raw = os.read(self.master, 65536)
                    except OSError:
                        break
                    if not raw:
                        break
                    log.write(raw)
                    if self.capture_screen:
                        require(len(self.data) + len(raw) <= 32 * 1024 * 1024, "bounded prelaunch screen transcript exceeded")
                        self.data.extend(raw)
        require(self.client is None or self.client.poll() is None, "PTY client exited")

    def key(self, raw):
        with (self.base / "keys.jsonl").open("a") as log:
            log.write(json.dumps(dict(time=time.time(), hex=raw.hex())) + "\n")
        os.write(self.master, raw)
        self.drain(.2)

    def execute(self):
        self.prepare()
        self.start()

        def terminal():
            snap = self.rpc()
            save(self.base / "latest-snapshot.json", snap)
            require(not field(snap, "finalizations"), "fresh endpoint must not finalize or adopt finalization")
            workflows = field(snap, "workflows")
            require(len(workflows) <= 1, "launch form created multiple workflows")
            if workflows and field(workflows[0], "run") and not self.result.get("selected_run_verified"):
                target = field(workflows[0], "run")
                def selected():
                    ws = self.rpc(domain="workspace")
                    save(self.base / "workspace-after-allocation.json", ws)
                    arrangement = next(w for w in field(ws, "workspaces") if field(w, "id") == self.launch_workspace)
                    require(field(arrangement, "context") == self.launch_context, "captured workspace context changed")
                    context = next(c for c in field(ws, "contexts") if field(c, "id") == self.launch_context)
                    return field(context, "selected_run") == target
                self.wait(selected, "PTY launch selected exact allocated run in captured context", 30)
                self.result["selected_run_verified"] = True
            if workflows and field(workflows[0], "phase") in ("Completed", "Failed", "Cancelled", "Interrupted"):
                return workflows[0]
        w = self.wait(terminal, "fresh " + self.endpoint + " workflow")
        save(self.base / "workflow.json", w)
        self.check(field(w, "phase") == "Completed", "fresh workflow completed: " + str(field(w, "error")))
        intent = field(w, "intent")
        self.check(field(intent, "selection") == self.selection, "exact requested selection captured")
        self.check(field(intent, "elaboration_only") == str(self.endpoint == "elaboration").lower(), "exact elaboration-only mode")
        self.check(not field(intent, "expected_plan_identity"), "no pinned preview or resume guard")
        self.check(bool(field(w, "preparation_id")) and field(w, "elaboration_status") == "completed", "own fresh preparation completed")
        build, emission = (field(w, key)[0] for key in ("build_job", "emission_job"))
        for job in (build, emission):
            self.check(field(job, "state") == "Complete" and field(job, "exit_status") == [["Exited", "0"]], "source job completed exit0")
        stamp = lambda obj, key: datetime.fromisoformat(field(obj, key)[0]).timestamp()
        self.check(field(build, "id") != field(emission, "id") and stamp(build, "finished_at") <= stamp(emission, "started_at"), "distinct build before emission")
        prepared = field(w, "prepared")[0]
        plan_path = Path(field(prepared, "methodology_plan_path"))
        bundle = Path(field(prepared, "bundle_directory"))
        self.check(plan_path.resolve().is_relative_to(self.base) and bundle.resolve().is_relative_to(self.base), "emitted inputs are test-owned")
        plan = json.loads(plan_path.read_text())
        self.check(digest(plan_path) == field(prepared, "methodology_plan_digest"), "exact emitted plan bytes/digest")
        self.check(plan["plan_identity"] == field(prepared, "plan_identity") and plan["bundle_identity"] == field(prepared, "bundle_identity"), "exact emitted bundle/plan identities")
        manifest = json.loads((bundle / "manifest.json").read_text())
        self.check(manifest == json.loads(plan["bundle_manifest"]) and manifest["identity"] == plan["bundle_identity"], "exact emitted manifest")
        for member in manifest["files"]:
            member_path = bundle / relative(member["path"])
            self.check(member_path.resolve().is_relative_to(bundle.resolve()) and digest(member_path) == member["sha256"], "bundle member bytes: " + member["path"])
        save(self.base / "plan.json", plan)
        self.result.update(workflow_id=field(w, "id"), preparation_id=field(w, "preparation_id"),
                           bundle_identity=plan["bundle_identity"], plan_identity=plan["plan_identity"], build_job=field(build, "id"), emission_job=field(emission, "id"))
        recipe = plan["methodology"]["recipe"]
        self.check(recipe["schema_version"] == 4 and recipe["initial_boundary"] is None, "fresh schema4 recipe with no resume boundary")
        if self.endpoint == "elaboration":
            snap = self.rpc()
            self.check(not field(w, "run") and not field(w, "reference") and not field(snap, "runs"), "elaboration has no physical allocation")
            ws = self.rpc(domain="workspace")
            self.check(field(ws, "contexts") == field(self.workspace_before, "contexts"), "elaboration retained intended workspace context")
            self.result["observed"] = []
            return
        prefix = select_prefix(self.endpoint)
        recipe = plan["methodology"]["recipe"]
        self.check(recipe["stages"] == prefix and recipe["initial_boundary"] is None, "exact fresh plan prefix; no initial checkpoint")
        run_ref = field(w, "run")[0]
        reference = field(w, "reference")[0]
        attempt = Path(field(reference, "attempt"))
        self.check(attempt.resolve().is_relative_to(self.base), "exact allocated attempt is private")
        observation = json.loads(self.command([self.c["provider"], "observation", "inspect", attempt, "--json"], "observation"))
        save(self.base / "observation.json", observation)
        self.result["observed"] = observation["state"]["plan"]["stages"]
        self.result["reference"] = reference
        self.result["final_results"] = observation["final_results"]
        if self.endpoint == "signoff":
            self.check(observation["final_results"]["physical_completion"] == "completed", "native signoff physical completion recorded")
        self.check(observation["stream_id"] == field(reference, "stream_id") and not observation["writer_active"], "exact terminal stream allocation")
        state = observation["state"]
        self.check(state["plan"] == recipe and state["outcome"]["status"] == "completed" and state["outcome"]["exit_code"] == 0, "provider completed exact selected recipe exit0")
        occurrences = state["occurrences"]
        self.check([o["action_key"] for o in occurrences] == ["implementation." + s for s in prefix], "ordered exact occurrences; no successors")
        self.check(all(o["status"] == "completed" and o["exit_code"] == 0 for o in occurrences), "every requested occurrence completed exit0")
        records = []
        snapshot_dir = self.base / "journal-snapshot"
        snapshot_dir.mkdir()
        self.result["journal_source_files"] = []
        for path in sorted(attempt.glob("[0-9]*.json")):
            raw = path.read_bytes()
            (snapshot_dir / path.name).write_bytes(raw)
            records.append(json.loads(raw))
            self.result["journal_source_files"].append(dict(path=str(path), snapshot=str(snapshot_dir / path.name),
                                                           sha256=hashlib.sha256(raw).hexdigest(), bytes=len(raw)))
        self.check(len(records) == observation["cursor"], "snapshot covers exact provider-inspected terminal journal cursor")
        validate_journal(records, prefix, field(reference, "stream_id"), artifacts=state["artifacts"])
        save(self.base / "journal.json", records)
        self.result["journal_validation"] = dict(cryptographic_validation="successful installed provider observation inspect", independent_checks="sequence, elapsed clock, hash links, exact starts/publications/finishes/outcome", parsed_snapshot_sha256=digest(self.base / "journal.json"))
        self.check(True, "native journal exact serial sequence/elapsed/publications/outcome; recorded_at may regress")
        method = observation["methodology"]
        self.check(method["plan_identity"] == plan["plan_identity"] and method["bundle_identity"] == plan["bundle_identity"], "allocated run consumes exact prepared identities")
        historical = method["reference"]
        self.result["historical_plan"] = validate_historical_plan(plan_path, historical, field(reference, "stream_id"), self.base)
        self.check(True, "historical canonical plan has its own verified byte digest and exact full emitted JSON value")
        execution_file = Path(observation["execution_file"])
        self.check(execution_file.resolve().is_relative_to(self.base), "exact execution record is test-owned")
        report = json.loads(self.command([self.c["provider"], "report", execution_file, "--json"], "full-report"))
        save(self.base / "report.json", report)
        validate_report(report, observation, recipe, field(reference, "stream_id"))
        self.check(True, "full report completed exact prefix with matching occurrences, artifact/checkpoint associations and methodology")
        self.result["report_completion"] = report["completion"]
        self.result["execution_sha256"] = digest(execution_file)
        for artifact in report["execution"]["artifacts"]:
            path = Path(artifact["path"]).resolve(strict=True)
            self.check(path.is_relative_to(self.base), "checkpoint is test-owned: " + artifact["boundary"])
            self.result.setdefault("checkpoint_manifests", []).append(dict(reference=artifact, manifest_sha256=digest(path / "manifest.json")))
        self.rpc("(Observe %s)" % sexp(run_ref))

        def stages_ready():
            snap = self.rpc()
            run = next(r for r in field(snap, "runs") if field(r, "run") == run_ref)
            return run if field(run, "stages") else None
        run = self.wait(stages_ready, "typed stage observations", 120)
        save(self.base / "run.json", run)
        self.check(field(run, "reference") == reference, "typed run reference matches workflow allocation")
        self.check(field(run, "selection") == [self.selection] and field(run, "status") == "completed" and not field(run, "error"), "typed run terminal status and exact selection")
        statuses = {field(s, "id"): field(s, "status") for s in field(run, "stages")}
        self.result["typed_statuses"] = statuses
        self.check(set(statuses) == set(PHYSICAL), "complete schema4 seven-stage typed checklist, including Timing")
        self.check(all(statuses.get(s) == "Completed" for s in prefix), "typed requested physical stages completed, including Timing")
        self.check(all(v == "Not_requested" for s, v in statuses.items() if s not in prefix), "typed successors not requested")
        if "timing" in prefix:
            self.rpc("(Load_summary %s)" % sexp(run_ref))

            def summary_ready():
                summaries = field(self.rpc(), "summaries")
                return next((s for s in summaries if field(s, "run") == run_ref and field(s, "timing_analysis")), None)
            summary = self.wait(summary_ready, "typed native timing analysis", 120)
            save(self.base / "summary.json", summary)
            analysis = field(summary, "timing_analysis")[0]
            target = field(analysis, "target")
            self.check(field(analysis, "status") == "Completed" and field(target, "attempt_id") == field(reference, "stream_id"), "typed timing completed for exact allocated stream")
            self.check(field(summary, "plan_identity") == [plan["plan_identity"]] and field(summary, "completion") == "completed", "typed summary exact plan and completed execution")
            self.result["timing_goal"] = field(analysis, "timing_goal")
            self.result["timing_source"] = validate_timing(analysis, report, execution_file, self.base)
            # Goal is evidence, not a fabricated pass: execution acceptance does
            # not imply timing closure, DRC/LVS, or finalization acceptance.
        self.check(stamp(emission, "finished_at") <= stamp(w, "finished_at"), "emission completed before physical workflow completion")

    def close(self):
        mask = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGINT, signal.SIGTERM})
        try:
            self._close()
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, mask)

    def _close(self):
        errors = []
        self.deadline = time.monotonic() + 120
        cleanup = dict(status="failed", cancellation_error=None, process_error=None, container_error=None)
        cleanup["ownership_proof"] = "private inherited capability with pidfd/start identity; exact subreaper adoptees excluding pre-existing children; immutable container ID with mount under this unique private rung"
        # Stop keyboard dispatch before reading/cancelling daemon-owned work.
        try:
            stop(self.client)
        except BaseException as error:
            errors.append(str(error))
        self.client = None
        if self.url and self.daemon and self.daemon.poll() is None:
            try:
                snap = self.rpc(cleanup=True)
                save(self.base / "cleanup-before-cancel.json", snap)
                save(self.base / "cleanup-last-snapshot.json", snap)
                for workflow in field(snap, "workflows"):
                    if field(workflow, "phase") not in ("Completed", "Failed", "Cancelled", "Interrupted"):
                        snap = self.rpc("(Cancel_workflow %s)" % sexp(field(workflow, "id")), cleanup=True)
                        save(self.base / "cleanup-last-snapshot.json", snap)
                end = time.monotonic() + 20
                while True:
                    snap = self.rpc(cleanup=True)
                    save(self.base / "cleanup-last-snapshot.json", snap)
                    require(not field(snap, "finalizations"), "unexpected finalization in private state")
                    if not any(field(w, "phase") not in ("Completed", "Failed", "Cancelled", "Interrupted") for w in field(snap, "workflows")):
                        break
                    require(time.monotonic() < end, "private cancellation did not settle")
                    time.sleep(.2)
            except BaseException as error:
                errors.append(str(error))
                cleanup["cancellation_error"] = traceback.format_exc()
        for process in (self.daemon,):
            try:
                stop(process)
            except BaseException as error:
                errors.append(str(error))
        try:
            cleanup["process_history"] = reap_owned(self.owner_token, timeout=5, baseline=self.foreign_children)
            cleanup["remaining_processes"] = owned_processes(self.owner_token)
            foreign = {(p["pid"], p["start"]) for p in self.foreign_children}
            cleanup["remaining_adopted_children"] = [p for p in child_identities() if (p["pid"], p["start"]) not in foreign]
            require(not cleanup["remaining_processes"], "owned detached processes remain")
            require(not cleanup["remaining_adopted_children"], "adopted owned descendants remain")
        except BaseException as error:
            errors.append(str(error))
            cleanup["process_error"] = traceback.format_exc()
        try:
            cleanup["container_history"] = self.cleanup_containers()
            cleanup["remaining_containers"] = self.containers()
            require(not cleanup["remaining_containers"], "owned containers remain")
        except BaseException as error:
            errors.append(str(error))
            cleanup["container_error"] = traceback.format_exc()
        if self.master is not None:
            os.close(self.master)
            self.master = None
        self.result["cleanup_errors"] = errors
        cleanup["status"] = "failed" if errors else "passed"
        last_snapshot = self.base / "cleanup-last-snapshot.json"
        if last_snapshot.exists(): cleanup["last_cancellation_snapshot_sha256"] = digest(last_snapshot)
        save(self.base / "cleanup.json", cleanup)
        self.result["cleanup_receipt_sha256"] = digest(self.base / "cleanup.json")
        require(not errors, "cleanup failed: " + str(errors))


def preflight(config, args, read_only=False):
    for key in ("provider", "dune", "python"):
        require(Path(config[key]).is_file() and os.access(config[key], os.X_OK), "installed executable missing: " + key)
    for path in (args.daemon, args.client):
        require(path.is_file() and os.access(path, os.X_OK), "prebuilt executable missing: " + str(path))
    for key in ("toolchain", "support_tools", "pdk_root"):
        require(Path(config[key]).is_dir(), "installed directory missing: " + key)
    for path in config.get("sdk_identity_files", []):
        require(Path(path).is_file(), "installed identity file missing: " + path)
    evidence = Path(config["evidence_root"]).resolve()
    require((read_only and not evidence.exists()) or evidence.is_dir(), "evidence_root must be a directory")
    for key in ("toolchain", "support_tools", "pdk_root"):
        installed = Path(config[key]).resolve(strict=True)
        require(not evidence.is_relative_to(installed) and not installed.is_relative_to(evidence), "installed/evidence roots overlap")
    for item in config["source_closure"]:
        source = Path(item["source"]).resolve(strict=True)
        require(source.is_dir(), "closure source must be directory")
        nested_excluded = evidence.is_relative_to(source) and any(excluded(p) for p in evidence.relative_to(source).parts)
        require((not evidence.is_relative_to(source) or nested_excluded) and not source.is_relative_to(evidence), "source/evidence roots overlap outside excluded storage")
        for key in ("serialization_lock", "build_lock"):
            require(not Path(config[key]).resolve().is_relative_to(source), "locks must not mutate source closure")
    for key in ("serialization_lock", "build_lock"):
        require(Path(config[key]).parent.is_dir(), "lock parent must exist")
    require(Path(config["serialization_lock"]).resolve() != Path(config["build_lock"]).resolve(), "build and execution locks must differ")
    if "outer_build_lock" in config:
        require(Path(config["outer_build_lock"]).resolve() != Path(config["build_lock"]).resolve(), "outer_build_lock and build_lock resolve to the same lock")
    # Diagnose a busy pre-existing build lock before allocating evidence/children.
    if not read_only:
        with locked(config["build_lock"], config.get("lock_timeout", 120)):
            pass


def verify_retained(capture):
    """Read-only public inspection/report replay; never repairs the original result."""
    capture = capture.resolve(strict=True)
    original_file = capture / "result.json"
    original = json.loads(original_file.read_text())
    config = validate_config(json.loads((capture / "config.json").read_text()))
    require(len(original["rungs"]) == 1 and original["rungs"][0]["endpoint"] != "elaboration", "one retained physical rung required")
    row = original["rungs"][0]
    source = Path(row["evidence"]).resolve(strict=True)
    require(source.is_relative_to(capture), "foreign retained rung")
    with locked(config["serialization_lock"], config.get("lock_timeout", 120)):
        output = capture.parent / ("verification-" + uuid.uuid4().hex)
        output.mkdir(mode=0o700)
        receipt = dict(status="failed", scope="read-only retained evidence verification; original alias result unchanged",
                       eda_launches=0, original_result=str(original_file), original_status=original["status"],
                       original_result_sha256=digest(original_file), verifier_sha256=digest(__file__), invocation=sys.argv)
        from types import SimpleNamespace
        reader = Rung(config, SimpleNamespace(), output, row["endpoint"], {})
        reader.root = source / "source" / config["project"]
        reader.deadline = time.monotonic() + 180
        def inventory():
            return {str(p.relative_to(capture)): digest(p) for p in sorted(capture.rglob("*")) if p.is_file() and not p.is_symlink()}
        before = inventory()
        save(output / "original-inventory-before.json", before)
        print("Read-only verification evidence: " + str(output), flush=True)
        try:
            require(all(digest(p) == h for p, h in original["identities"].items()), "installed identities drifted from original launch")
            workflow = json.loads((source / "workflow.json").read_text())
            prepared = field(workflow, "prepared")[0]
            reference = field(workflow, "reference")[0]
            stream = field(reference, "stream_id")
            plan_path = Path(field(prepared, "methodology_plan_path"))
            plan = json.loads(plan_path.read_text())
            require(digest(plan_path) == field(prepared, "methodology_plan_digest"), "emitted plan changed")
            observed = json.loads(reader.command([config["provider"], "observation", "inspect", field(reference, "attempt"), "--json"], "retained-observation"))
            require(observed == json.loads((source / "observation.json").read_text()), "retained observation changed")
            require(observed["stream_id"] == stream and observed["writer_active"] is False and observed["state"]["outcome"] == dict(status="completed", exit_code=0, error=None), "retained exact execution not completed exit0")
            receipt["historical_plan"] = validate_historical_plan(plan_path, observed["methodology"]["reference"], stream, source)
            execution = Path(observed["execution_file"])
            report = json.loads(reader.command([config["provider"], "report", execution, "--json"], "retained-full-report", 60))
            save(output / "report.json", report)
            recipe = plan["methodology"]["recipe"]
            require(recipe["stages"] == select_prefix(row["endpoint"]), "retained requested prefix differs")
            validate_report(report, observed, recipe, stream)
            records = json.loads((source / "journal.json").read_text())
            validate_journal(records, recipe["stages"], stream, artifacts=observed["state"]["artifacts"])
            snapshot = json.loads((source / "cleanup-last-snapshot.json").read_text())
            run = next(r for r in field(snapshot, "runs") if field(r, "run") == field(workflow, "run")[0])
            statuses = {field(s, "id"): field(s, "status") for s in field(run, "stages")}
            require(set(statuses) == set(PHYSICAL) and all(statuses[s] == ("Completed" if s in recipe["stages"] else "Not_requested") for s in PHYSICAL), "typed stage statuses differ from exact prefix")
            require(field(run, "status") == "completed" and not field(snapshot, "finalizations"), "typed run incomplete or unexpected finalizations")
            cleanup = json.loads((source / "cleanup.json").read_text())
            require(cleanup["status"] == "passed" and not cleanup["remaining_processes"] and not cleanup["remaining_adopted_children"] and not cleanup["remaining_containers"], "original cleanup not verified")
            ws = json.loads((source / "workspace-after-allocation.json").read_text())
            require(any(field(c, "selected_run") == field(workflow, "run") for c in field(ws, "contexts")), "retained workspace did not select exact run")
            transports = []
            for path in sorted((source / "results").rglob("*-transport.json")):
                transport = json.loads(path.read_text())
                transports.append(dict(path=str(path), sha256=digest(path), argv=transport["argv"]))
            receipt.update(stream_id=stream, workflow_id=field(workflow, "id"), recipe=recipe, stages=statuses,
                           occurrences=report["execution"]["occurrences"], artifacts=report["execution"]["artifacts"],
                           report_completion=report["completion"], acceptance=report["acceptance"], external_postcheck=report["external_postcheck"],
                           execution_file=str(execution), execution_sha256=digest(execution), finalizations=0,
                           selected_run_verified=True, original_cleanup_sha256=digest(source / "cleanup.json"), transports=transports,
                           resource_limit_evidence="recorded transport argv; not an independent live task/thread peak measurement")
            if "timing" in recipe["stages"]:
                summary = next(s for s in field(snapshot, "summaries") if field(s, "run") == field(workflow, "run")[0])
                receipt["timing_source"] = validate_timing(field(summary, "timing_analysis")[0], report, execution, source)
            after = inventory()
            save(output / "original-inventory-after.json", after)
            require(before == after, "read-only replay changed original evidence bytes")
            receipt.update(status="passed", original_bytes_unchanged=True, inventoried_files=len(before))
        except BaseException:
            receipt["error"] = traceback.format_exc()
            raise
        finally:
            try:
                reader.close()
            except BaseException:
                receipt.update(status="failed", cleanup_error=traceback.format_exc())
                raise
            finally:
                save(output / "verification.json", receipt)
        print("PASS retained verification only; original alias remains " + original["status"] + ": " + str(output / "verification.json"))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--endpoint", choices=ENDPOINTS)
    mode.add_argument("--pyramid", action="store_true")
    mode.add_argument("--self-test", action="store_true")
    mode.add_argument("--preflight-only", action="store_true", help="read-only setup validation; no locks, builds, providers, or EDA")
    mode.add_argument("--verify-retained", type=Path, metavar="CAPTURE", help="read-only observation/report verification; never relaunch or change original status")
    parser.add_argument("--config", default=os.environ.get("HARDCAML_WORKBENCH_REAL_TEST_CONFIG", ""))
    parser.add_argument("--daemon", type=Path, help="prebuilt daemon; required with an explicit config, including --preflight-only")
    parser.add_argument("--client", type=Path, help="prebuilt client; required with an explicit config, including --preflight-only")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    if args.verify_retained:
        verify_retained(args.verify_retained)
        return
    spec = importlib.util.spec_from_file_location("pyramid_resolution", Path(__file__).with_name("resolve.py"))
    resolver = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(resolver)
    try:
        config, raw, resolved_inputs = resolver.resolve(args.config)
    except (ValueError, OSError, KeyError, TypeError, IndexError) as error:
        parser.error("real setup config: " + str(error))
    if args.preflight_only:
        apps = resolved_inputs.get("prebuilt_apps", {})
        args.daemon = args.daemon or (Path(apps["daemon"]) if "daemon" in apps else None)
        args.client = args.client or (Path(apps["client"]) if "client" in apps else None)
    if args.daemon is None or args.client is None:
        parser.error("--daemon and --client prebuilt applications required; explicit config overrides require both flags even with --preflight-only (no installed-app guessing)")
    args.daemon, args.client = args.daemon.resolve(strict=True), args.client.resolve(strict=True)
    if args.preflight_only:
        preflight(config, args, read_only=True)
        print(json.dumps(dict(status="ready", config=config, resolved_inputs=resolved_inputs), indent=2))
        return
    interrupted = False
    def interrupt(signum, frame):
        nonlocal interrupted
        if not interrupted:
            interrupted = True
            raise InterruptedError("runner interrupted by signal " + str(signum))
    signal.signal(signal.SIGTERM, interrupt)
    signal.signal(signal.SIGINT, interrupt)
    preflight(config, args, read_only=True)
    Path(config["evidence_root"]).mkdir(parents=True, exist_ok=True)
    preflight(config, args)
    os.umask(0o077)
    endpoints = list(ENDPOINTS) if args.pyramid else [args.endpoint]
    with locked(config["serialization_lock"], config.get("lock_timeout", 120)):
        blocked = Path(config["serialization_lock"] + ".cleanup-blocked.json")
        require(not blocked.exists(), "prior cleanup unresolved; inspect durable interlock: " + str(blocked))
        base = Path(config["evidence_root"]).resolve() / ("pyramid-" + uuid.uuid4().hex)
        base.mkdir()
        (base / "config.json").write_bytes(raw)
        require(all(digest(p) == h for p, h in resolved_inputs["inputs_sha256"].items()), "resolved setup inputs changed; retry")
        save(base / "resolved-inputs.json", resolved_inputs)
        snapshots = base / "resolved-inputs"
        snapshots.mkdir()
        for index, (path, expected) in enumerate(resolved_inputs["inputs_sha256"].items()):
            target = snapshots / str(index)
            shutil.copyfile(path, target)
            require(digest(target) == expected, "resolved input changed while snapshotting: " + path)
        report = dict(status="failed", config_path=resolved_inputs.get("config_path"), config_sha256=hashlib.sha256(raw).hexdigest(),
                      invocation=sys.argv, runner_sha256=digest(__file__),
                       identities={**{str(p): digest(p) for p in (args.daemon, args.client, Path(config["provider"]), Path(config["dune"]), Path(config["python"]), *map(Path, config.get("sdk_identity_files", [])))},
                                   **resolved_inputs["inputs_sha256"]},
                      installed_paths={k: config[k] for k in ("toolchain", "support_tools", "pdk_root")},
                      rungs=[dict(endpoint=e, requested=select_prefix(e), observed=None, status="not_run") for e in endpoints])
        print("Evidence: " + str(base), flush=True)
        save(base / "result.json", report)
        try:
            for result in report["rungs"]:
                require(all(digest(path) == expected for path, expected in report["identities"].items()), "installed app/provider/SDK identity drift before rung")
                directory = base / result["endpoint"]
                directory.mkdir()
                result.update(status="running", evidence=str(directory))
                save(base / "result.json", report)
                rung = None
                try:
                    rung = Rung(config, args, directory, result["endpoint"], result)
                    rung.execute()
                    result["status"] = "passed"
                except BaseException:
                    result.update(status="failed", error=traceback.format_exc())
                    raise
                finally:
                    try:
                        if rung is not None:
                            rung.close()
                        require(all(digest(path) == expected for path, expected in report["identities"].items()), "installed app/provider/SDK identity drift during rung")
                    except BaseException:
                        result.update(status="failed", cleanup_error=traceback.format_exc())
                        save(blocked, dict(evidence=str(directory), cleanup_error=result["cleanup_error"], status="cleanup_unresolved"))
                        raise
                    finally:
                        save(base / "result.json", report)
            report["status"] = "passed"
        except BaseException:
            report["error"] = traceback.format_exc()
            raise
        finally:
            save(base / "result.json", report)
        print("PASS " + ", ".join(endpoints) + ": " + str(base))


def self_test():
    """No real provider, daemon, Dune or EDA is invoked."""
    import tempfile
    import unittest

    class Controls(unittest.TestCase):
        def test_prefix(self):
            for index, endpoint in enumerate(ENDPOINTS):
                self.assertEqual(select_prefix(endpoint), list(PHYSICAL[:index]))
            with self.assertRaises(ValueError):
                select_prefix("resume")

        def test_sexp(self):
            value = [["path", 'a " b\\c\n'], ["option", []]]
            self.assertEqual(parse(sexp(value)), value)
            self.assertEqual(parse(r'"\195\169"'), "é")
            for value in ("(", ")", "a b"):
                with self.assertRaises(ValueError):
                    parse(value)

        def test_config(self):
            c = dict(schema_version=1, **{k: "/installed/" + k for k in ("evidence_root", "serialization_lock", "build_lock", "provider", "dune", "toolchain", "python", "support_tools", "pdk_root")},
                     source_closure=[dict(source="/source", destination="example")], project="example", build_target="cli/project.exe",
                     environment={"PATH": "/usr/bin"}, sdk_identity_files=["/installed/receipt.json"], flow="standard", profile="balanced", assignments=[])
            self.assertIs(validate_config(c), c)
            self.assertGreaterEqual(DEFAULT_TIMEOUTS["signoff"], 7200)
            for patch in ({"project": "../main"}, {"endpoint_timeouts": {"signoff": 0}}, {"environment": {}},
                          {"environment": {"PATH": "/bin", "HARDCAML_ASIC_SYNTHESIS_TASK_LIMIT": "6"}},
                          {"environment": {"PATH": "/bin", "GIT_DIR": "/owner/.git"}},
                          {"outer_build_lock": c["build_lock"]},
                          {"source_closure": [dict(source="/s", destination="."), dict(source="/t", destination="example")]},
                          {"unexpected": True}):
                with self.subTest(patch=patch), self.assertRaises(ValueError):
                    validate_config(dict(c, **patch))

        def test_copy_isolation(self):
            with tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                src = root / "original"
                src.mkdir()
                (src / "ok.ml").write_text("source")
                for name in ("_build", "_build_private", ".dev", "results"):
                    (src / name).mkdir()
                    (src / name / "owner").write_text("untouched")
                closure = {"source_closure": [dict(source=str(src), destination="example")]}
                first = copy_closure(closure, root / "copy1")
                second = copy_closure(closure, root / "copy2")
                self.assertEqual(len(first), 1)
                self.assertEqual(first, second)
                (root / "copy1/example/ok.ml").write_text("changed")
                self.assertEqual((src / "ok.ml").read_text(), "source")
                self.assertEqual((root / "copy2/example/ok.ml").read_text(), "source")
                (src / "escape").symlink_to(root)
                with self.assertRaises(ValueError):
                    copy_closure(closure, root / "copy3")

        def test_lock_contention(self):
            with tempfile.TemporaryDirectory() as tmp:
                path = Path(tmp) / "lock"
                with locked(path, 1):
                    with self.assertRaises(ValueError):
                        with locked(path, .02):
                            self.fail("lock admitted concurrent command")
                with locked(path, .1):
                    pass

        def test_journal_rejects_failed_reordered_and_successor_work(self):
            import copy
            events = []
            def event(name, key=None):
                previous = events[-1]["sha256"] if events else None
                data = {} if key is None else {"occurrence": dict(action_key=key, occurrence_id="stream/" + key,
                                                                  status="completed", exit_code=0)}
                if name == "published": data["artifact"] = dict(boundary=key.removeprefix("implementation."), identity=key, path="/fixture/" + key)
                if name == "outcome": data = dict(status="completed", exit_code=0)
                events.append(dict(stream_id="stream", sequence=len(events) + 1, previous_sha256=previous,
                                   sha256="fixture-not-a-cryptographic-claim-" + str(len(events)), elapsed_seconds=len(events),
                                   recorded_at="2026-11-11T00:00:01Z" if len(events) % 2 else "2020-01-01T00:00:00Z", event=name, data=data))
            event("allocated")
            for stage in ("synthesis", "floorplan"):
                event("started", "implementation." + stage)
                event("published", "implementation." + stage)
                event("finished", "implementation." + stage)
            event("outcome")
            validate_journal(events, ["synthesis", "floorplan"], "stream", 0)
            for mode in ("failure", "successor", "reordered", "wrong-stream", "elapsed-regression", "outcome", "publication"):
                broken = copy.deepcopy(events)
                if mode == "failure":
                    broken[3]["data"]["occurrence"]["exit_code"] = 1
                elif mode == "successor":
                    broken[4]["data"]["occurrence"]["action_key"] = "implementation.signoff"
                elif mode == "reordered":
                    broken[1], broken[2] = broken[2], broken[1]
                elif mode == "wrong-stream":
                    broken[1]["stream_id"] = "owner"
                elif mode == "elapsed-regression": broken[2]["elapsed_seconds"] = 0
                elif mode == "outcome": broken[-1]["data"]["exit_code"] = 1
                elif mode == "publication": broken[2]["data"]["artifact"]["boundary"] = "signoff"
                with self.subTest(mode=mode), self.assertRaises(ValueError):
                    validate_journal(broken, ["synthesis", "floorplan"], "stream")

        def test_bounded_command_retains_output_and_reaps(self):
            from types import SimpleNamespace
            with tempfile.TemporaryDirectory() as tmp:
                base = Path(tmp)
                root = base / "source/project"
                root.mkdir(parents=True)
                config = dict(project="project", environment={"PATH": "/usr/bin"}, endpoint_timeouts={"elaboration": .2})
                rung = Rung(config, SimpleNamespace(), base, "elaboration", {})
                started = time.monotonic()
                with self.assertRaises(subprocess.TimeoutExpired):
                    rung.command([sys.executable, "-c", "import time; print('retained',flush=True); time.sleep(30)"], "bounded")
                self.assertLess(time.monotonic() - started, 5)
                self.assertIn("retained", next(base.glob("*.stdout")).read_text())
                rung.close()

        def test_full_schema4_report_requires_timing_artifacts_and_completion(self):
            import copy
            recipe = dict(schema_version=4, initial_boundary=None, stages=list(PHYSICAL))
            occurrences = [dict(action_key="implementation." + stage, status="completed", exit_code=0) for stage in PHYSICAL]
            artifacts = [dict(boundary=stage, path="/private/" + stage, identity=stage) for stage in PHYSICAL]
            observation = dict(state=dict(occurrences=occurrences, artifacts=artifacts), methodology={"identity": "exact"})
            report = dict(execution=dict(attempt_id="stream", plan=recipe, status="completed", exit_code=0,
                                         occurrences=occurrences, artifacts=artifacts),
                          completion=dict(requested="signoff", physical="full"), methodology={"identity": "exact"},
                          acceptance="not_evaluated", external_postcheck="not_evaluated",
                          checkpoints=[dict(reference=a) for a in artifacts])
            validate_report(report, observation, recipe, "stream")
            for mode in ("wrong-completion", "missing-timing", "wrong-artifact", "wrong-occurrence"):
                broken = copy.deepcopy(report)
                if mode == "wrong-completion":
                    broken["completion"]["physical"] = "synthesis"
                elif mode == "missing-timing":
                    broken["execution"]["artifacts"] = [a for a in artifacts if a["boundary"] != "timing"]
                elif mode == "wrong-artifact":
                    broken["checkpoints"][0]["reference"]["identity"] = "other"
                else:
                    broken["execution"]["occurrences"][0]["exit_code"] = 1
                with self.subTest(mode=mode), self.assertRaises(ValueError):
                    validate_report(broken, observation, recipe, "stream")

        def test_historical_plan_accepts_only_serialization_changes(self):
            with tempfile.TemporaryDirectory() as tmp:
                base = Path(tmp)
                emitted, historical = base / "emitted.json", base / "historical.json"
                document = dict(plan_identity="plan", bundle_identity="bundle", methodology={"enabled": True, "stages": ["synthesis"]})
                emitted.write_text(json.dumps(document, indent=2))
                historical.write_text(json.dumps(document, sort_keys=True, separators=(",", ":")))
                reference = dict(snapshot_path=str(historical), snapshot_sha256=digest(historical), attempt_id="stream",
                                 plan_identity="plan", expected_plan_identity="plan", bundle_identity="bundle")
                validated = validate_historical_plan(emitted, reference, "stream", base)
                self.assertNotEqual(validated["emitted_sha256"], validated["historical_sha256"])
                historical.write_text(json.dumps(dict(document, methodology={"enabled": 1, "stages": ["synthesis"]})))
                reference["snapshot_sha256"] = digest(historical)
                with self.assertRaisesRegex(ValueError, "full emitted plan JSON"):
                    validate_historical_plan(emitted, reference, "stream", base)

        def test_persistent_evidence_is_admitted_only_in_excluded_source_storage(self):
            from types import SimpleNamespace
            with tempfile.TemporaryDirectory() as tmp:
                base = Path(tmp)
                source, sdk = base / "source", base / "installed-sdk"
                source.mkdir()
                sdk.mkdir()
                evidence = source / ".dev/pyramid/evidence"
                evidence.mkdir(parents=True)
                c = dict(source_closure=[dict(source=str(source), destination="project")], evidence_root=str(evidence),
                         provider=sys.executable, dune=sys.executable, python=sys.executable,
                         toolchain=str(sdk), support_tools=str(sdk), pdk_root=str(sdk),
                         serialization_lock=str(base / "execution.lock"), build_lock=str(base / "source-build.lock"), lock_timeout=.02)
                args = SimpleNamespace(daemon=Path(sys.executable), client=Path(sys.executable))
                preflight(c, args)
                with locked(c["build_lock"], 1), self.assertRaisesRegex(ValueError, "lock timeout"):
                    preflight(c, args)
                public = source / "not-excluded"
                public.mkdir()
                with self.assertRaisesRegex(ValueError, "overlap"):
                    preflight(dict(c, evidence_root=str(public)), args)

        def test_real_detached_fixture_cleanup_build_emit_allocated_and_cancel_error(self):
            from types import SimpleNamespace
            for phase in ("Building", "Emitting", "Physical", "cancel-error"):
                with self.subTest(phase=phase), tempfile.TemporaryDirectory() as tmp:
                    base = Path(tmp)
                    (base / "source/project").mkdir(parents=True)
                    sentinel = subprocess.Popen([sys.executable, "-c", "import time;time.sleep(60)"], start_new_session=True)
                    config = dict(project="project", environment={"PATH": "/usr/bin", "OMP_NUM_THREADS": "1"})
                    rung = Rung(config, SimpleNamespace(), base, "elaboration", {})
                    self.assertEqual(rung.env["OMP_NUM_THREADS"], "1")
                    self.assertNotIn("OPENROAD_THREADS", rung.env)
                    child_file = base / "detached.pid"
                    code = ("import subprocess,sys,time; from pathlib import Path; "
                            "p=subprocess.Popen([sys.executable,'-c','import time;time.sleep(60)'],start_new_session=True,env=" + ("{}" if phase == "Physical" else "None") + "); "
                            "Path(sys.argv[1]).write_text(str(p.pid)); time.sleep(60)")
                    rung.daemon = subprocess.Popen([sys.executable, "-c", code, str(child_file)], env=rung.env, start_new_session=True)
                    rung.url = "fixture://private"
                    cancelled = False
                    def rpc(operation="Get", domain="asic", cleanup=False):
                        nonlocal cancelled
                        if operation.startswith("(Cancel_workflow"):
                            if phase == "cancel-error": raise ValueError("fixture cancellation rejected")
                            cancelled = True
                        return [["workflows", [[["id", "private-workflow"], ["phase", "Cancelled" if cancelled else ("Building" if phase == "cancel-error" else phase)]]]], ["finalizations", []]]
                    rung.rpc = rpc
                    try:
                        end = time.monotonic() + 5
                        while not child_file.exists():
                            require(time.monotonic() < end, "fixture child failed to start")
                            time.sleep(.02)
                        child_pid = int(child_file.read_text())
                        if phase != "Physical":
                            require(any(p["pid"] == child_pid for p in owned_processes(rung.owner_token)), "fixture detached child must carry ownership capability")
                        if phase == "cancel-error":
                            with self.assertRaisesRegex(ValueError, "cleanup failed"): rung.close()
                        else: rung.close()
                        self.assertFalse(Path("/proc", str(child_pid)).exists(), "exact detached child reaped")
                        self.assertEqual(owned_processes(rung.owner_token), [])
                        self.assertIsNone(sentinel.poll(), "unowned process must survive cleanup")
                        receipt = json.loads((base / "cleanup.json").read_text())
                        self.assertEqual(bool(receipt["cancellation_error"]), phase == "cancel-error")
                        if cancelled:
                            snapshot = json.loads((base / "cleanup-last-snapshot.json").read_text())
                            self.assertEqual(field(field(snapshot, "workflows")[0], "phase"), "Cancelled")
                    finally:
                        stop(rung.daemon)
                        reap_owned(rung.owner_token, timeout=1)
                        stop(sentinel)

        def test_current_screen_does_not_admit_stale_or_disabled_command(self):
            title = "Launch and view planned run in captured context — synthesis"
            old = ("> " + title).encode()
            self.assertIn(title, screen_text(old))
            self.assertNotIn(title, screen_text(old + b"\x1b[2J\x1b[HNo matching commands"))
            disabled = screen_text(("> " + title + " [not available]").encode())
            self.assertFalse(enabled_command(disabled, title))
            self.assertTrue(enabled_command("│ background │ > " + title + "     │ another tile │", title))

        def test_container_fixture_exact_mount_ownership_and_absence(self):
            from types import SimpleNamespace
            with tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                base = root / "rung"
                (base / "source/project").mkdir(parents=True)
                state = root / "engine.json"
                private_id, foreign_id = "a" * 64, "b" * 64
                save(state, {private_id: dict(Id=private_id, State={"Running": True}, Mounts=[{"Source": str(base / "results")}]),
                             foreign_id: dict(Id=foreign_id, State={"Running": True}, Mounts=[{"Source": str(root / "owner")}])})
                fixture = root / "docker-fixture"
                fixture.write_text("#!" + sys.executable + "\nimport json,sys\nfrom pathlib import Path\n"
                    "p=Path(" + repr(str(state)) + "); s=json.loads(p.read_text()); a=sys.argv[1:]\n"
                    "if a[0]=='ps': print('\\n'.join(s))\n"
                    "elif a[0]=='inspect': print(json.dumps([s[i] for i in a[1:]]))\n"
                    "elif a[0]=='stop': s[a[-1]]['State']['Running']=False; p.write_text(json.dumps(s))\n"
                    "elif a[0]=='rm': del s[a[-1]]; p.write_text(json.dumps(s))\n"
                    "else: raise ValueError(a)\n")
                fixture.chmod(0o700)
                rung = Rung(dict(project="project", environment={"PATH": "/usr/bin"}), SimpleNamespace(), base, "elaboration", {})
                rung.docker = str(fixture)
                rung.close()
                self.assertEqual(set(json.loads(state.read_text())), {foreign_id})
                cleanup = json.loads((base / "cleanup.json").read_text())
                self.assertEqual(cleanup["remaining_containers"], [])
                self.assertEqual(cleanup["container_history"][0][0]["Id"], private_id)

        def test_timing_frozen_source_running_signoff_and_exact_digest(self):
            import copy
            with tempfile.TemporaryDirectory() as tmp:
                base = Path(tmp)
                execution = base / "execution.json"
                source = base / "execution.json.timing-source"
                prefix = select_prefix("timing")
                occurrences = [dict(action_key="implementation." + s, occurrence_id="s/implementation." + s, status="completed", exit_code=0) for s in prefix]
                artifacts = [dict(boundary=s, identity=s, path=str(base / s)) for s in prefix]
                frozen = dict(attempt_id="s", plan={"stages": list(PHYSICAL)}, status="running", occurrences=occurrences, artifacts=artifacts)
                save(source, frozen)
                native = dict(schema_version=2, stage="timing", status="completed", attempt_id="s", occurrence_id="s/implementation.timing",
                              analysis_id="s/post-pnr-sta", source_digest="a" * 64, execution_sha256=digest(source), execution_file=str(source),
                              enclosing_status="running", producer={"class_id": "OpenROAD.STAPostPNR"}, inventory=[])
                report = dict(execution=dict(frozen, status="completed"), timing_analysis=native)
                def wire(raw):
                    return [["target", [[k, raw[k]] for k in ("attempt_id", "occurrence_id", "analysis_id", "source_digest", "execution_sha256", "stage")] + [["execution_file", [raw["execution_file"]]]]],
                            ["evidence", json.dumps(raw)], ["producer", [json.dumps(raw["producer"])]], ["enclosing_status", raw["enclosing_status"]]]
                self.assertEqual(validate_timing(wire(native), report, execution, base)["enclosing_status"], "running")
                for key, wrong in (("stage", "signoff"), ("analysis_id", "owner/post-pnr-sta"), ("execution_sha256", "0" * 64)):
                    changed = copy.deepcopy(native)
                    changed[key] = wrong
                    with self.subTest(key=key), self.assertRaises(ValueError):
                        validate_timing(wire(changed), dict(report, timing_analysis=changed), execution, base)

        def test_sigterm_while_waiting_for_preflight_lock_is_handled(self):
            with tempfile.TemporaryDirectory() as tmp:
                base = Path(tmp)
                ready = base / "ready"
                lock = base / "held.lock"
                config = dict(schema_version=1, evidence_root=str(base), serialization_lock=str(base / "serial.lock"), build_lock=str(lock),
                              source_closure=[dict(source="/source", destination="project")], project="project", build_target="project.exe",
                              provider=sys.executable, dune=sys.executable, python=sys.executable, toolchain="/tools", support_tools="/tt", pdk_root="/pdk",
                              environment={"PATH": "/usr/bin"}, flow="standard", profile="balanced", assignments=[])
                save(base / "config.json", config)
                code = ("import importlib.util,sys;from pathlib import Path; "
                        "s=importlib.util.spec_from_file_location('r',sys.argv[1]);m=importlib.util.module_from_spec(s);s.loader.exec_module(m); "
                        "m.preflight=lambda *a,**k:(Path(sys.argv[2]).write_text('ready'),m.locked(sys.argv[3],60).__enter__()); "
                        "sys.argv=['runner','--endpoint','elaboration','--config',sys.argv[4],'--daemon',sys.executable,'--client',sys.executable];m.main()")
                # The lambda's argv is rewritten by main's caller. Use immutable
                # closure paths, not mutable argv, for this controlled preflight.
                code = code.replace("Path(sys.argv[2])", "Path(" + repr(str(ready)) + ")").replace("m.locked(sys.argv[3],60)", "m.locked(" + repr(str(lock)) + ",60)")
                with locked(lock, 1):
                    process = subprocess.Popen([sys.executable, "-B", "-c", code, __file__, str(ready), str(lock), str(base / "config.json")], stderr=subprocess.PIPE)
                    try:
                        end = time.monotonic() + 5
                        while not ready.exists():
                            require(time.monotonic() < end, "signal fixture not ready")
                            time.sleep(.02)
                        process.send_signal(signal.SIGTERM)
                        _, error = process.communicate(timeout=5)
                        self.assertNotEqual(process.returncode, 0)
                        self.assertIn(b"InterruptedError", error)
                    finally: stop(process)

    suite = unittest.defaultTestLoader.loadTestsFromTestCase(Controls)
    require(unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful(), "runner self-tests failed")


if __name__ == "__main__":
    main()
