#!/usr/bin/env bash
# device_size.sh of the worktree for the classic ESP32 at the given
# opt-levels (logs/devsize-<opt><suffix>.log, output in devsize/).
# Usage: devsize.sh SUFFIX OPT... (env passes through, e.g. RUSTFLAGS)
set -uo pipefail
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-aa569f94a56435af9
A=/home/flo/work/opentoit-sandbox-artifacts/device-size
SUFFIX=$1
shift
cd "$WT"
for o in "$@"; do
  DEVICE_SIZE_ARCH=xtensa DEVICE_SIZE_SUFFIX="$SUFFIX" bash verified/vmverify/tests/device_size.sh "$o" "$A/devsize" > "$A/logs/devsize-$o$SUFFIX.log" 2>&1
  echo "== opt $o$SUFFIX"
  tail -22 "$A/logs/devsize-$o$SUFFIX.log"
done
