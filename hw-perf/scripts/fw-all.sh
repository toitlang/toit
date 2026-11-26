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
#   f1perf, f2perf: f1, f2 with TOIT_HW_PERF (src/hw_perf.h)
# Usage: fw-all.sh TARGET TAG [CONFIGS...]   (logs in logs/<target>-<config>-<tag>.log)
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/hw-perf
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
# Hot core functions outside the loop (PC samples of perfbench, hw-perf).
LIST_A="9rnonlocal8op_try_v,toit_v2_run,4room15ensure_room_all,7rarrays15cxx_primitive_v,7machine3run,5prims5array8list_add,9rnonlocal21op_non_local_return_v,5rhash14op_hash_find_v,5prims4blob20json_skip_whitespace,5prims5array9array_new"
LIST_B="$LIST_A,4step4slow,5rhash7probe_x,5rhash7hf_at_x,7rarrays18cxx_primitive_rest,9rnonlocal15unwind_resume_v,5prims4blob8blob_arg,6arraysNtNtB4_4exec7Machine9large_loc,5callsNtNtB4_4exec7Machine9do_return"
IRAMFN=${IRAMFN:-$LIST_A}
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
    f1perf) args=(CONFIG_TOIT_VERIFIED_CORE=n CONFIG_TOIT_BYTECODE_FORMAT_2=n CONFIG_TOIT_CXX_INTERPRETER=y CONFIG_TOIT_HW_PERF=y CONFIG_FREERTOS_HZ=1000) ;;
    f2perf) args=($(core 3) "${IRAM[@]}" CONFIG_TOIT_HW_PERF=y CONFIG_FREERTOS_HZ=1000) ;;
    f2h) args=($(core 3) "${IRAM[@]}" "CONFIG_TOIT_VERIFIED_CORE_IRAM_FUNCTIONS=\"$IRAMFN\"") ;;
    f2hperf) args=($(core 3) "${IRAM[@]}" "CONFIG_TOIT_VERIFIED_CORE_IRAM_FUNCTIONS=\"$IRAMFN\"" CONFIG_TOIT_HW_PERF=y CONFIG_FREERTOS_HZ=1000 CONFIG_BT_ENABLED=n) ;;
    f2hb) args=($(core 3) "${IRAM[@]}" "CONFIG_TOIT_VERIFIED_CORE_IRAM_FUNCTIONS=\"$LIST_B\"") ;;
    f2hbperf) args=($(core 3) "${IRAM[@]}" "CONFIG_TOIT_VERIFIED_CORE_IRAM_FUNCTIONS=\"$LIST_B\"" CONFIG_TOIT_HW_PERF=y CONFIG_FREERTOS_HZ=1000) ;;
    f2hbnobt) args=($(core 3) "${IRAM[@]}" "CONFIG_TOIT_VERIFIED_CORE_IRAM_FUNCTIONS=\"$LIST_B\"" CONFIG_BT_ENABLED=n) ;;
    f2nobt) args=($(core 3) "${IRAM[@]}" CONFIG_BT_ENABLED=n) ;;
    f1nobt) args=(CONFIG_TOIT_VERIFIED_CORE=n CONFIG_TOIT_BYTECODE_FORMAT_2=n CONFIG_TOIT_CXX_INTERPRETER=y CONFIG_BT_ENABLED=n) ;;
    f1rxoff) args=(CONFIG_TOIT_VERIFIED_CORE=n CONFIG_TOIT_BYTECODE_FORMAT_2=n CONFIG_TOIT_CXX_INTERPRETER=y CONFIG_ESP_WIFI_RX_IRAM_OPT=n CONFIG_ESP32_WIFI_RX_IRAM_OPT=n) ;;
    f2trace3) args=($(core 3) "${IRAM[@]}" CONFIG_TOIT_TRACE_INSTALL=y "CONFIG_TOIT_VERIFIED_CORE_VERIFIER_OPT_LEVEL=\"3\"") ;;
    f2traces) args=($(core 3) "${IRAM[@]}" CONFIG_TOIT_TRACE_INSTALL=y "CONFIG_TOIT_VERIFIED_CORE_VERIFIER_OPT_LEVEL=\"s\"") ;;
    f2traceperf) args=($(core 3) "${IRAM[@]}" CONFIG_TOIT_TRACE_INSTALL=y CONFIG_TOIT_HW_PERF=y CONFIG_FREERTOS_HZ=1000 CONFIG_BT_ENABLED=n) ;;
    *) echo "unknown config $c"; exit 2 ;;
  esac
  log=$A/logs/$TARGET-$c-$TAG.log
  if bash "$A/scripts/fw.sh" "$TARGET" "$c" "${args[@]}" > "$log" 2>&1; then
    echo "$TARGET-$c: $(tail -1 "$log")"
  else
    echo "$TARGET-$c: FAILED (see $log)"
  fi
done
