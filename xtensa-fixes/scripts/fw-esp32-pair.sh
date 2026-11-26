#!/usr/bin/env bash
# Builds the ESP32 firmware without and with the verified core (opt 3), with
# the heap and ring-buffer functions moved to flash: sandbox-integration's
# esp32 firmware overflows IRAM by 2,720 bytes even without the Rust core.
# Usage: fw-esp32-pair.sh <worktree>
set -uo pipefail
WT=$1
S=/home/flo/work/opentoit-sandbox-artifacts/xtensa-fixes/scripts
L=/home/flo/work/opentoit-sandbox-artifacts/xtensa-fixes
export EXTRA_SDKCONFIG='CONFIG_HEAP_PLACE_FUNCTION_INTO_FLASH=y\nCONFIG_RINGBUF_PLACE_FUNCTIONS_INTO_FLASH=y'
bash "$S/fw-esp32.sh" "$WT" base-flashheap > "$L/fw-esp32-base-flashheap.log" 2>&1
tail -8 "$L/fw-esp32-base-flashheap.log" | cut -c1-200
bash "$S/fw-esp32.sh" "$WT" core3-flashheap core 3 > "$L/fw-esp32-core3-flashheap.log" 2>&1
tail -8 "$L/fw-esp32-core3-flashheap.log" | cut -c1-200
