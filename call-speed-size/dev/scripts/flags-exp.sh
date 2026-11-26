#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# LLVM flag experiments for the classic ESP32: for each flag set, appends a
# [target.xtensa-esp32-none-elf] rustflags section to the worktree's
# verified/vmverify/.cargo/config.toml (restored afterwards), builds the f2
# firmware, runs the benchmark-only QEMU suite and records the TIME lines.
# Usage: flags-exp.sh TAG "FLAGS-1" "FLAGS-2" ...   (FLAGS: space separated
#   llvm-args, e.g. "-tail-dup-size=12 -split-spill-mode=speed")
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/call-speed-size/dev
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a61139585de4882bc
CFG=$WT/verified/vmverify/.cargo/config.toml
TAG=$1
shift
cp "$CFG" "$A/logs/config.toml.orig"
trap 'cp "$A/logs/config.toml.orig" "$CFG"' EXIT
OUT=$A/logs/flags-$TAG.txt
: > "$OUT"
i=0
for flags in "$@"; do
  i=$((i + 1))
  cp "$A/logs/config.toml.orig" "$CFG"
  {
    echo ""
    echo "[target.xtensa-esp32-none-elf]"
    printf 'rustflags = ['
    sep=""
    for f in $flags; do printf '%s"-C", "llvm-args=%s"' "$sep" "$f"; sep=", "; done
    echo ']'
  } >> "$CFG"
  if bash "$A/scripts/fw-all.sh" esp32 "flags$i" f2 > /dev/null 2>&1; then
    size=$(stat -c %s "$A/bins/esp32-f2/toit.bin")
    bash "$A/scripts/bench-qemu.sh" f2 "flags-$TAG-$i" > /dev/null 2>&1
    res=$(grep "^TIME" "$A/qemu/bench-f2-flags-$TAG-$i/result.txt" | awk '{printf "%s=%s ", $2, $3}')
    echo "[$i] $flags | toit.bin $size | $res" | tee -a "$OUT"
  else
    echo "[$i] $flags | BUILD FAILED" | tee -a "$OUT"
  fi
done
