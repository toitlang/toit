#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# The run loop's opcode handlers in a C6 firmware: decodes the dispatch
# jump table (the register added to the scaled opcode before the loop's
# `jr`s, loaded by a lui/addi pair) and prints, per opcode, the handler
# address and the number of instructions up to the handler's first
# indirect jump (its own dispatch; a rough length of the fast path).
# Usage: handlers.sh BINS-CONFIG   (e.g. esp32c6-f2-base)
set -euo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/rpc-task-speed-3
T=$HOME/.espressif/tools/riscv32-esp-elf/esp-14.2.0_20241119/riscv32-esp-elf/bin
E=$A/bins/$1/toit.elf
read -r start size < <("$T/riscv32-esp-elf-nm" -S "$E" | awk '/step8run_loop/ { print $1, $2; exit }')
end=$(printf '%x' $((0x$start + 0x$size)))
DIS=$(mktemp)
trap 'rm -f "$DIS" "$DIS.table"' EXIT
"$T/riscv32-esp-elf-objdump" -d --no-show-raw-insn "$E" --start-address=0x$start --stop-address=0x$end > "$DIS"
table=$(awk '
  { if (match($0, /:\t([^\t]+)\t?(.*)$/, m)) { i++; ins[i] = m[1]; arg[i] = m[2] } }
  END {
    for (k = 3; k <= i; k++) if (ins[k] ~ /jr/ && ins[k-1] ~ /lw/ && ins[k-2] ~ /add/) { split(arg[k-2], a, ","); cnt[a[3]]++ }
    best = ""; for (r in cnt) if (best == "" || cnt[r] > cnt[best]) best = r
    for (k = 2; k <= i; k++) if (ins[k-1] ~ /lui/ && ins[k] ~ /addi/) {
      split(arg[k-1], a, ","); split(arg[k], b, ",")
      if (a[1] == best && b[1] == best && b[2] == best) { lo = b[3]; sub(/ .*/, "", lo); printf "%x\n", strtonum(a[2]) * 4096 + lo; exit }
    }
  }' "$DIS")
"$T/riscv32-esp-elf-objdump" -s --start-address=0x$table --stop-address=0x$(printf '%x' $((0x$table + 1024))) "$E" |
  awk '/^ [0-9a-f]+ / { for (i = 2; i <= 5; i++) { w = $i; if (length(w) == 8) print substr(w,7,2) substr(w,5,2) substr(w,3,2) substr(w,1,2) } }' |
  awk 'NR <= 256' > "$DIS.table"
awk -v dis="$DIS" '
  BEGIN { n = 0; while ((getline line < dis) > 0) { if (match(line, /^([0-9a-f]+):\t([^\t]+)/, m)) { n++; ins[n] = m[2]; idx[m[1]] = n } } }
  { op = NR - 1; h = $1; sub(/^0+/, "", h); i = idx[h]; c = 0
    if (i == "") { printf "%3d %s ?\n", op, h; next }
    while (i <= n && ins[i] !~ /jr/) { c++; i++ }
    printf "%3d %s %d\n", op, h, c }' "$DIS.table"
