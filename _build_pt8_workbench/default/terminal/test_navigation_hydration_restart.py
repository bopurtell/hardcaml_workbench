"""Production navigation/host restore in separate fresh processes; no daemon or EDA."""
import pathlib
import subprocess
import sys
import tempfile


probe = str(pathlib.Path(sys.argv[1]).resolve())
subprocess.run([probe, "scheduler"], check=True)
with tempfile.TemporaryDirectory(prefix="navigation-hydration-") as state:
    subprocess.run([probe, "write", state], check=True)
    subprocess.run([probe, "read", state], check=True)
    print("fresh-process restore: active/focus, inactive Testing exact old attempt/artifact, Timing stage/filter/row, replacement/member fences")
