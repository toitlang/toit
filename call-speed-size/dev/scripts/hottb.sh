#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# The hottest translation blocks of a qprof.sh profile inside one function
# of the ELF, with their disassembly. Usage: hottb.sh PROF CONFIG [N] [FUNC-REGEX]
#   PROF: the qprof.sh OUT prefix (PROF.tb); CONFIG: bins/esp32-CONFIG.
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/call-speed-size/dev
OBJ=/home/flo/.espressif/tools/xtensa-esp-elf/esp-13.2.0_20240530/xtensa-esp-elf/bin/xtensa-esp32-elf-objdump
NM=/home/flo/.espressif/tools/xtensa-esp-elf/esp-13.2.0_20240530/xtensa-esp-elf/bin/xtensa-esp32-elf-nm
PROF=$1
C=$2
N=${3:-40}
FUNC=${4:-4step8run_loop$}
ELF=$A/bins/esp32-$C/toit.elf
read -r addr size _ name < <("$NM" -S "$ELF" | grep -E "$FUNC" | head -1)
start=$((16#$addr)); end=$((start + 16#$size))
DIS=$(mktemp)
"$OBJ" -d --no-show-raw-insn --start-address=$start --stop-address=$end "$ELF" > "$DIS"
awk -v s=$start -v e=$end '{ pc = strtonum("0x" $1) } pc >= s && pc < e { printf "%d %s %d %d\n", $2 * $3, $1, $2, $3 }' "$PROF.tb" | sort -rn | head -"$N" |
while read -r w pc n x; do
  printf "== %x (+0x%x) %d insns x %d = %d\n" $((16#$pc)) $((16#$pc - start)) "$n" "$x" "$w"
  grep -A$((n - 1)) -m1 "^$pc:" "$DIS" | cut -c1-90
done
rm -f "$DIS"
