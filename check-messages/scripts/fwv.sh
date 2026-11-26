#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Builds one firmware configuration (fw.sh) and its flash budget with
# Jaguar (jag-check.sh); log in logs/<target>-<name>.log.
# Usage: [IDF=shared] fwv.sh TARGET f1|f2 NAME [SDKCONFIG-LINE...]
#   f2 = the f2 lines of size-2/measure-2 (verified core, format 2, no C++
#   interpreter, loop in IRAM; on the classic ESP32 the three IRAM-freeing
#   lines); f1 = format 1 on the C++ interpreter.
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/check-messages
TARGET=$1
FMT=$2
NAME=$3
shift 3
if [ "$FMT" = f1 ]; then
  CORE=(CONFIG_TOIT_VERIFIED_CORE=n CONFIG_TOIT_BYTECODE_FORMAT_2=n CONFIG_TOIT_CXX_INTERPRETER=y)
else
  CORE=(CONFIG_TOIT_VERIFIED_CORE=y CONFIG_TOIT_BYTECODE_FORMAT_2=y CONFIG_TOIT_CXX_INTERPRETER=n CONFIG_TOIT_VERIFIED_CORE_LOOP_IN_IRAM=y)
  if [ "$TARGET" = esp32 ]; then
    CORE+=(CONFIG_ESP_WIFI_RX_IRAM_OPT=n CONFIG_ESP32_WIFI_RX_IRAM_OPT=n CONFIG_HEAP_PLACE_FUNCTION_INTO_FLASH=y CONFIG_RINGBUF_PLACE_FUNCTIONS_INTO_FLASH=y)
  fi
fi
log=$A/logs/$TARGET-$NAME.log
if bash "$A/scripts/fw.sh" "$TARGET" "$NAME" "${CORE[@]}" "$@" > "$log" 2>&1; then
  tail -1 "$log"
  bash "$A/scripts/jag-check.sh" "$TARGET" "$NAME"
else
  echo "$TARGET-$NAME: FAILED (see $log)"
fi
