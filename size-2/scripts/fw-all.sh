#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Builds the firmware configurations of one target (never flashes), from
# the device/size-2 worktree:
#   f1:     format 1, C++ interpreter, no verified core
#   f2:     format 2 on the core, no C++ interpreter, the Kconfig defaults of
#           core/split-option: whole loop (TOIT_VERIFIED_CORE_SPLIT_LOOP=n),
#           loop in IRAM, default TOIT_VERIFIED_CORE_IRAM_FUNCTIONS (classic
#           ESP32: list A + step::slow; C6: list B, which has step::slow);
#           on the classic ESP32 with the three IRAM-freeing lines below
#   f2s:    f2 with the split loop (improved hot set; ESP32 default list:
#           A + slow + step_cold, i.e. the cold part in IRAM; C6: list B,
#           cold part in flash)
#   f2sf:   classic ESP32: f2s with the cold part in flash (list A + slow)
#   f2perf, f2sperf, f1perf: with TOIT_HW_PERF (src/hw_perf.h), 1 kHz tick
#   f2trace: f2 with TOIT_TRACE_INSTALL
# PAD=N (environment): layout perturbation (fw.sh); the name gets -pN.
# Usage: fw-all.sh TARGET TAG [CONFIGS...]   (logs in logs/<target>-<name>-<tag>.log)
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/size-2
TARGET=$1
TAG=$2
shift 2
CONFIGS=${*:-f1 f2}
CORE=(CONFIG_TOIT_VERIFIED_CORE=y CONFIG_TOIT_BYTECODE_FORMAT_2=y CONFIG_TOIT_CXX_INTERPRETER=n)
F1=(CONFIG_TOIT_VERIFIED_CORE=n CONFIG_TOIT_BYTECODE_FORMAT_2=n CONFIG_TOIT_CXX_INTERPRETER=y)
IRAM=(CONFIG_TOIT_VERIFIED_CORE_LOOP_IN_IRAM=y)
if [ "$TARGET" = esp32 ]; then
  IRAM+=(CONFIG_ESP_WIFI_RX_IRAM_OPT=n CONFIG_ESP32_WIFI_RX_IRAM_OPT=n CONFIG_HEAP_PLACE_FUNCTION_INTO_FLASH=y CONFIG_RINGBUF_PLACE_FUNCTIONS_INTO_FLASH=y)
fi
SPLIT=(CONFIG_TOIT_VERIFIED_CORE_SPLIT_LOOP=y)
PERF=(CONFIG_TOIT_HW_PERF=y CONFIG_FREERTOS_HZ=1000)
LIST_A="9rnonlocal8op_try_v,toit_v2_run,4room15ensure_room_all,7rarrays15cxx_primitive_v,7machine3run,5prims5array8list_add,9rnonlocal21op_non_local_return_v,5rhash14op_hash_find_v,5prims4blob20json_skip_whitespace,5prims5array9array_new"
for c in $CONFIGS; do
  case $c in
    f1) args=("${F1[@]}") ;;
    f1perf) args=("${F1[@]}" "${PERF[@]}") ;;
    f2) args=("${CORE[@]}" "${IRAM[@]}") ;;
    f2s) args=("${CORE[@]}" "${IRAM[@]}" "${SPLIT[@]}") ;;
    f2sf) args=("${CORE[@]}" "${IRAM[@]}" "${SPLIT[@]}" "CONFIG_TOIT_VERIFIED_CORE_IRAM_FUNCTIONS=\"$LIST_A,4step4slow\"") ;;
    f2perf) args=("${CORE[@]}" "${IRAM[@]}" "${PERF[@]}") ;;
    f2sperf) args=("${CORE[@]}" "${IRAM[@]}" "${SPLIT[@]}" "${PERF[@]}") ;;
    f2trace) args=("${CORE[@]}" "${IRAM[@]}" CONFIG_TOIT_TRACE_INSTALL=y) ;;
    *) echo "unknown config $c"; exit 2 ;;
  esac
  name=$c${PAD:+-p$PAD}
  log=$A/logs/$TARGET-$name-$TAG.log
  if bash "$A/scripts/fw.sh" "$TARGET" "$name" "${args[@]}" > "$log" 2>&1; then
    echo "$TARGET-$name: $(tail -1 "$log")"
  else
    echo "$TARGET-$name: FAILED (see $log)"
  fi
done
