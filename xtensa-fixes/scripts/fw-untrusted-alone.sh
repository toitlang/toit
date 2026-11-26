#!/usr/bin/env bash
# Runs each given untrusted test image alone (fresh boot, its own QEMU
# instance, in parallel) on a firmware build. Usage:
#   fw-untrusted-alone.sh <firmware-build-dir> <tag> <image>...
set -uo pipefail
B=$1
TAG=$2
shift 2
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a13f01ee86eed5211
S=/home/flo/work/opentoit-sandbox-artifacts/xtensa-fixes/scripts/fw-untrusted-run.sh
pids=()
for img in "$@"; do
  n=$(basename "$img" .image)
  bash "$S" "$WT" "$B" "$TAG-$n" 2300 "$img" > /dev/null 2>&1 &
  pids+=($!)
done
for p in "${pids[@]}"; do wait "$p"; done
for img in "$@"; do
  n=$(basename "$img" .image)
  grep -h -E 'XTENSA-CORE .* (exit|install-failed)|verifier:' \
    "/home/flo/work/opentoit-sandbox-artifacts/xtensa-fixes/fw-qemu/run-$TAG-$n/serial.txt"
done
