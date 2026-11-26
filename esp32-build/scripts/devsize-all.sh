#!/usr/bin/env bash
# Device library sizes by component, with and without LTO, riscv32 and
# Xtensa (verified/vmverify/tests/device_size.sh). Usage: devsize-all.sh [OPT]
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a11f10728217c321a
A=/home/flo/work/opentoit-sandbox-artifacts/esp32-build/devsize
OPT=${1:-3}
mkdir -p "$A"
S=$WT/verified/vmverify/tests/device_size.sh
(DEVICE_SIZE_LTO=false DEVICE_SIZE_SUFFIX=-nolto bash "$S" "$OPT" "$A" > "$A/rv-$OPT-nolto.txt" 2>&1) &
(DEVICE_SIZE_SUFFIX=-lto bash "$S" "$OPT" "$A" > "$A/rv-$OPT-lto.txt" 2>&1) &
(DEVICE_SIZE_ARCH=xtensa DEVICE_SIZE_LTO=false DEVICE_SIZE_SUFFIX=-nolto bash "$S" "$OPT" "$A" > "$A/xt-$OPT-nolto.txt" 2>&1) &
(DEVICE_SIZE_ARCH=xtensa DEVICE_SIZE_SUFFIX=-lto bash "$S" "$OPT" "$A" > "$A/xt-$OPT-lto.txt" 2>&1) &
wait
for f in rv-$OPT-nolto rv-$OPT-lto xt-$OPT-nolto xt-$OPT-lto; do echo "== $f"; cat "$A/$f.txt"; done
