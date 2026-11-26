#!/usr/bin/env bash
# device_size.sh (core at 3) for riscv32 and xtensa on each level's copy of
# verified/ (make-copies.sh), in parallel.
# Usage: devsize.sh <worktree> <level>...
set -uo pipefail
WT=$1
shift
A=/home/flo/work/opentoit-sandbox-artifacts/trusted-integration/verifier-opt
export TOIT="$WT/build/host/sdk/bin/toit"
pids=()
for l in "$@"; do
  S="$WT/build/vopt/$l/verified/vmverify/tests/device_size.sh"
  mkdir -p "$A/devsize/$l"
  bash "$S" 3 "$A/devsize/$l" > "$A/devsize/$l/riscv.log" 2>&1 &
  pids+=($!)
  DEVICE_SIZE_ARCH=xtensa bash "$S" 3 "$A/devsize/$l" > "$A/devsize/$l/xtensa.log" 2>&1 &
  pids+=($!)
done
for p in "${pids[@]}"; do wait "$p"; done
for l in "$@"; do
  for a in riscv xtensa; do
    echo "=== $l $a"
    grep -E "verifier: checker|verifier: heap check|spec: other|glue \(vmverify\)|Rust library total" "$A/devsize/$l/$a.log"
  done
done
