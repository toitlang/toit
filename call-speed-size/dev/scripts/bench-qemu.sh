#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Runs the benchmark-only suite (qemu/progs/bench-only.toit) on an ESP32
# firmware build under QEMU with -icount shift=0 (never touches hardware)
# and prints the TIME lines and the f2/f1 ratios against the format-1
# reference run (qemu/run-f1-ref, or the numbers of compact-methods).
# Usage: bench-qemu.sh CONFIG TAG   (bins/esp32-CONFIG/firmware.envelope)
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/call-speed-size/dev
WT=${WT:-/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a61139585de4882bc}
TOIT=$WT/build/host/sdk/bin/toit
C=$1
TAG=$2
format=2
[ "$C" = f1 ] && format=1
OUT=$A/qemu/bench-$C-$TAG
mkdir -p "$OUT"
D=$OUT/snap
mkdir -p "$D"
TOIT_BYTECODE_FORMAT=$format "$TOIT" compile --snapshot -o "$D/bench.snapshot" "$A/qemu/progs/bench-only.toit" || exit 1
cp "$A/bins/esp32-$C/firmware.envelope" "$D/fw.envelope"
"$TOIT" tool firmware -e "$D/fw.envelope" container install bench "$D/bench.snapshot" || exit 1
QEMU_EXTRA="-icount shift=0" bash "$A/scripts/qemu-run.sh" esp32 "$D/fw.envelope" "$OUT/run" 900 "SUITE done|Guru Meditation|abort\(\)|Potential dead"
grep -a -E "^(TIME|SUITE)" "$OUT/run/serial.txt" > "$OUT/result.txt"
# Reference f1 numbers (compact-methods dev/qemu/run-f1-cm, identical code).
declare -A F1=([richards]=178552 [deltablue]=10453 [pystone]=24326 [json]=26753 [map-set]=19259 [strings]=16806 [gc-stress]=88913)
if [ -f "$A/qemu/bench-f1-ref/result.txt" ]; then
  while read -r _ name us _; do F1[$name]=$us; done < <(grep "^TIME" "$A/qemu/bench-f1-ref/result.txt")
fi
while read -r _ name us _; do
  f1=${F1[$name]:-0}
  if [ "$f1" -gt 0 ]; then
    awk -v n="$name" -v u="$us" -v f="$f1" 'BEGIN { printf "%-10s %9d us  f2/f1 %.3f\n", n, u, u / f }'
  else
    printf "%-10s %9d us\n" "$name" "$us"
  fi
done < <(grep "^TIME" "$OUT/result.txt") | tee "$OUT/ratios.txt"
grep "^SUITE" "$OUT/result.txt"
