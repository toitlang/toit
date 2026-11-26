#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# esp_idf_size summaries (IRAM, DRAM) of firmware builds in bins/ into
# logs/size-<target>-<config>.txt. Sources esp-idf's export.sh in its own
# shell (never flash from it).
# Usage: size.sh TARGET-CONFIG...
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/esp32-layout
export IDF_PATH=/home/flo/work/opentoit-sandbox/third_party/esp-idf
export IDF_TOOLS_PATH=$HOME/.espressif
# shellcheck disable=SC1091
. "$IDF_PATH/export.sh" > /dev/null 2>&1
for b in "$@"; do
  python -m esp_idf_size "$A/bins/$b/toit.map" > "$A/logs/size-$b.txt" 2>&1
  echo "== $b"
  grep -E "IRAM|DRAM|Flash Code|Flash Data|Used stat" "$A/logs/size-$b.txt" | head -12
done
