#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public
# License as published by the Free Software Foundation; version
# 2.1 only.
#
# This library is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# Lesser General Public License for more details.
#
# The license can be found in the file `LICENSE` in the top level
# directory of this repository.

# The whole gate of this checkout, builds included, as a dependency graph
# run in parallel:
#
#   part                                       needs
#   host-sdk, asan-build, verus, verus32,      -
#     ieee, no-python, no-python-self-test,
#     nopanic, ec618-nopanic, ec618-codegen
#   host-tests-build, host32-build             host-sdk
#   cxx, spec-tests, vmverify, contracts,      host-sdk
#     layout-table, audit-test, redteam4-A-cert
#   audit                                      host-sdk, verus
#   layout-check, sandbox-ctests               host-tests-build
#   redteam3-heap, redteam3-asm,               host-sdk, asan-build
#     redteam4-{A,B,D,E,F}
#   redteam4-C                                 host-sdk, host32-build
#   ctest-host                                 host-tests-build, layout-check,
#                                              sandbox-ctests
#
# (The table DEPS below is what runs.) The critical path is host-sdk, then
# cxx (the residual C++ matrix: tens of minutes, bounded by the machine-wide
# model-checker memory budget and its longest VeriFast proofs).
#
# The builds are those of the serial flow (`make sdk`; `make
# download-packages`; `ninja -C build/host`; `ninja -C build/host
# build_test_assets`; the ASan build's `build_tools`; `make TARGET=host32
# sdk`), the checks are the sections of `verified/check.sh --tests`, each
# run as `check.sh --only NAME` (check.sh stays the one place that says
# what is checked: a section it lists that has no place in the graph here
# stops the gate before anything runs), and `ctest` of the host build.
#
# Each part logs to LOGS/NAME.log. The summary lists every part with its
# result (passed, FAILED, skipped, not run: a part it depends on did not
# pass) and wall time; the exit status is 0 only when every part passed.
# An interrupted run (INT, TERM, HUP) stops every part: each runs in its
# own session, and every process of that session is signalled (run.sh's
# jobs release their model-checker memory on TERM).
#
# Usage: verified/gate.sh [--logs DIR] [--slow] [--allow-skip]
#   --logs DIR    where the logs go (default build/gate/<date-time>)
#   --slow        also the slow tier of the residual C++ matrix (hours)
#   --allow-skip  exit 0 although a check was skipped (a tool missing)
# Environment: GATE_CTEST_JOBS (12), GATE_CTEST_KNOWN_FAILURES (ctest
# names, space-separated, that may fail without failing the gate; default
# the multicast test the sandboxed host cannot run). To gate a commit in a
# separate worktree: tools/gate-commit.sh.

set -u -o pipefail

VERIFIED="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$VERIFIED/.." && pwd)"
SELF="$VERIFIED/gate.sh"
LOGS=""
SLOW=0
ALLOW_SKIP=0
RUN_PART=""

while [ $# -gt 0 ]; do
  case "$1" in
    --logs) shift; LOGS="$1" ;;
    --slow) SLOW=1 ;;
    --allow-skip) ALLOW_SKIP=1 ;;
    --run-part) shift; RUN_PART="$1" ;;
    -h|--help) sed -n '/^# The whole gate/,/^# separate worktree/p' "$SELF" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

[ -n "$LOGS" ] || LOGS="$REPO/build/gate/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOGS"
LOGS="$(cd "$LOGS" && pwd)"
cd "$REPO" || exit 2

# Worktrees: the environment tools/worktree-setup.sh wrote.
# shellcheck disable=SC1091
[ -f "$REPO/build/worktree-env.sh" ] && source "$REPO/build/worktree-env.sh"
# Scratch files of the checks (solver temporaries, check.sh's own log
# directory when none is given) stay in the checkout, not in /tmp.
export TMPDIR="$REPO/build/tmp"
mkdir -p "$TMPDIR"

HOST="$REPO/build/host"
CHECK_LOGS="$LOGS/check"
CTEST_JOBS="${GATE_CTEST_JOBS:-12}"
CTEST_KNOWN_FAILURES="${GATE_CTEST_KNOWN_FAILURES-tests/udp-reuse-port-test.toit}"

