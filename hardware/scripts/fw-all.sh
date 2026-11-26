#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Builds the firmware configurations of one target (never flashes):
#   f1:     format 1, C++ interpreter, no verified core (today's firmware)
#   f2cxx:  format 2 on the core, C++ interpreter still linked
#   f2:     format 2 on the core, no C++ interpreter, core loop in IRAM
#           (TOIT_VERIFIED_CORE_LOOP_IN_IRAM; on the classic ESP32 with the
#           three IRAM-freeing lines below)
#   f2s, f2z: f2 with the core at opt-level s / z
#   f2flash: f2 with the loop in flash (TOIT_VERIFIED_CORE_LOOP_IN_IRAM=n),
#           f2flashs, f2flashz: the same at s / z
#   f2trace: f2 with TOIT_TRACE_INSTALL
# Usage: fw-all.sh TARGET TAG [CONFIGS...]   (logs in logs/<target>-<config>-<tag>.log)
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/hardware
TARGET=$1
TAG=$2
shift 2
CONFIGS=${*:-f1 f2cxx f2}
core() {  # opt-level
  echo CONFIG_TOIT_VERIFIED_CORE=y "CONFIG_TOIT_VERIFIED_CORE_OPT_LEVEL=\"$1\"" CONFIG_TOIT_BYTECODE_FORMAT_2=y CONFIG_TOIT_CXX_INTERPRETER=n
}
IRAM=(CONFIG_TOIT_VERIFIED_CORE_LOOP_IN_IRAM=y)
if [ "$TARGET" = esp32 ]; then
  IRAM+=(CONFIG_ESP_WIFI_RX_IRAM_OPT=n CONFIG_ESP32_WIFI_RX_IRAM_OPT=n CONFIG_HEAP_PLACE_FUNCTION_INTO_FLASH=y CONFIG_RINGBUF_PLACE_FUNCTIONS_INTO_FLASH=y)
fi
FLASH=(CONFIG_TOIT_VERIFIED_CORE_LOOP_IN_IRAM=n)
for c in $CONFIGS; do
  # shellcheck disable=SC2207
  case $c in
    f1) args=(CONFIG_TOIT_VERIFIED_CORE=n CONFIG_TOIT_BYTECODE_FORMAT_2=n CONFIG_TOIT_CXX_INTERPRETER=y) ;;
    f2cxx) args=(CONFIG_TOIT_VERIFIED_CORE=y 'CONFIG_TOIT_VERIFIED_CORE_OPT_LEVEL="3"' CONFIG_TOIT_BYTECODE_FORMAT_2=y CONFIG_TOIT_CXX_INTERPRETER=y "${FLASH[@]}") ;;
    f2) args=($(core 3) "${IRAM[@]}") ;;
    f2s) args=($(core s) "${IRAM[@]}") ;;
    f2z) args=($(core z) "${IRAM[@]}") ;;
    f2flash) args=($(core 3) "${FLASH[@]}") ;;
    f2flashs) args=($(core s) "${FLASH[@]}") ;;
    f2flashz) args=($(core z) "${FLASH[@]}") ;;
    f2trace) args=($(core 3) "${IRAM[@]}" CONFIG_TOIT_TRACE_INSTALL=y) ;;
    *) echo "unknown config $c"; exit 2 ;;
  esac
  log=$A/logs/$TARGET-$c-$TAG.log
  if bash "$A/scripts/fw.sh" "$TARGET" "$c" "${args[@]}" > "$log" 2>&1; then
    echo "$TARGET-$c: $(tail -1 "$log")"
  else
    echo "$TARGET-$c: FAILED (see $log)"
  fi
done
