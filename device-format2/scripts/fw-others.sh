#!/usr/bin/env bash
# Builds the other ESP32 targets in their default configuration (format 1,
# no verified core), to check that they still build. Never flashes.
# Usage: fw-others.sh TAG [TARGETS...]
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/device-format2
TAG=$1
shift
TARGETS=${*:-esp32c3 esp32s2 esp32s3}
for t in $TARGETS; do
  log=$A/logs/$t-default-$TAG.log
  if bash "$A/scripts/fw.sh" "$t" default > "$log" 2>&1; then
    echo "$t: $(tail -1 "$log")"
  else
    echo "$t: FAILED (see $log)"
  fi
done