# --- The graph ------------------------------------------------------------------

# Parts that are not check.sh sections, and the dependencies of every part:
# NAME, the part needs NAME to have passed (else it does not run); ~NAME,
# it only runs after NAME, whatever NAME's result (a failure there must not
# hide this part's result).
BUILD_PARTS=(host-sdk host-tests-build asan-build host32-build)
declare -A DEPS=(
  [host-sdk]=""
  [host-tests-build]="host-sdk"
  [asan-build]=""
  [host32-build]="host-sdk"
  # After the sections that write into build/host (ninja, cmake): ctest
  # reads its test lists at start.
  [ctest-host]="host-tests-build ~layout-check ~sandbox-ctests"
  # check.sh sections.
  [verus]=""
  [verus32]=""
  # The audit reads the `verus --no-cheating` logs section verus writes
  # (also when a proof fails, as in a serial check.sh run).
  [audit]="~verus host-sdk"
  [contracts]="host-sdk"
  [layout-table]="host-sdk"
  [no-python]=""
  [ieee]=""
  [audit-test]="host-sdk"
  [no-python-self-test]=""
  [layout-check]="host-tests-build"
  [cxx]="host-sdk"
  [cxx-slow]="host-sdk"
  [spec-tests]="host-sdk"
  [vmverify]="host-sdk"
  [nopanic]=""
  [ec618-nopanic]=""
  [ec618-codegen]=""
  [sandbox-ctests]="host-tests-build"
  [redteam3-heap]="host-sdk asan-build"
  [redteam3-asm]="host-sdk asan-build"
  [redteam4-A]="host-sdk asan-build"
  [redteam4-A-cert]="host-sdk"
  [redteam4-B]="host-sdk asan-build"
  [redteam4-C]="host-sdk host32-build"
  [redteam4-D]="host-sdk asan-build"
  [redteam4-E]="host-sdk asan-build"
  [redteam4-F]="host-sdk asan-build"
)

# Writes into build/host take check.sh's lock of that directory (its
# layout check runs ninja there, its sandbox section cmake).
host_locked() {
  mkdir -p "$HOST"
  flock "$HOST/.check-build.lock" "$@"
}

part_host-sdk() {
  host_locked make sdk
}
part_host-tests-build() {
  host_locked make download-packages \
    && host_locked ninja -C "$HOST" \
    && host_locked ninja -C "$HOST" build_test_assets
}
part_asan-build() {
  local dir="$REPO/build/asan"
  if [ ! -f "$dir/build.ninja" ]; then
    cmake -S "$REPO" -B "$dir" -G Ninja -DCMAKE_BUILD_TYPE=asan \
      -DCMAKE_TOOLCHAIN_FILE="$REPO/toolchains/host.cmake" \
      "-DCMAKE_C_FLAGS=-fsanitize=address,undefined -fno-omit-frame-pointer -g" \
      "-DCMAKE_CXX_FLAGS=-fsanitize=address,undefined -fno-omit-frame-pointer -g" \
      "-DCMAKE_EXE_LINKER_FLAGS=-fsanitize=address,undefined" || return 1
  fi
  ASAN_OPTIONS=detect_leaks=0 ninja -C "$dir" build_tools
}
# `make TARGET=host32 sdk` without its `host-tools` step (ninja build_tools
# in build/host: done by host-sdk, and it would run a second ninja there
# beside host-tests-build): configure, `tools-no-cmake`, `version-file`.
part_host32-build() {
  if [ ! -f "$REPO/build/host32/CMakeCache.txt" ]; then
    make TARGET=host32 build/host32/CMakeCache.txt || return 1
  fi
  ninja -C "$REPO/build/host32" build_tools && ninja -C "$REPO/build/host32" build_version_file
}
part_ctest-host() {
  local out="$LOGS/ctest-host.out" rc
  (cd "$HOST" && ctest -j "$CTEST_JOBS" --timeout 600) 2>&1 | tee "$out"
  rc=${PIPESTATUS[0]}
  [ "$rc" -eq 0 ] && return 0
  # Every failure must be a known environmental one; "Not Run" never is.
  local bad=0 line name kind
  while read -r line; do
    # "419 - tests/udp-reuse-port-test.toit (Failed)"
    name=$(sed -nE 's/^[0-9]+ - (.*) \([^()]*\)$/\1/p' <<< "$line")
    kind=$(sed -nE 's/^[0-9]+ - .* \(([^()]*)\)$/\1/p' <<< "$line")
    if [ -n "$name" ] && [ "$kind" = Failed ] && [[ " $CTEST_KNOWN_FAILURES " == *" $name "* ]]; then
      echo "known environmental failure: $name"
    else
      echo "gate: not accepted: $line"
      bad=1
    fi
  done < <(sed -n '/^The following tests FAILED:/,/^Errors while running/p' "$out" | grep -E '^[[:space:]]+[0-9]+ - ')
  if ! grep -q '^The following tests FAILED:' "$out"; then
    echo "gate: ctest exited with $rc without a list of failed tests"
    bad=1
  fi
  return $bad
}
part_check() {
  "$VERIFIED/check.sh" --only "$1" --logs "$CHECK_LOGS"
}

