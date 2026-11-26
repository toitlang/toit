#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Approximate code size of each opcode handler in step::run_loop of an
# ESP32 firmware: the distance from each jump-table target to the next
# target in address order (blocks LLVM moved elsewhere count for the
# handler laid out before them). Usage: handler-sizes.sh CONFIG
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/call-speed-size/dev
OBJ=/home/flo/.espressif/tools/xtensa-esp-elf/esp-13.2.0_20240530/xtensa-esp-elf/bin/xtensa-esp32-elf-objdump
NM=/home/flo/.espressif/tools/xtensa-esp-elf/esp-13.2.0_20240530/xtensa-esp-elf/bin/xtensa-esp32-elf-nm
NAMES=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a61139585de4882bc/verified/spec/src/v2/bytecodes.rs
C=$1
ELF=$A/bins/esp32-$C/toit.elf
read -r addr size _ < <("$NM" -S "$ELF" | grep -E "4step8run_loop$" | head -1)
start=$((16#$addr)); end=$((start + 16#$size))
T=$(mktemp -d)
"$OBJ" -d --no-show-raw-insn --start-address=$start --stop-address=$end "$ELF" > "$T/rl"
reg=$(grep -B3 -m1 "jx	a8" "$T/rl" | grep -m1 "addx4	a8, a8, " | sed -E 's/.*addx4	a8, a8, (a[0-9]+).*/\1/')
table=$(grep -m1 -E "l32r	$reg, .*\(3f" "$T/rl" | sed -E 's/.*\(([0-9a-f]+) .*/\1/')
tstart=$((16#$table))
"$OBJ" -s --start-address=$tstart --stop-address=$((tstart + 114 * 4)) "$ELF" | awk '
  /^ [0-9a-f]+ / { for (i = 2; i <= 5; i++) if ($i ~ /^[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]$/) { w = $i; printf "%d %d\n", n++, strtonum("0x" substr(w,7,2) substr(w,5,2) substr(w,3,2) substr(w,1,2)) } }' > "$T/h"
awk '/^pub const OPCODE_NAMES2/ { on = 1 } on { while (match($0, /"[A-Z0-9_]+"/)) { print substr($0, RSTART + 1, RLENGTH - 2); $0 = substr($0, RSTART + RLENGTH) } } on && /\];/ { exit }' "$NAMES" > "$T/n"
awk -v N="$T/n" -v E=$end -v S=$start '
  BEGIN { i = 0; while ((getline l < N) > 0) name[i++] = l }
  { op[NR] = $1; a[NR] = $2; n = NR }
  END {
    # sort by address (insertion sort on n <= 114)
    for (i = 1; i <= n; i++) idx[i] = i
    for (i = 2; i <= n; i++) { j = i; while (j > 1 && a[idx[j-1]] > a[idx[j]]) { t = idx[j]; idx[j] = idx[j-1]; idx[j-1] = t; j-- } }
    printf "%6d prologue\n", a[idx[1]] - S
    for (i = 1; i <= n; i++) {
      k = idx[i]; nxt = (i < n) ? a[idx[i+1]] : E
      if (nxt == a[k]) continue
      printf "%6d %s\n", nxt - a[k], name[op[k]]
    }
  }' "$T/h" | sort -rn
rm -rf "$T"
