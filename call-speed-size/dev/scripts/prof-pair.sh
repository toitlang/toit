#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Profiles a benchmark (qemu/progs/prof-BENCH.toit) on the pre-compact
# firmware (bins/esp32-f2-pre, device/size SDK) and on CONFIG, then
# compares per handler. Usage: prof-pair.sh BENCH CONFIG TAG
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/call-speed-size/dev
B=$1
C=$2
TAG=$3
cd "$A" || exit 1
if [ ! -f "prof/$B-pre.tb" ]; then
  WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-aa569f94a56435af9 bash scripts/qprof.sh f2-pre "qemu/progs/prof-$B.toit" "prof/$B-pre" 1500 > /dev/null 2>&1
fi
bash scripts/qprof.sh "$C" "qemu/progs/prof-$B.toit" "prof/$B-$TAG" 1500 > /dev/null 2>&1
grep TIME "prof/$B-pre.serial" "prof/$B-$TAG.serial"
bash scripts/cmph.sh "$B-pre:f2-pre" "$B-$TAG:$C" > "prof/$B-$TAG.cmp"
head -30 "prof/$B-$TAG.cmp"
