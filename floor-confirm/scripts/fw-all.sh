#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Builds the firmware configurations of one target (never flashes), from
# the device/esp32-layout worktree:
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
A=/home/flo/work/opentoit-sandbox-artifacts/floor-confirm
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
    # measure-3: f1 with the Kconfig of e2cc27d1^ (no TOIT_SILENT_IDF_CHECKS) and f2 likewise.
    f1prev|f2prev) [ $c = f1prev ] && args=("${F1[@]}") || args=("${CORE[@]}" "${IRAM[@]}"); export KCONFIG_FROM=e2cc27d1^ ;;
    f2timeprev) args=("${CORE[@]}" "${IRAM[@]}" CONFIG_TOIT_TRACE_INSTALL=y CONFIG_TOIT_TRACE_INSTALL_HEAP=n); export KCONFIG_FROM=e2cc27d1^ ;;
    # measure-3: classic ESP32 f2 with the C6's RPC/task helpers in IRAM too
    # (the ones PC sampling found in flash on rpc-200, 3.4 KB).
    f2ir) args=("${CORE[@]}" "${IRAM[@]}" "CONFIG_TOIT_VERIFIED_CORE_IRAM_FUNCTIONS=\"$LIST_A,4step4slow,4step9slow_body,5rhash7probe_x,5rhash7hf_at_x,7machineNtNtB6_4exec7Machine11reload_cold,9rnonlocal15unwind_resume_v,9rnonlocal11enter_fin_r,7rarrays18cxx_primitive_rest,5callsNtNtB4_4exec7Machine9do_return,7rarrays8resume_r,9rnonlocal9ret_try_v,5callsNtNtB4_4exec7Machine9push_call,4step10leave_exit,5prims5float17number_to_integer\"") ;;
    f2) args=("${CORE[@]}" "${IRAM[@]}") ;;
    # floor-confirm: f2 with the diagnostic heartbeat every 30 s.
    f2hb) args=("${CORE[@]}" "${IRAM[@]}" CONFIG_TOIT_HEARTBEAT_S=30) ;;
    f2s) args=("${CORE[@]}" "${IRAM[@]}" "${SPLIT[@]}") ;;
    f2sf) args=("${CORE[@]}" "${IRAM[@]}" "${SPLIT[@]}" "CONFIG_TOIT_VERIFIED_CORE_IRAM_FUNCTIONS=\"$LIST_A,4step4slow\"") ;;
    f2perf) args=("${CORE[@]}" "${IRAM[@]}" "${PERF[@]}") ;;
    # esp32-layout: PC samples of flash-cache stall cycles (i-stall-busy /
    # d-stall-busy alternating per run) instead of timer ticks.
    f2stall) args=("${CORE[@]}" "${IRAM[@]}" "${PERF[@]}" CONFIG_TOIT_HW_PERF_STALL_SAMPLES=y) ;;
    # f1 has 858 B of IRAM free: the stall ISR needs WiFi RX code in flash.
    f1stall) args=("${F1[@]}" "${PERF[@]}" CONFIG_TOIT_HW_PERF_STALL_SAMPLES=y CONFIG_ESP_WIFI_RX_IRAM_OPT=n CONFIG_ESP32_WIFI_RX_IRAM_OPT=n) ;;
    f2timestall) args=("${CORE[@]}" "${IRAM[@]}" CONFIG_TOIT_TRACE_INSTALL=y CONFIG_TOIT_TRACE_INSTALL_HEAP=n "${PERF[@]}" CONFIG_TOIT_HW_PERF_STALL_SAMPLES=y) ;;
    f2sperf) args=("${CORE[@]}" "${IRAM[@]}" "${SPLIT[@]}" "${PERF[@]}") ;;
    f2trace) args=("${CORE[@]}" "${IRAM[@]}" CONFIG_TOIT_TRACE_INSTALL=y) ;;
    # install-speed: counters during the install, and the platform suspects
    # (Bluetooth/coexistence, the tick rate) of hw-perf's fast traceperf build.
    f2traceperf) args=("${CORE[@]}" "${IRAM[@]}" CONFIG_TOIT_TRACE_INSTALL=y "${PERF[@]}") ;;
    # memory-pressure: time-only trace with the hw-perf counters per install.
    f2timeperf) args=("${CORE[@]}" "${IRAM[@]}" CONFIG_TOIT_TRACE_INSTALL=y CONFIG_TOIT_TRACE_INSTALL_HEAP=n "${PERF[@]}") ;;
    f2time) args=("${CORE[@]}" "${IRAM[@]}" CONFIG_TOIT_TRACE_INSTALL=y CONFIG_TOIT_TRACE_INSTALL_HEAP=n) ;;
    f2tracehz) args=("${CORE[@]}" "${IRAM[@]}" CONFIG_TOIT_TRACE_INSTALL=y CONFIG_FREERTOS_HZ=1000) ;;
    f2tracenobt) args=("${CORE[@]}" "${IRAM[@]}" CONFIG_TOIT_TRACE_INSTALL=y CONFIG_BT_ENABLED=n) ;;
    f2nobt) args=("${CORE[@]}" "${IRAM[@]}" CONFIG_BT_ENABLED=n) ;;
    # VOPT=3|s|z (environment): the verifier's opt-level knob.
    f2tracev) args=("${CORE[@]}" "${IRAM[@]}" CONFIG_TOIT_TRACE_INSTALL=y "CONFIG_TOIT_VERIFIED_CORE_VERIFIER_OPT_LEVEL=\"${VOPT:-3}\"") ;;
    f2timev) args=("${CORE[@]}" "${IRAM[@]}" CONFIG_TOIT_TRACE_INSTALL=y CONFIG_TOIT_TRACE_INSTALL_HEAP=n "CONFIG_TOIT_VERIFIED_CORE_VERIFIER_OPT_LEVEL=\"${VOPT:-3}\"") ;;
    f2v) args=("${CORE[@]}" "${IRAM[@]}" "CONFIG_TOIT_VERIFIED_CORE_VERIFIER_OPT_LEVEL=\"${VOPT:-3}\"") ;;
    *) echo "unknown config $c"; exit 2 ;;
  esac
  case $c in f1prev|f2prev|f2timeprev) ;; *) unset KCONFIG_FROM ;; esac
  # esp32-layout: PIN=1 pins the hot flash code (TOIT_PIN_HOT_FLASH_CODE),
  # PIN=0 turns it off; HOT=list overrides TOIT_HOT_FLASH_FUNCTIONS (or
  # HOTFILE=file holding the list); IRAMFN=list overrides
  # TOIT_VERIFIED_CORE_IRAM_FUNCTIONS.
  [ "${PIN:-}" = 1 ] && args+=(CONFIG_TOIT_PIN_HOT_FLASH_CODE=y)
  [ "${PIN:-}" = 0 ] && args+=(CONFIG_TOIT_PIN_HOT_FLASH_CODE=n)
  [ -n "${HOTFILE:-}" ] && HOT=$(tr -d ' \n' < "$HOTFILE")
  [ -n "${HOT:-}" ] && args+=("CONFIG_TOIT_HOT_FLASH_FUNCTIONS=\"$HOT\"")
  [ -n "${IRAMFN:-}" ] && args+=("CONFIG_TOIT_VERIFIED_CORE_IRAM_FUNCTIONS=\"$IRAMFN\"")
  name=$c${VOPT:+-o$VOPT}${PAD:+-p$PAD}${RPAD:+-r$RPAD}${SUFFIX:+-$SUFFIX}
  log=$A/logs/$TARGET-$name-$TAG.log
  if bash "$A/scripts/fw.sh" "$TARGET" "$name" "${args[@]}" > "$log" 2>&1; then
    echo "$TARGET-$name: $(tail -1 "$log")"
  else
    echo "$TARGET-$name: FAILED (see $log)"
  fi
done
