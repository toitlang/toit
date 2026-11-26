#!/usr/bin/env bash
# Builds the firmware configurations of one target (never flashes):
#   f1:    format 1, C++ interpreter, no verified core (today's firmware)
#   f2cxx: format 2 on the core, C++ interpreter still linked
#   f2:    format 2 on the core, no C++ interpreter (TOIT_CXX_INTERPRETER=n)
# Usage: fw-all.sh TARGET TAG [CONFIGS...]   (logs in logs/<target>-<config>-<tag>.log)
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/device-format2
TARGET=$1
TAG=$2
shift 2
CONFIGS=${*:-f1 f2cxx f2}
CORE=(CONFIG_TOIT_VERIFIED_CORE=y 'CONFIG_TOIT_VERIFIED_CORE_OPT_LEVEL="3"' CONFIG_TOIT_BYTECODE_FORMAT_2=y)
for c in $CONFIGS; do
  case $c in
    f1) args=(CONFIG_TOIT_VERIFIED_CORE=n CONFIG_TOIT_BYTECODE_FORMAT_2=n CONFIG_TOIT_CXX_INTERPRETER=y) ;;
    f2cxx) args=("${CORE[@]}" CONFIG_TOIT_CXX_INTERPRETER=y) ;;
    f2) args=("${CORE[@]}" CONFIG_TOIT_CXX_INTERPRETER=n) ;;
    f2trace) args=("${CORE[@]}" CONFIG_TOIT_CXX_INTERPRETER=n CONFIG_TOIT_TRACE_INSTALL=y) ;;
    *) echo "unknown config $c"; exit 2 ;;
  esac
  log=$A/logs/$TARGET-$c-$TAG.log
  if bash "$A/scripts/fw.sh" "$TARGET" "$c" "${args[@]}" > "$log" 2>&1; then
    echo "$TARGET-$c: $(tail -1 "$log")"
  else
    echo "$TARGET-$c: FAILED (see $log)"
  fi
done
