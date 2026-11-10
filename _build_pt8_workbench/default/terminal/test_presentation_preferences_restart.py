"""Run after the serialized build: python3 terminal/test_presentation_preferences_restart.py
_build/default/terminal/presentation_preferences_probe.exe

Also wired into the terminal runtest alias. Each probe invocation is a fresh process.
"""

import itertools
import pathlib
import re
import subprocess
import sys
import tempfile


def main():
    probe = str(pathlib.Path(sys.argv[1]).resolve())
    with tempfile.TemporaryDirectory(prefix="fs3-presentation-") as directory:
        state = pathlib.Path(directory) / "state"

        def run(mode, path=state, *extra):
            subprocess.run([probe, mode, str(path), *extra], check=True)

        run("missing")
        run("write")
        run("read")
        files = list(state.iterdir())
        assert len(files) == 1 and files[0].name.startswith("presentation-")
        assert files[0].stat().st_mode & 0o077 == 0
        original = files[0].read_bytes()
        run("write")
        run("read")
        assert files[0].read_bytes() == original
        assert len(list(state.iterdir())) == 1, "temporary file leaked"

        run("reset")  # Actual catalog reset, poll, save, then a fresh process.
        run("read-reset")
        assert b"not-persistent" not in files[0].read_bytes()
        run("write")
        run("read")

        # WB-019: every main/palette hint combination survives a fresh process,
        # without disturbing the global chrome choice.
        for combo in ("11", "10", "01", "00"):
            run("hints-write", state, combo)
            run("hints-read", state, combo)
        # Schema 2 (before WB-048 tile appearance) and schema 1 (before WB-019
        # hints) files stay readable; missing fields inherit.
        assert b"(schema_version 6)" in original and b"tile_appearance" in original
        run("headers-write")
        current = files[0].read_bytes()
        assert b"(tile_appearance ())" in current
        legacy_v2 = re.sub(rb"\s*\(tile_appearance \(\)\)", b"", current).replace(
            b"(schema_version 6)", b"(schema_version 2)"
        )
        assert b"tile_appearance" not in legacy_v2 and b"(schema_version 2)" in legacy_v2
        files[0].write_bytes(legacy_v2)
        run("read-legacy", state, "2")
        legacy = re.sub(
            rb"\s*\((main|palette)_hints (true|false)\)", b"", legacy_v2
        ).replace(b"(schema_version 2)", b"(schema_version 1)")
        assert b"hints" not in legacy and b"(schema_version 1)" in legacy
        files[0].write_bytes(legacy)
        run("read-legacy", state, "1")
        run("write")
        run("read")

        run("scopes-write")
        run("scopes-read")
        run("scopes-read-reset")
        # Schema 5 already recorded preload; migration keeps its explicit false.
        scopes_reset = files[0].read_bytes()
        assert b"(timing_preload false)" in scopes_reset
        files[0].write_bytes(
            scopes_reset.replace(b"(schema_version 6)", b"(schema_version 5)")
        )
        run("scopes-read-reset")
        for choices in itertools.product("itf", repeat=3):
            combo = "".join(choices)
            run("matrix-write", state, combo)
            run("matrix-read", state, combo)

        unknown_version = original.replace(b"(schema_version 6)", b"(schema_version 99)")
        # A schema 3 file missing its required appearance structure is rejected.
        cut = original.index(b"(tile_appearance")
        missing_appearance = original[:cut].rstrip() + b")\n"
        assert b"(tile_headers" in missing_appearance
        assert unknown_version != original
        for malformed in (b"(", unknown_version, missing_appearance, b" " * 65537):
            files[0].write_bytes(malformed)
            run("malformed")
            assert files[0].read_bytes() == malformed

        run("write")  # An explicit new choice may replace an unreadable old file.
        run("read")
        blocked = pathlib.Path(directory) / "blocked"
        blocked.write_text("not a directory")
        run("save-error", blocked)
    print("Presentation preferences: fresh-process retention and failure checks passed")


if __name__ == "__main__":
    main()
