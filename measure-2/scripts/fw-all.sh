#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Builds the firmware configurations of one target (never flashes):
#   f1:     format 1, C++ interpreter, no verified core (today's firmware)
#   f2:     format 2 on the core, no C++ interpreter, the Kconfig defaults of
#           sandbox-integration 7f7ad28e (call-speed-size): split loop, hot
#           part in IRAM (TOIT_VERIFIED_CORE_LOOP_IN_IRAM), core opt-level s
#           on Xtensa / 3 on RISC-V, default TOIT_VERIFIED_CORE_IRAM_FUNCTIONS
#           (classic ESP32: list A + step::slow, step_cold, slow_body; C6:
#           list B + slow, slow_body); on the classic ESP32 with the three
#           IRAM-freeing lines below (needed by LOOP_IN_IRAM)
#   f2old:  the configuration of the earlier hardware measurements (hw-perf
#           a3cc7ee2): opt-level 3, IRAM functions list A (ESP32) / list B
#           (C6); the loop is split now whatever the configuration
#   f2perf, f1perf: f2, f1 with TOIT_HW_PERF (src/hw_perf.h), 1 kHz tick
#   f2trace: f2 with TOIT_TRACE_INSTALL
#   f2o3:   f2 with the core at opt-level 3 (IRAM list unchanged)
# Usage: fw-all.sh TARGET TAG [CONFIGS...]   (logs in logs/<target>-<config>-<tag>.log)
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/measure-2
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
PERF=(CONFIG_TOIT_HW_PERF=y CONFIG_FREERTOS_HZ=1000)
# The hot core functions outside the loop of hw-perf (PC samples of perfbench).
LIST_A="9rnonlocal8op_try_v,toit_v2_run,4room15ensure_room_all,7rarrays15cxx_primitive_v,7machine3run,5prims5array8list_add,9rnonlocal21op_non_local_return_v,5rhash14op_hash_find_v,5prims4blob20json_skip_whitespace,5prims5array9array_new"
LIST_B="$LIST_A,4step4slow,5rhash7probe_x,5rhash7hf_at_x,7rarrays18cxx_primitive_rest,9rnonlocal15unwind_resume_v,5prims4blob8blob_arg,6arraysNtNtB4_4exec7Machine9large_loc,5callsNtNtB4_4exec7Machine9do_return"
OLDLIST=$LIST_A
[ "$TARGET" = esp32 ] || OLDLIST=$LIST_B
for c in $CONFIGS; do
  case $c in
    f1) args=("${F1[@]}") ;;
    f1perf) args=("${F1[@]}" "${PERF[@]}") ;;
    f2) args=("${CORE[@]}" "${IRAM[@]}") ;;
    # f2 args; the source must be patched by hand (experiments, see README).
    # The C6 default list plus the loop's cold part (step_cold) in IRAM.
    f2cold) args=("${CORE[@]}" "${IRAM[@]}" "CONFIG_TOIT_VERIFIED_CORE_IRAM_FUNCTIONS=\"$LIST_B,4step9slow_body,4step9step_cold\"") ;;
    f2nosplit|f2x*) args=("${CORE[@]}" "${IRAM[@]}") ;;
    # Unsplit loop on the classic ESP32: the default list without step_cold.
    f2nosplitl) args=("${CORE[@]}" "${IRAM[@]}" "CONFIG_TOIT_VERIFIED_CORE_IRAM_FUNCTIONS=\"$LIST_A,4step4slow,4step9slow_body\"") ;;
    f2perf) args=("${CORE[@]}" "${IRAM[@]}" "${PERF[@]}") ;;
    f2trace) args=("${CORE[@]}" "${IRAM[@]}" CONFIG_TOIT_TRACE_INSTALL=y) ;;
    f2o3) args=("${CORE[@]}" "${IRAM[@]}" 'CONFIG_TOIT_VERIFIED_CORE_OPT_LEVEL="3"') ;;
    f2old) args=("${CORE[@]}" "${IRAM[@]}" 'CONFIG_TOIT_VERIFIED_CORE_OPT_LEVEL="3"' "CONFIG_TOIT_VERIFIED_CORE_IRAM_FUNCTIONS=\"$OLDLIST\"") ;;
    f2oldperf) args=("${CORE[@]}" "${IRAM[@]}" 'CONFIG_TOIT_VERIFIED_CORE_OPT_LEVEL="3"' "CONFIG_TOIT_VERIFIED_CORE_IRAM_FUNCTIONS=\"$OLDLIST\"" "${PERF[@]}") ;;
    *) echo "unknown config $c"; exit 2 ;;
  esac
  log=$A/logs/$TARGET-$c-$TAG.log
  if bash "$A/scripts/fw.sh" "$TARGET" "$c" "${args[@]}" > "$log" 2>&1; then
    echo "$TARGET-$c: $(tail -1 "$log")"
  else
    echo "$TARGET-$c: FAILED (see $log)"
  fi
done
