#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
switch="${OPAM_SWITCH:-5.2.0+ox}"
build_dir="${HCW_BUILD_DIR:-$repo_root/_build}"
build_jobs="${HCW_BUILD_JOBS:-6}"
umask 077
work_root="$(mktemp -d "${TMPDIR:-/tmp}/hardcaml-workbench-native.XXXXXX")"
prefix="$work_root/prefix"
outside="$work_root/outside"
fixture="$work_root/fixture"
integrated_fixture="$work_root/integrated-fixture"
manifest_fixture="$work_root/manifest-fixture"
missing_driver_fixture="$work_root/missing-driver-fixture"
invalid_manifest_fixture="$work_root/invalid-manifest-fixture"
initialized_fixture="$work_root/initialized-fixture"
runtime="$work_root/runtime"
explicit_runtime="$work_root/explicit-runtime"
mkdir -p \
  "$prefix" "$outside" "$fixture" "$integrated_fixture" "$manifest_fixture" \
  "$missing_driver_fixture" "$invalid_manifest_fixture" "$initialized_fixture" \
  "$runtime" "$explicit_runtime"
mkdir -p "$work_root/home" "$work_root/config" "$work_root/state" \
  "$work_root/data" "$work_root/cache" "$work_root/tmp"

cp -R "$repo_root/test/fixtures/example_project/." "$fixture/"
cp -R "$repo_root/test/fixtures/example_project/." "$integrated_fixture/"
cp -R "$repo_root/test/fixtures/example_project/." "$manifest_fixture/"
cp -R "$repo_root/test/fixtures/example_project/." "$missing_driver_fixture/"
cp -R "$repo_root/test/fixtures/example_project/." "$invalid_manifest_fixture/"
rm -rf "$fixture/_build"
rm -rf \
  "$integrated_fixture/_build" "$manifest_fixture/_build" \
  "$missing_driver_fixture/_build" "$invalid_manifest_fixture/_build"
rm -f "$fixture/hardcaml-workbench.sexp"
rm -rf "$fixture/workbench"
rm -rf "$manifest_fixture/workbench"
cat >"$manifest_fixture/hardcaml-workbench.sexp" <<'EOF'
(lang hardcaml-workbench 1)
(project (name manifest-only-fixture))
(dune (build_alias @workbench-build) (test_alias @workbench-test))
EOF
cat >"$missing_driver_fixture/hardcaml-workbench.sexp" <<'EOF'
(lang hardcaml-workbench 1)
(project (name missing-driver-fixture))
(dune (driver ./workbench/missing_driver.exe))
EOF
cat >"$invalid_manifest_fixture/hardcaml-workbench.sexp" <<'EOF'
(lang hardcaml-workbench 99)
(project (name invalid-manifest-fixture))
(dune)
EOF
cat >"$initialized_fixture/dune-project" <<'EOF'
(lang dune 3.22)
(name installed_init_fixture)
EOF

metadata_path="$runtime/hardcaml-workbench/daemon.sexp"
client="$prefix/bin/hardcaml-workbench"

metadata_field() {
  local field="$1"
  perl -ne "print \"\$1\\n\" if /\\($field ([^()[:space:]]+)\\)/" "$metadata_path"
}

wait_dead() {
  local pid="$1"
  local attempt
  for attempt in $(seq 1 100); do
    if ! kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
    sleep 0.05
  done
  return 1
}

cleanup() {
  if [[ -f "$metadata_path" ]]; then
    local pid
    pid="$(metadata_field pid || true)"
    if [[ -n "$pid" ]]; then
      kill -TERM "$pid" 2>/dev/null || true
      wait_dead "$pid" || true
    fi
  fi
  rm -rf "$work_root"
}
trap cleanup EXIT

(
  cd "$repo_root"
  "$repo_root/scripts/with-switch.sh" dune build --build-dir "$build_dir" \
    -j"$build_jobs" -p hardcaml_workbench @install
  "$repo_root/scripts/with-switch.sh" dune install --build-dir "$build_dir" \
    -j"$build_jobs" --prefix "$prefix" hardcaml_workbench
)

# Keep toolchain lookup available to the broader checks, while installed application
# preferences, registry state, fallback paths and diagnostics are entirely private.
export OPAMROOT="${OPAMROOT:-$HOME/.opam}"
export HOME="$work_root/home"
export XDG_CONFIG_HOME="$work_root/config"
export XDG_STATE_HOME="$work_root/state"
export XDG_DATA_HOME="$work_root/data"
export XDG_CACHE_HOME="$work_root/cache"
export XDG_RUNTIME_DIR="$runtime"
export TMPDIR="$work_root/tmp"
unset HARDCAML_WORKBENCH_DIAGNOSTICS
cd "$outside"

