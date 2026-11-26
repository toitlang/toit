#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# How much of a function (by default the core's run loop) the PC samples of
# a perfbench log touch: samples per BLOCK-byte block, and how many bytes
# hold 90/95/99/100 % of the function's samples (the size of a hot part
# for IRAM if the function were split). Also writes the per-block counts to
# logs/<LOG>.blocks.txt.
# Usage: loop-coverage.sh LOG-NAME BIN-NAME [BENCH-REGEX] [FUNCTION-REGEX] [BLOCK]
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/rpc-task-speed
T=$HOME/.espressif/tools
LOG=$A/logs/$1.txt
ELF=$A/bins/$2/toit.elf
RE=${3:-.}
FRE=${4:-step::run_loop$}
BLOCK=${5:-64}
case $2 in
  esp32c6*) NM=$T/riscv32-esp-elf/esp-14.2.0_20241119/riscv32-esp-elf/bin/riscv32-esp-elf-nm ;;
  esp32s3*) NM=$T/xtensa-esp-elf/esp-14.2.0_20241119/xtensa-esp-elf/bin/xtensa-esp32s3-elf-nm ;;
  *) NM=$T/xtensa-esp-elf/esp-14.2.0_20241119/xtensa-esp-elf/bin/xtensa-esp32-elf-nm ;;
esac
read -r start size < <("$NM" -S -C "$ELF" | awk -v re="$FRE" '{n = $4; for (i = 5; i <= NF; i++) n = n " " $i} n ~ re {print $1, $2; exit}')
[ -n "${start:-}" ] || { echo "no function matching $FRE"; exit 1; }
tr -d '\r' < "$LOG" | awk -v re="$RE" '
  /\[hw-perf\] begin / { on = ($3 ~ re); next }
  /\[hw-perf\] end/ { on = 0; next }
  on && /^\[hw-pc\] [01] / { for (i = 3; i <= NF; i++) { split($i, a, ":"); print a[1], a[2] } }
' | awk -v s="$start" -v z="$size" -v blk="$BLOCK" -v out="$A/logs/$1.blocks.txt" '
  BEGIN { s = strtonum("0x" s); z = strtonum("0x" z) }
  { pc = strtonum("0x" $1); if (pc < s || pc >= s + z) next; b = int((pc - s) / blk); c[b] += $2; total += $2 }
  END {
    nb = int((z + blk - 1) / blk); n = 0
    for (b = 0; b < nb; b++) { v[++n] = c[b] + 0; printf "%d %d\n", b * blk, c[b] + 0 > out }
    # Sort the block counts, largest first.
    for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++) if (v[j] > v[i]) { t = v[i]; v[i] = v[j]; v[j] = t }
    printf "function size %d bytes, %d blocks of %d, samples %d\n", z, n, blk, total
    acc = 0; k = 1
    split("0.90 0.95 0.99 1.00", q, " ")
    for (i = 1; i <= n; i++) {
      acc += v[i]
      while (k <= 4 && acc >= q[k] * total - 1e-9) { printf "  %3d%% of samples in %6d bytes (%d blocks)\n", q[k] * 100, i * blk, i; k++ }
    }
    zero = 0; for (i = 1; i <= n; i++) if (v[i] == 0) zero++
    printf "  blocks without samples: %d (%d bytes)\n", zero, zero * blk
  }'
