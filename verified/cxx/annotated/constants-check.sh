#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
#
# Checks the model's constant table against the C++ headers: compiles every
# generated *.gen.constants.cc (one static_assert per constant use of a
# rendering, written by cxx_render.toit) for the host (64-bit) and for
# i686 (32-bit), in parallel. Private members are reached with
# -fno-access-control.
#
# Usage: constants-check.sh [FILE...]   (default: all of them)

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
cd "$ANNOTATED_DIR"
[ $# -eq 0 ] && set -- $(ls */*.gen.constants.cc */*.abi.cc)
CLANG="${CLANGXX:-clang++}"
vm_cxx_flags "$REPO_ROOT"
mkdir -p "$ACXX_WORK/logs"
pids=()
logs=()
for f in "$@"; do
  for target in x86_64-linux-gnu i686-linux-gnu; do
    log="$ACXX_WORK/logs/constants-$(basename "$f")-$target.log"
    "$CLANG" --target="$target" -fsyntax-only -fno-access-control "${VM_CXX_FLAGS[@]}" "$f" > "$log" 2>&1 &
    pids+=($!)
    logs+=("$f|$target|$log")
  done
done
status=0
for i in "${!pids[@]}"; do
  IFS='|' read -r f target log <<< "${logs[$i]}"
  if wait "${pids[$i]}"; then
    printf 'ok    constants %-40s %s (%d checks)\n' "$f" "$target" "$(grep -c static_assert "$f")"
  else
    printf 'FAIL  constants %-40s %s:\n' "$f" "$target"
    grep -E "error|evaluates to" "$log" | head -10
    status=1
  fi
done
exit $status