# Runs one part (in its own session, started by the scheduler below).
if [ -n "$RUN_PART" ]; then
  if declare -F "part_$RUN_PART" > /dev/null; then
    "part_$RUN_PART"
  else
    part_check "$RUN_PART"
  fi
  exit $?
fi

# The parts of this run: the builds, check.sh's sections, the host ctest.
CHECK_FLAGS=(--tests)
[ "$SLOW" = 1 ] && CHECK_FLAGS=(--slow)
mapfile -t SECTIONS < <("$VERIFIED/check.sh" --list "${CHECK_FLAGS[@]}")
if [ ${#SECTIONS[@]} -eq 0 ]; then
  echo "gate: verified/check.sh --list gave no sections" >&2
  exit 2
fi
PARTS=("${BUILD_PARTS[@]}" "${SECTIONS[@]}" ctest-host)
missing=()
for p in "${PARTS[@]}"; do
  [ -n "${DEPS[$p]+x}" ] || missing+=("$p")
done
if [ ${#missing[@]} -ne 0 ]; then
  echo "gate: check.sh sections without a place in the graph of verified/gate.sh: ${missing[*]}" >&2
  exit 2
fi
for p in "${PARTS[@]}"; do
  for d in ${DEPS[$p]}; do
    printf '%s\n' "${PARTS[@]}" | grep -qxF "${d#\~}" || { echo "gate: $p depends on ${d#\~}, which is not a part" >&2; exit 2; }
  done
done

# --- The scheduler ----------------------------------------------------------------

declare -A STATE=() PID=() START=() SECS=()
for p in "${PARTS[@]}"; do STATE[$p]=pending; done
RUN_START=$(date +%s)
ts() { date +%T; }

# Every process of the part's session.
signal_part() {
  local sig="$1" sid="$2"
  pkill "-$sig" -s "$sid" 2> /dev/null
}
stop_all() {
  trap - INT TERM HUP
  echo "$(ts) gate: interrupted, stopping the running parts" >&2
  local p n=0
  for p in "${PARTS[@]}"; do
    [ "${STATE[$p]}" = running ] && signal_part TERM "${PID[$p]}"
  done
  # Grace period for the jobs' own cleanup (memory reservations), then KILL.
  while (( n < 30 )); do
    local alive=0
    for p in "${PARTS[@]}"; do
      [ "${STATE[$p]}" = running ] && pgrep -s "${PID[$p]}" > /dev/null && alive=1
    done
    (( alive )) || break
    sleep 1
    n=$((n + 1))
  done
  for p in "${PARTS[@]}"; do
    [ "${STATE[$p]}" = running ] && signal_part KILL "${PID[$p]}"
  done
  wait 2> /dev/null
  for p in "${PARTS[@]}"; do
    if [ "${STATE[$p]}" = running ]; then
      STATE[$p]=interrupted
      SECS[$p]=$(($(date +%s) - START[$p]))
    fi
  done
  INTERRUPTED=1
}
INTERRUPTED=0
trap stop_all INT TERM HUP

start_part() {
  local p="$1"
  STATE[$p]=running
  START[$p]=$(date +%s)
  rm -f "$LOGS/$p.status"
  # setsid: the part is the leader of a new session (a background child of
  # this non-interactive shell is no group leader, so setsid does not fork:
  # $! is the session id). Its wrapper also stops the session when this
  # driver is gone without stopping it (killed with KILL): no part
  # outlives the gate. (It ignores TERM itself only after starting the
  # part, which keeps the default.)
  setsid bash -c '
    "$0" --run-part "$1" --logs "$2" &
    child=$!
    trap "" TERM
    while kill -0 "$child" 2> /dev/null; do
      if ! kill -0 "$3" 2> /dev/null; then
        pkill -TERM -s $$; sleep 30; pkill -KILL -s $$; exit 1
      fi
      sleep 2
    done
    wait "$child"
    echo $? > "$2/$1.status"' \
    "$SELF" "$p" "$LOGS" "$$" > "$LOGS/$p.log" 2>&1 < /dev/null &
  PID[$p]=$!
  echo "$(ts) start  $p"
}

finish_part() {
  local p="$1" rc
  wait "${PID[$p]}" 2> /dev/null
  rc=$(cat "$LOGS/$p.status" 2> /dev/null || echo 255)
  SECS[$p]=$(($(date +%s) - START[$p]))
  case "$rc" in
    0) STATE[$p]=passed ;;
    3) STATE[$p]=skipped ;;   # check.sh --only: nothing failed, something skipped
    *) STATE[$p]=FAILED ;;
  esac
  printf '%s %-6s %s (%d s)\n' "$(ts)" done "$p: ${STATE[$p]}" "${SECS[$p]}"
}

echo "gate: $(git -C "$REPO" rev-parse --short HEAD 2> /dev/null) in $REPO; logs in $LOGS"
echo "gate: load $(cut -d' ' -f1-3 /proc/loadavg) on $(nproc) cores at start"
while (( ! INTERRUPTED )); do
  progress=0
  running=0
  for p in "${PARTS[@]}"; do
    case "${STATE[$p]}" in
      running)
        if [ -f "$LOGS/$p.status" ] || ! kill -0 "${PID[$p]}" 2> /dev/null; then
          finish_part "$p"
          progress=1
        else
          running=$((running + 1))
        fi ;;
      pending)
        ready=1
        for d in ${DEPS[$p]}; do
          if [ "${d:0:1}" = "~" ]; then
            # Order only.
            case "${STATE[${d#\~}]}" in pending|running) ready=0 ;; esac
            continue
          fi
          case "${STATE[$d]}" in
            passed) ;;
            pending|running) ready=0 ;;
            *) ready=0; STATE[$p]="not run"; SECS[$p]=0
               echo "$(ts) skip   $p: not run ($d ${STATE[$d]})"; progress=1; break ;;
          esac
        done
        if [ "${STATE[$p]}" = pending ] && (( ready )); then
          start_part "$p"
          running=$((running + 1))
          progress=1
        fi ;;
    esac
  done
  (( running == 0 && ! progress )) && break
  (( progress )) || sleep 2
done

# --- Summary ----------------------------------------------------------------------

total=$(($(date +%s) - RUN_START))
echo
echo "=== gate summary ($(git -C "$REPO" rev-parse --short HEAD 2> /dev/null), $((total / 60)) min $((total % 60)) s wall)"
echo "logs in $LOGS"
bad=0
for p in "${PARTS[@]}"; do
  s="${STATE[$p]}"
  printf '  %-20s %-12s %6s  %s\n' "$p" "$s" "${SECS[$p]:-0} s" "$p.log"
  case "$s" in
    passed) ;;
    skipped) (( ALLOW_SKIP )) || bad=1 ;;
    *) bad=1 ;;
  esac
done
{
  for p in "${PARTS[@]}"; do printf '%s\t%s\t%s\n' "$p" "${STATE[$p]}" "${SECS[$p]:-0}"; done
} > "$LOGS/summary.tsv"
echo "gate: load $(cut -d' ' -f1-3 /proc/loadavg) at the end"
if (( bad )); then
  echo "gate: FAILED (a part failed, was skipped or did not run)"
  exit 1
fi
echo "gate: passed"
