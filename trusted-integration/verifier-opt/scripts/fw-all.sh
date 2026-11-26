#!/usr/bin/env bash
# Builds the ESP32 firmware for each given level in parallel (fw-esp32.sh).
# Usage: fw-all.sh <worktree> <level>...
set -uo pipefail
WT=$1
shift
V=/home/flo/work/opentoit-sandbox-artifacts/trusted-integration/verifier-opt
pids=()
for l in "$@"; do
  bash "$V/scripts/fw-esp32.sh" "$WT" "$l" > "$V/fw-$l.log" 2>&1 &
  pids+=($!)
done
for p in "${pids[@]}"; do wait "$p"; done
for l in "$@"; do echo "== $l"; tail -9 "$V/fw-$l.log"; done
