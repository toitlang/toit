#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# The firmware option builds of size-2 (one after the other), each followed
# by its flash budget with Jaguar: logs/options.txt.
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/size-2
S=$A/scripts
CS=CONFIG_COMPILER_OPTIMIZATION_CHECKS_SILENT=y
F1=(CONFIG_TOIT_VERIFIED_CORE=n CONFIG_TOIT_BYTECODE_FORMAT_2=n CONFIG_TOIT_CXX_INTERPRETER=y)
{
  bash "$S/fwv.sh" f2nv CONFIG_TOIT_VERIFIED_CORE_VERIFIER=n
  bash "$S/fwv.sh" f2en CONFIG_ESP_ERR_TO_NAME_LOOKUP=n
  if bash "$S/fw.sh" esp32 f1cs "${F1[@]}" "$CS" > "$A/logs/esp32-f1cs.log" 2>&1; then
    bash "$S/jag-check.sh" esp32 f1cs
  else
    echo "esp32-f1cs: FAILED"
  fi
  TARGET=esp32c6 bash "$S/fwv.sh" f2
  TARGET=esp32c6 bash "$S/fwv.sh" f2cs "$CS"
} 2>&1 | tee -a "$A/logs/options.txt"
