#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Per benchmark of a perfbench/hwbench log with PC samples: the share of the
# busy (non-idle) samples in groups of functions:
#   loop     the core's run loop (or the C++ interpreter's run)
#   core-fl  other functions of the core and its C++ glue that are in flash
#   core-ir  other functions of the core and its glue in IRAM/SRAM
#   memmove  ROM memmove/memcpy
#   room     room::ensure_room_all
#   rest     everything else (C++ runtime, primitives, FreeRTOS, ROM)
# Usage: shares.sh LOG-NAME BIN-NAME
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/s3-ota-soak
LOG=$1
BIN=$2
benches=$(tr -d '\r' < "$A/logs/$LOG.txt" | awk '/\[hw-perf\] begin / {print $3}' | awk '!s[$0]++')
printf '%-15s %6s %6s %6s %6s %6s %6s %6s\n' bench busy loop core-fl core-ir memmove room rest
for b in $benches; do
  bash "$A/scripts/pc-profile.sh" "$LOG" "$BIN" "^$b\$" 100000 | awk -v b="$b" '
    NR == 1 || /^  region/ { next }
    {
      c = $1; reg = $3; name = $4; for (i = 5; i <= NF; i++) name = name " " $i
      if (name ~ /esp_cpu_wait_for_intr|uart_tx_char/) next
      busy += c
      if (name ~ /step::run_loop$|^toit::Interpreter::run\(\)$/) g["loop"] += c
      else if (name ~ /ensure_room_all/) g["room"] += c
      else if (name ~ /^rom:(memmove|memcpy)$/) g["memmove"] += c
      else if (name ~ /toit_verified_core|toit_v2_|v2_primitive_failed|Interpreter::run_v2|v2_program_tables|v2_task_transfer|Interpreter::run\(\)/) {
        if (reg == "flash") g["core-fl"] += c; else g["core-ir"] += c
      } else g["rest"] += c
    }
    END {
      printf "%-15s %6d", b, busy
      split("loop core-fl core-ir memmove room rest", k, " ")
      for (i = 1; i <= 6; i++) printf " %5.1f%%", busy ? 100 * g[k[i]] / busy : 0
      printf "\n"
    }'
done
