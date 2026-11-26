#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Attributes the run_loop instructions of a qprof.sh profile to the opcode
# handlers: reads the dispatch jump table (the l32r into a13 at the loop
# head, 114 entries), then charges every translation block of run_loop to
# the handler with the greatest entry at or below its start (approximate:
# LLVM may place shared tails and cold blocks elsewhere).
# Usage: byhandler.sh PROF CONFIG > out   (lines: opcode name insns)
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/call-speed-size/dev
OBJ=/home/flo/.espressif/tools/xtensa-esp-elf/esp-13.2.0_20240530/xtensa-esp-elf/bin/xtensa-esp32-elf-objdump
NM=/home/flo/.espressif/tools/xtensa-esp-elf/esp-13.2.0_20240530/xtensa-esp-elf/bin/xtensa-esp32-elf-nm
NAMES=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a61139585de4882bc/verified/spec/src/v2/bytecodes.rs
PROF=$1
C=$2
ELF=$A/bins/esp32-$C/toit.elf
read -r addr size _ < <("$NM" -S "$ELF" | grep -E "4step8run_loop$" | head -1)
start=$((16#$addr)); end=$((start + 16#$size))
"$OBJ" -d --no-show-raw-insn --start-address=$start --stop-address=$end "$ELF" > /tmp/rl.$$
reg=$(grep -B3 -m1 "jx	a8" /tmp/rl.$$ | grep -m1 "addx4	a8, a8, " | sed -E 's/.*addx4	a8, a8, (a[0-9]+).*/\1/')
table=$(grep -m1 -E "l32r	$reg, .*\(3f" /tmp/rl.$$ | sed -E 's/.*\(([0-9a-f]+) .*/\1/')
rm -f /tmp/rl.$$
tstart=$((16#$table))
"$OBJ" -s --start-address=$tstart --stop-address=$((tstart + 114 * 4)) "$ELF" | awk '
  /^ [0-9a-f]+ / { for (i = 2; i <= 5; i++) if ($i ~ /^[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]$/) { w = $i; printf "%d %d\n", n++, strtonum("0x" substr(w,7,2) substr(w,5,2) substr(w,3,2) substr(w,1,2)) } }' > /tmp/handlers.$$
# Opcode names (spec bytecodes.rs: the names array, in order).
awk '/^pub const OPCODE_NAMES2/ { on = 1 } on { while (match($0, /"[A-Z0-9_]+"/)) { print substr($0, RSTART + 1, RLENGTH - 2); $0 = substr($0, RSTART + RLENGTH) } } on && /\];/ { exit }' "$NAMES" > /tmp/names.$$
awk -v s=$start -v e=$end -v H=/tmp/handlers.$$ -v NM=/tmp/names.$$ -v D="${DUMP:-}" '
  BEGIN { while ((getline l < H) > 0) { split(l, p, " "); op[p[1]] = p[2] }
          i = 0; while ((getline l < NM) > 0) name[i++] = l }
  { pc = strtonum("0x" $1) }
  pc >= s && pc < e {
    best = -1; ba = -1
    for (o in op) if (op[o] <= pc && op[o] > ba) { ba = op[o]; best = o }
    w[best] += $2 * $3; tot += $2 * $3
    if (D != "" && name[best] == D) printf "TB %s %d x %d = %d\n", $1, $2, $3, $2 * $3 > "/dev/stderr"
  }
  END { for (o in w) printf "%d %s %d\n", o, (o in name ? name[o] : "?"), w[o]; printf "-1 total %d\n", tot }' "$PROF.tb" | sort -k3,3rn
rm -f /tmp/handlers.$$ /tmp/names.$$
