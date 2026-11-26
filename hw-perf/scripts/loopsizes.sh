#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# run_loop size, IRAM text and toit.bin of builds in bins/.
# Usage: loopsizes.sh BUILD-NAME...
A=/home/flo/work/opentoit-sandbox-artifacts/hw-perf
for c in "$@"; do
  loop=$(bash "$A/scripts/bigsyms.sh" "$c" "step::run_loop" 1 | awk '{print $1, $2}')
  iram=$(grep '^.iram0.text ' "$A/bins/$c/sections.txt" | awk '{print $2}')
  bin=$(stat -c %s "$A/bins/$c/toit.bin")
  printf '%-22s loop %-18s iram0.text %-7s toit.bin %s\n' "$c" "$loop" "$iram" "$bin"
done