# Installed initializer -> existing daemon session -> explicit client reload. This
# minimal fixture declares saved references only; no build or driver is requested.
XDG_RUNTIME_DIR="$runtime" "$client" --plain --project-root "$initialized_fixture" \
  --environment inherited >"$work_root/before-init.txt"
grep -Fq "Integration: Generic_dune" "$work_root/before-init.txt"
grep -Fq "Jobs: 0" "$work_root/before-init.txt"
"$prefix/bin/hardcaml-workbench-init" --root "$initialized_fixture" \
  --project-name installed-initialized --build-alias @saved-build --test-alias @saved-test \
  >"$work_root/initialize.txt"
cp "$initialized_fixture/hardcaml-workbench.sexp" "$work_root/initialized-manifest.sexp"
if "$prefix/bin/hardcaml-workbench-init" --root "$initialized_fixture" \
  >"$work_root/reinitialize.txt" 2>&1; then
  echo "error: installed initializer unexpectedly clobbered a manifest" >&2
  exit 1
fi
cmp "$initialized_fixture/hardcaml-workbench.sexp" "$work_root/initialized-manifest.sexp"
grep -Fq '(build_alias @saved-build)' "$initialized_fixture/hardcaml-workbench.sexp"
grep -Fq '(test_alias @saved-test)' "$initialized_fixture/hardcaml-workbench.sexp"
XDG_RUNTIME_DIR="$runtime" "$client" --plain --project-root "$initialized_fixture" \
  --environment inherited >"$work_root/initialized-before-reload.txt"
grep -Fq "Integration: Generic_dune" "$work_root/initialized-before-reload.txt"
XDG_RUNTIME_DIR="$runtime" "$client" --plain --project-root "$initialized_fixture" \
  --environment inherited --refresh-integration --wait >"$work_root/init-reload.txt"
XDG_RUNTIME_DIR="$runtime" "$client" --plain --project-root "$initialized_fixture" \
  --environment inherited >"$work_root/after-init.txt"
