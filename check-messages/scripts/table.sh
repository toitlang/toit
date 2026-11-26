#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Size table of the builds in bins/: toit.bin, the main sections (size -A),
# and the flash budget with Jaguar (from the queue logs' jag-check lines).
# Usage: table.sh TARGET-CONFIG...
A=/home/flo/work/opentoit-sandbox-artifacts/check-messages
printf "| build | toit.bin | flash.text | flash.rodata | IRAM (text+vectors) | DRAM data | DRAM bss | flashed + Jaguar | margin |\n|---|---:|---:|---:|---:|---:|---:|---:|---:|\n"
for b in "$@"; do
  s=$A/bins/$b/sections.txt
  sec() { awk -v n="$1" '$1 == n {print $2}' "$s"; }
  it=$(sec .iram0.text); iv=$(sec .iram0.vectors)
  iram=$(( ${it:-0} + ${iv:-0} ))
  line=$(grep -h "^$b toit.bin" $A/logs/queue*.txt | tail -1)
  jag=$(echo "$line" | sed -n 's/.*with Jaguar \([0-9]*\) (\([-+0-9]*\)).*/\1 \2/p')
  printf "| %s | %d | %d | %d | %d | %d | %d | %s | %s |\n" "$b" "$(stat -c %s $A/bins/$b/toit.bin)" \
    "$(sec .flash.text)" "$(sec .flash.rodata)" "$iram" "$(sec .dram0.data)" "$(sec .dram0.bss)" \
    "${jag% *}" "${jag#* }"
done
