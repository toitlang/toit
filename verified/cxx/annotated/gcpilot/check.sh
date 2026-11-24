#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
#
# GC proof pilot, route A (verified/gcpilot/README.md): renders the pilot
# sidecars of this directory and verifies them with VeriFast, LP64 and
# ILP32. Not part of run.sh (the pilot's admits are not in the trusted
# lists).
#
# Usage: check.sh [SIDECAR...]   (default: every gcpilot/*.render)

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../env.sh"
cd "$ANNOTATED_DIR"
[ $# -eq 0 ] && set -- gcpilot/*.render
./render.sh "$@" || exit 1
status=0
for sidecar in "$@"; do
  gen="${sidecar%.render}.gen.c"
  for target in LP64 ILP32; do
    dir="$ANNOTATED_DIR"
    [ "$target" = ILP32 ] && dir="$GEN32"
    start=$(date +%s%N)
    out=$(cd "$dir" && "$VERIFAST" -c -target "$target" -fno-strict-aliasing -assume_left_to_right_evaluation "$gen" 2>&1)
    rc=$?
    end=$(date +%s%N)
    printf '%s %s: exit %d, %d ms: %s\n' "$gen" "$target" "$rc" $(((end - start) / 1000000)) "$(echo "$out" | tail -1)"
    [ $rc -ne 0 ] && { echo "$out" | tail -8; status=1; }
  done
done
exit $status
