#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Several hwrun.sh in a row on one board, each with the same flash options.
# Usage: hwmany.sh BOARD "FLASH-OPTIONS" ENV:LOG [ENV:LOG...]
#   e.g. hwmany.sh b1 --test-partitions esp32-f1-perf:b1-f1-perf esp32-f2-perf:b1-f2-perf
# Output in logs/<LOG>.txt; a summary on stdout.
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/esp32-layout
BOARD=$1
# shellcheck disable=SC2206
OPTS=($2)
shift 2
for spec in "$@"; do
  env=${spec%%:*}
  log=${spec#*:}
  echo "== $BOARD $env -> $log"
  bash "$A/scripts/hwrun.sh" "$BOARD" "$env" "$log" "${TIMEOUT:-600}" "${OPTS[@]}" | grep -a -E "^BENCH|^INSTALL|^WIFI|^TIME|^MEM|flash failed|mon:|Guru|abort|Backtrace" | head -60
done