grep -Fq "Project: installed-initialized" "$work_root/after-init.txt"
grep -Fq "Integration: Manifest" "$work_root/after-init.txt"
grep -Fq "driver=absent" "$work_root/after-init.txt"
grep -Fq "Jobs: 0" "$work_root/after-init.txt"
if [[ -n "${HCW_NATIVE_EVIDENCE_DIR:-}" ]]; then
  # A new absolute destination is required, so existing evidence is never replaced.
  [[ "$HCW_NATIVE_EVIDENCE_DIR" = /* ]]
  mkdir "$HCW_NATIVE_EVIDENCE_DIR"
  cp "$work_root/before-init.txt" "$work_root/initialize.txt" \
    "$work_root/reinitialize.txt" "$work_root/initialized-before-reload.txt" \
    "$work_root/init-reload.txt" "$work_root/after-init.txt" \
    "$work_root/initialized-manifest.sexp" "$HCW_NATIVE_EVIDENCE_DIR/"
  sha256sum "$client" "$prefix/bin/hardcaml-workbench-init" \
    "$prefix/bin/hardcaml-workbench-daemon" >"$HCW_NATIVE_EVIDENCE_DIR/binaries.sha256"
  printf 'result=PASS\ncheck=installed-setup-handoff\ncwd=%s\nbuild_dir=%s\nbuild_jobs=%s\nHOME=%s\nXDG_CONFIG_HOME=%s\nXDG_STATE_HOME=%s\nXDG_DATA_HOME=%s\nXDG_CACHE_HOME=%s\nXDG_RUNTIME_DIR=%s\nassertions=generic-open,initialize,no-clobber,saved-aliases,no-implicit-reload,explicit-reload,manifest-name,no-driver,zero-jobs\n' \
    "$PWD" "$build_dir" "$build_jobs" "$HOME" "$XDG_CONFIG_HOME" \
    "$XDG_STATE_HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME" "$XDG_RUNTIME_DIR" \
    >"$HCW_NATIVE_EVIDENCE_DIR/receipt.txt"
fi
if [[ "${HCW_NATIVE_SETUP_ONLY:-0}" == 1 ]]; then
  printf 'Installed initializer/client handoff and no-clobber checks: passed\n'
  exit 0
fi

# The copied project remains a normal external Dune workspace.
"$repo_root/scripts/with-switch.sh" dune build -j"$build_jobs" --root "$fixture"
"$repo_root/scripts/with-switch.sh" dune runtest -j"$build_jobs" --root "$fixture"
"$repo_root/scripts/with-switch.sh" dune clean --root "$fixture"

(
  cd "$outside"
  XDG_RUNTIME_DIR="$runtime" "$client" --plain \
    --project-root "$fixture" --environment "opam:$switch" >first.txt
)
first_pid="$(metadata_field pid)"
first_endpoint="$(metadata_field endpoint)"
kill -0 "$first_pid"
grep -Fq "root=$fixture" "$outside/first.txt"
grep -Fq "Environment request: opam switch $switch  resolved=opam switch $switch" \
  "$outside/first.txt"
grep -Eq "Generic Dune workspace: contexts=[^;]+; [1-9][0-9]* inspected item" \
  "$outside/first.txt"
grep -Fq "Jobs: 0" "$outside/first.txt"

XDG_RUNTIME_DIR="$runtime" \
  "$repo_root/scripts/test-terminal-resize.py" "$client" \
  --project-root "$fixture" --environment "opam:$switch" \
  --expect-project-name hardcaml_workbench_fixture

# A single attached terminal session must consume discovery events and render the result.
XDG_RUNTIME_DIR="$runtime" \
  "$repo_root/scripts/test-terminal-resize.py" "$client" \
  --project-root "$integrated_fixture" --environment "opam:$switch" \
  --expect-live-discovery --expect-project-name hardcaml-counter-fixture

XDG_RUNTIME_DIR="$explicit_runtime" "$client" --plain --connect "$first_endpoint" \
  --project-root "$fixture" --environment "opam:$switch" \
  >"$work_root/explicit-success.txt"
grep -Fq "root=$fixture" "$work_root/explicit-success.txt"
test ! -e "$explicit_runtime/hardcaml-workbench/daemon.sexp"

# Submit without waiting, let that client exit, and observe the same daemon-owned job.
XDG_RUNTIME_DIR="$runtime" "$client" --plain --project-root "$fixture" \
  --environment "opam:$switch" --action build >"$work_root/detached-submit.txt"
grep -Fq "Submitted build job" "$work_root/detached-submit.txt"
XDG_RUNTIME_DIR="$runtime" "$client" --plain --project-root "$fixture" \
  --environment "opam:$switch" >"$work_root/during-detached-job.txt"
grep -Fq "Jobs: 1" "$work_root/during-detached-job.txt"
grep -Eq '^Job .*: (Queued|Starting|Running) ' "$work_root/during-detached-job.txt"
test "$(metadata_field pid)" = "$first_pid"
for _attempt in $(seq 1 500); do
  XDG_RUNTIME_DIR="$runtime" "$client" --plain --project-root "$fixture" \
    --environment "opam:$switch" >"$work_root/after-detached-job.txt"
  if grep -Eq '^Job .*: Complete ' "$work_root/after-detached-job.txt"; then
    break
  fi
  sleep 0.1
done
grep -Fq "Jobs: 1" "$work_root/after-detached-job.txt"
grep -Eq '^Job .*: Complete ' "$work_root/after-detached-job.txt"

printf '.\n' >>"$fixture/lifecycle-trigger"
(
  cd "$outside"
  XDG_RUNTIME_DIR="$runtime" "$client" --plain --project-root "$fixture" \
    --environment "opam:$switch" --action build --wait >build.txt
) &
build_client=$!
for _attempt in $(seq 1 500); do
  if grep -Fq "[stdout] fixture build: started" "$outside/build.txt" 2>/dev/null; then
    break
  fi
  kill -0 "$build_client"
  sleep 0.02
done
grep -Fq "[stdout] fixture build: started" "$outside/build.txt"
kill -0 "$build_client"
if grep -Fq "fixture build: complete" "$outside/build.txt"; then
  echo "error: build output was not observed before completion" >&2
  exit 1
fi
wait "$build_client"
grep -Fq "Submitted build job" "$outside/build.txt"
grep -Fq "[stdout] fixture build: started" "$outside/build.txt"
grep -Fq "[stdout] fixture build: complete" "$outside/build.txt"
grep -Eq '^Job .*: Complete$' "$outside/build.txt"

printf '.\n' >>"$fixture/lifecycle-trigger"
XDG_RUNTIME_DIR="$runtime" "$client" --plain --project-root "$fixture" \
  --environment "opam:$switch" >"$work_root/reattach.txt"
test "$(metadata_field pid)" = "$first_pid"
kill -0 "$first_pid"
grep -Fq "Jobs: 2" "$work_root/reattach.txt"

XDG_RUNTIME_DIR="$runtime" "$client" --plain >"$work_root/second-observer.txt" &
observer_one=$!
XDG_RUNTIME_DIR="$runtime" "$client" --plain >"$work_root/third-observer.txt" &
observer_two=$!
wait "$observer_one"
wait "$observer_two"
grep -Fq "Jobs: 2" "$work_root/second-observer.txt"
grep -Fq "Jobs: 2" "$work_root/third-observer.txt"
test "$(metadata_field pid)" = "$first_pid"

XDG_RUNTIME_DIR="$runtime" "$client" --plain --project-root "$fixture" \
  --environment "opam:$switch" --action test --wait >"$work_root/test.txt"
grep -Fq "Submitted test job" "$work_root/test.txt"
grep -Fq "[stdout] fixture test: started" "$work_root/test.txt"
grep -Fq "[stdout] fixture test: complete" "$work_root/test.txt"
grep -Eq '^Job .*: Complete$' "$work_root/test.txt"

XDG_RUNTIME_DIR="$runtime" "$client" --plain --project-root "$fixture" \
  --environment "opam:$switch" >"$work_root/jobs.txt"
grep -Fq "Jobs: 3" "$work_root/jobs.txt"
test "$(metadata_field pid)" = "$first_pid"

# A valid manifest without a driver uses its declared aliases and remains manifest-only.
XDG_RUNTIME_DIR="$runtime" "$client" --plain --project-root "$manifest_fixture" \
  --environment "opam:$switch" >"$work_root/manifest-only.txt"
grep -Fq "Project: manifest-only-fixture" "$work_root/manifest-only.txt"
grep -Fq "Integration: Manifest" "$work_root/manifest-only.txt"
grep -Fq "driver=absent" "$work_root/manifest-only.txt"
XDG_RUNTIME_DIR="$runtime" "$client" --plain --project-root "$manifest_fixture" \
  --environment "opam:$switch" --action test --wait >"$work_root/manifest-test.txt"
grep -Eq '^Job .*: Complete$' "$work_root/manifest-test.txt"

# Compatible driver discovery is daemon-owned, cached on repeat-open, and explicitly refreshable.
XDG_RUNTIME_DIR="$runtime" "$client" --plain --project-root "$integrated_fixture" \
  --environment "opam:$switch" >"$work_root/integrated-open.txt"
for _attempt in $(seq 1 500); do
  XDG_RUNTIME_DIR="$runtime" "$client" --plain --project-root "$integrated_fixture" \
    --environment "opam:$switch" >"$work_root/integrated-ready.txt"
  if grep -Fq "driver=available v1" "$work_root/integrated-ready.txt"; then
    break
  fi
  sleep 0.05
done
grep -Fq "driver=available v1" "$work_root/integrated-ready.txt"
grep -Fq "Four-bit counter (top counter_top)" "$work_root/integrated-ready.txt"
grep -Fq "4-bit counter" "$work_root/integrated-ready.txt"
grep -Fq "8-bit counter" "$work_root/integrated-ready.txt"
grep -Fq "Jobs: 1" "$work_root/integrated-ready.txt"
XDG_RUNTIME_DIR="$runtime" "$client" --plain --project-root "$integrated_fixture" \
  --environment "opam:$switch" --refresh-integration --wait \
  >"$work_root/integrated-refresh.txt"
grep -Fq "Submitted integration refresh job" "$work_root/integrated-refresh.txt"
grep -Eq '^Job .*: Complete$' "$work_root/integrated-refresh.txt"
grep -Fq "driver=available v1" "$work_root/integrated-refresh.txt"
grep -Fq "Four-bit counter (top counter_top)" "$work_root/integrated-refresh.txt"
grep -Fq "4-bit counter" "$work_root/integrated-refresh.txt"
grep -Fq "8-bit counter" "$work_root/integrated-refresh.txt"

# Generation waits through incremental events, registers isolated artifacts, and retrieves by ID.
XDG_RUNTIME_DIR="$runtime" "$client" --plain --project-root "$integrated_fixture" \
  --environment "opam:$switch" --action generate-rtl \
  --target "Four-bit counter" --configuration "4-bit counter" --wait \
  >"$work_root/generate-four.txt"
grep -Eq '^Job .*: Complete$' "$work_root/generate-four.txt"
four_artifact="$(grep -E '^Artifact .*: counter-4\.v ' "$work_root/generate-four.txt" | \
  cut -d' ' -f2 | tr -d ':')"
four_hierarchy="$(grep -E '^Artifact .*: counter-4 hierarchy ' \
  "$work_root/generate-four.txt" | cut -d' ' -f2 | tr -d ':')"
test -n "$four_artifact"
test -n "$four_hierarchy"
XDG_RUNTIME_DIR="$runtime" "$client" --plain --project-root "$integrated_fixture" \
  --environment "opam:$switch" --artifact "$four_artifact" \
  >"$work_root/four-rtl.txt"
grep -Fq 'module counter' "$work_root/four-rtl.txt"
grep -Eq 'output[[:space:]]+\[3:0\][[:space:]]+count_o' "$work_root/four-rtl.txt"
XDG_RUNTIME_DIR="$runtime" "$client" --plain --hierarchy "$four_hierarchy" \
  >"$work_root/four-hierarchy.txt"
grep -Fq '<root> : counter_top [/]' "$work_root/four-hierarchy.txt"
grep -Fq 'u_counter_0 : counter [/11:u_counter_0]' "$work_root/four-hierarchy.txt"
grep -Fq 'u_counter_1 : counter [/11:u_counter_1]' "$work_root/four-hierarchy.txt"

XDG_RUNTIME_DIR="$runtime" "$client" --plain --project-root "$integrated_fixture" \
  --environment "opam:$switch" --action generate-rtl \
  --target "Four-bit counter" --configuration "8-bit counter" --wait \
  >"$work_root/generate-eight.txt"
grep -Eq '^Job .*: Complete$' "$work_root/generate-eight.txt"
eight_artifact="$(grep -E '^Artifact .*: counter-8\.v ' "$work_root/generate-eight.txt" | \
  cut -d' ' -f2 | tr -d ':')"
eight_hierarchy="$(grep -E '^Artifact .*: counter-8 hierarchy ' \
  "$work_root/generate-eight.txt" | cut -d' ' -f2 | tr -d ':')"
test -n "$eight_artifact"
test -n "$eight_hierarchy"
test "$eight_artifact" != "$four_artifact"
test "$eight_hierarchy" != "$four_hierarchy"
XDG_RUNTIME_DIR="$runtime" "$client" --plain --project-root "$integrated_fixture" \
  --environment "opam:$switch" --artifact "$eight_artifact" \
  >"$work_root/eight-rtl.txt"
grep -Eq 'output[[:space:]]+\[7:0\][[:space:]]+count_o' "$work_root/eight-rtl.txt"
XDG_RUNTIME_DIR="$runtime" "$client" --plain --hierarchy "$eight_hierarchy" \
  >"$work_root/eight-hierarchy.txt"
grep -Fq 'u_counter_0 : counter [/11:u_counter_0]' "$work_root/eight-hierarchy.txt"
grep -Fq 'u_counter_1 : counter [/11:u_counter_1]' "$work_root/eight-hierarchy.txt"

XDG_RUNTIME_DIR="$runtime" "$client" --plain --project-root "$integrated_fixture" \
  --environment "opam:$switch" >"$work_root/integrated-reconnect.txt"
grep -Fq "driver=available v1" "$work_root/integrated-reconnect.txt"
grep -Fq "Jobs: 4" "$work_root/integrated-reconnect.txt"
grep -Fq "$four_artifact" "$work_root/integrated-reconnect.txt"
grep -Fq "$eight_artifact" "$work_root/integrated-reconnect.txt"
grep -Fq "$four_hierarchy" "$work_root/integrated-reconnect.txt"
grep -Fq "$eight_hierarchy" "$work_root/integrated-reconnect.txt"
XDG_RUNTIME_DIR="$runtime" "$client" --plain --hierarchy "$four_hierarchy" \
  >"$work_root/reconnected-hierarchy.txt"
grep -Fq 'u_counter_1 : counter [/11:u_counter_1]' "$work_root/reconnected-hierarchy.txt"
XDG_RUNTIME_DIR="$runtime" \
  "$repo_root/scripts/test-terminal-resize.py" "$client" \
  --project-root "$integrated_fixture" --environment "opam:$switch" \
  --expect-hierarchy --expect-project-name hardcaml-counter-fixture

# Missing and invalid optional integration remain actionable without disabling generic jobs.
XDG_RUNTIME_DIR="$runtime" "$client" --plain --project-root "$missing_driver_fixture" \
  --environment "opam:$switch" >"$work_root/missing-driver-open.txt"
for _attempt in $(seq 1 500); do
  XDG_RUNTIME_DIR="$runtime" "$client" --plain --project-root "$missing_driver_fixture" \
    --environment "opam:$switch" >"$work_root/missing-driver-ready.txt"
  if grep -Fq "driver=unusable: driver exited with code" \
    "$work_root/missing-driver-ready.txt"; then
    break
  fi
  sleep 0.05
done
grep -Fq "driver=unusable: driver exited with code" "$work_root/missing-driver-ready.txt"
XDG_RUNTIME_DIR="$runtime" "$client" --plain --project-root "$missing_driver_fixture" \
  --environment "opam:$switch" --action build --wait \
  >"$work_root/missing-driver-build.txt"
grep -Eq '^Job .*: Complete$' "$work_root/missing-driver-build.txt"
XDG_RUNTIME_DIR="$runtime" "$client" --plain --project-root "$invalid_manifest_fixture" \
  --environment "opam:$switch" >"$work_root/invalid-manifest-open.txt"
grep -Fq "Integration: Generic_dune" "$work_root/invalid-manifest-open.txt"
grep -Fq "unsupported hardcaml-workbench manifest version 99" \
  "$work_root/invalid-manifest-open.txt"
XDG_RUNTIME_DIR="$runtime" "$client" --plain --project-root "$invalid_manifest_fixture" \
  --environment "opam:$switch" --action test --wait \
  >"$work_root/invalid-manifest-test.txt"
grep -Eq '^Job .*: Complete$' "$work_root/invalid-manifest-test.txt"

if XDG_RUNTIME_DIR="$runtime" "$client" --plain --project-root "$outside" \
  --environment "opam:$switch" >"$work_root/invalid-root.txt" 2>&1; then
  echo "error: invalid project root unexpectedly succeeded" >&2
  exit 1
fi
grep -Fq "project root must directly contain dune-project" "$work_root/invalid-root.txt"

if XDG_RUNTIME_DIR="$runtime" "$client" --plain --project-root "$fixture" \
  --environment invalid >"$work_root/invalid-environment.txt" 2>&1; then
  echo "error: invalid environment unexpectedly succeeded" >&2
  exit 1
fi
grep -Fq -- "--environment must be inherited or opam:SWITCH" \
  "$work_root/invalid-environment.txt"

kill -TERM "$first_pid"
wait_dead "$first_pid"
XDG_RUNTIME_DIR="$runtime" "$client" --plain >"$work_root/stale.txt"
replacement_pid="$(metadata_field pid)"
test "$replacement_pid" != "$first_pid"
kill -0 "$replacement_pid"
grep -Fq "Jobs: 0" "$work_root/stale.txt"

kill -TERM "$replacement_pid"
wait_dead "$replacement_pid"
rm -f "$metadata_path"
XDG_RUNTIME_DIR="$runtime" "$client" --plain >"$work_root/concurrent-1.txt" &
client_one=$!
XDG_RUNTIME_DIR="$runtime" "$client" --plain >"$work_root/concurrent-2.txt" &
client_two=$!
wait "$client_one"
wait "$client_two"
concurrent_pid="$(metadata_field pid)"
kill -0 "$concurrent_pid"
grep -Fq "Silver" "$work_root/concurrent-1.txt"
grep -Fq "Silver" "$work_root/concurrent-2.txt"

if XDG_RUNTIME_DIR="$explicit_runtime" "$client" --plain --connect http://127.0.0.1:1 \
  >"$work_root/explicit.txt" 2>&1; then
  echo "error: unreachable explicit endpoint unexpectedly succeeded" >&2
  exit 1
fi
test ! -e "$explicit_runtime/hardcaml-workbench/daemon.sexp"

kill -TERM "$concurrent_pid"
wait_dead "$concurrent_pid"

printf 'Installed client: %s\n' "$client"
printf 'Installed daemon: %s\n' "$prefix/bin/hardcaml-workbench-daemon"
printf 'Installed launch directory: %s\n' "$outside"
printf 'External fixture: %s\n' "$fixture"
printf 'Integrated external fixture: %s\n' "$integrated_fixture"
printf 'Native lifecycle and installed workflow checks: passed\n'
