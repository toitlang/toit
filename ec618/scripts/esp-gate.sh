#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# The ESP32 and ESP32-C6 firmware in format 1 (default) and format 2 on the core.
set -u
S=/home/flo/work/opentoit-sandbox-artifacts/ec618/scripts
L=/home/flo/work/opentoit-sandbox-artifacts/ec618/logs
F2=(CONFIG_TOIT_VERIFIED_CORE=y CONFIG_TOIT_BYTECODE_FORMAT_2=y CONFIG_TOIT_CXX_INTERPRETER=n)
for t in esp32 esp32c6; do
  bash "$S/esp-fw.sh" "$t" f1 > "$L/$t-f1.log" 2>&1 && echo "$t f1: $(tail -1 "$L/$t-f1.log")" || echo "$t f1: FAILED"
  bash "$S/esp-fw.sh" "$t" f2 "${F2[@]}" > "$L/$t-f2.log" 2>&1 && echo "$t f2: $(tail -1 "$L/$t-f2.log")" || echo "$t f2: FAILED"
done
