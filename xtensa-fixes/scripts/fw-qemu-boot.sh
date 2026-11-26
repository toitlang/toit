#!/usr/bin/env bash
# Boots a Toit ESP32 firmware build (merged with its bootloader, partition
# table and OTA data) under Espressif's QEMU for N seconds and saves the
# serial output. Never touches hardware.
# Usage: fw-qemu-boot.sh <firmware-build-dir> <out-dir> [seconds] [firmware-bin]
set -uo pipefail
B=$1
OUT=$2
SECS=${3:-30}
FW=${4:-$B/toit-firmware.bin}
mkdir -p "$OUT"
export IDF_PATH=/home/flo/work/opentoit-sandbox/third_party/esp-idf
export IDF_TOOLS_PATH=$HOME/.espressif
# shellcheck disable=SC1091
. "$IDF_PATH/export.sh" > /dev/null 2>&1
QEMU=$HOME/.espressif/tools/qemu-xtensa/esp_develop_9.2.2_20261109/qemu/bin/qemu-system-xtensa
esptool.py --chip esp32 merge_bin --fill-flash-size 4MB -o "$OUT/flash.bin" \
  --flash_mode dio --flash_freq 40m --flash_size 4MB \
  0x1000 "$B/bootloader/bootloader.bin" 0x8000 "$B/partition_table/partition-table.bin" \
  0xd000 "$B/ota_data_initial.bin" 0x10000 "$FW" > "$OUT/merge.log" 2>&1 || { cat "$OUT/merge.log"; exit 1; }
timeout "$SECS" "$QEMU" -nographic -machine esp32 -drive file="$OUT/flash.bin",if=mtd,format=raw \
  -serial file:"$OUT/serial.log" -monitor none -no-reboot > "$OUT/qemu.log" 2>&1
tr -d '\r' < "$OUT/serial.log" | tail -40
