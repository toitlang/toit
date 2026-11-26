#!/usr/bin/env bash
# fw-qemu-icount.sh (shift=0) for each level's firmware, in parallel.
# Usage: icount-all.sh <worktree> <level>...
set -uo pipefail
WT=$1
shift
V=/home/flo/work/opentoit-sandbox-artifacts/trusted-integration/verifier-opt
pids=()
for l in "$@"; do
  bash "$V/scripts/fw-qemu-icount.sh" "$WT/build/esp32-vopt-$l" "ic0$l" 0 fold format map deque list \
    > "$V/fw-qemu/ic0$l.summary" 2>&1 &
  pids+=($!)
done
for p in "${pids[@]}"; do wait "$p"; done
for l in "$@"; do echo "== $l"; grep -E "install-trace|install-failed" "$V/fw-qemu/ic0$l.summary"; done
