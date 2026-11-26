#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Builds a classic-ESP32 (or TARGET=esp32c6) f2 variant: the f2 lines of
# fw-all.sh plus extra sdkconfig lines; log in logs/<target>-<name>.log, then
# the flash budget with Jaguar (jag-check.sh).
# Usage: [TARGET=esp32c6] fwv.sh NAME [SDKCONFIG-LINE...]
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/size-2
TARGET=${TARGET:-esp32}
NAME=$1
shift
CORE=(CONFIG_TOIT_VERIFIED_CORE=y CONFIG_TOIT_BYTECODE_FORMAT_2=y CONFIG_TOIT_CXX_INTERPRETER=n CONFIG_TOIT_VERIFIED_CORE_LOOP_IN_IRAM=y)
if [ "$TARGET" = esp32 ]; then
  CORE+=(CONFIG_ESP_WIFI_RX_IRAM_OPT=n CONFIG_ESP32_WIFI_RX_IRAM_OPT=n CONFIG_HEAP_PLACE_FUNCTION_INTO_FLASH=y CONFIG_RINGBUF_PLACE_FUNCTIONS_INTO_FLASH=y)
fi
log=$A/logs/$TARGET-$NAME.log
if bash "$A/scripts/fw.sh" "$TARGET" "$NAME" "${CORE[@]}" "$@" > "$log" 2>&1; then
  tail -1 "$log"
  bash "$A/scripts/jag-check.sh" "$TARGET" "$NAME"
else
  echo "$TARGET-$NAME: FAILED (see $log)"
fi
