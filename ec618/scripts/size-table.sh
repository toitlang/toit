#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# One line per EC618 configuration: VM body, extension (system image), .data,
# .bss, populated slot, Rust library, C++ interpreter, format-2 glue.
set -euo pipefail
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a6c88832d90141abe
A=/home/flo/work/opentoit-sandbox-artifacts/ec618
BIN=$A/bin
printf "%-7s %9s %9s %7s %7s %9s %8s %8s %8s %9s\n" config vm_a ext data bss populated rust cxx_int glue2 snapshot
for n in f1 f2 f2s f2z f2nv f2cxx; do
  d=$WT/build/ec618-$n
  [ "$n" = f1 ] && d=$WT/build/ec618
  log=$A/logs/build-$n.log
  sizes=$("$BIN/arm-none-eabi-size" -A "$d/toit-slot-a.elf")
  vma=$(echo "$sizes" | awk '$1==".vm_a" {print $2}')
  data=$(echo "$sizes" | awk '$1==".vm_dram_data" {print $2}')
  bss=$(echo "$sizes" | awk '$1==".vm_dram_zi" {print $2}')
  ext=$(grep -m1 'ext-verify\] OK' "$log" | sed 's/.*pointers, \([0-9]*\) bytes.*/\1/')
  trailer=$(stat -c %s "$d/slot-reloc.bin")
  populated=$((vma + ext + data + trailer + 4))
  m=$(bash "$A/scripts/mapsizes.sh" "$d/toit-slot-a.map")
  rust=$(echo "$m" | awk '$1==".vm_a" && /rust/ {print $NF}')
  cxx=$(echo "$m" | awk '$1==".vm_a" && /interpreter \(format 1\)/ {print $NF}')
  glue=$(echo "$m" | awk '$1==".vm_a" && /format-2 glue/ {print $NF}')
  snap=$(stat -c %s "$d/system.snapshot")
  printf "%-7s %9d %9d %7d %7d %9d %8s %8s %8s %9d\n" "$n" "$vma" "$ext" "$data" "$bss" "$populated" "${rust:-0}" "${cxx:-0}" "${glue:-0}" "$snap"
done
echo "slot: $((0xC0000)) bytes; VM RAM pool: $((0x6000)) bytes (.data 0x2000 + .bss 0x4000 reserves)"
