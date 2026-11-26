#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Sizes of the core's run loop and slow path (and of the hot/cold loop
# sections once split) in ESP32 firmware builds: bins/esp32-CONFIG/toit.elf.
# Usage: loopsize.sh CONFIG...
NM=/home/flo/.espressif/tools/xtensa-esp-elf/esp-13.2.0_20240530/xtensa-esp-elf/bin/xtensa-esp32-elf-nm
A=/home/flo/work/opentoit-sandbox-artifacts/call-speed-size/dev
for c in "$@"; do
  printf "%-14s toit.bin %8d " "$c" "$(stat -c %s "$A/bins/esp32-$c/toit.bin")"
  "$NM" -S --size-sort "$A/bins/esp32-$c/toit.elf" | grep -E '4step8run_loop$|4step4slow$|18toit_verified_core4step' |
    awk '{ n = $4; sub(/.*4step/, "", n); printf "%s=%d ", n, strtonum("0x" $2) }'
  echo
done
