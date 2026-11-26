#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
#
# Flashes an envelope of env/ and captures the serial output.
# Usage: hwrun.sh BOARD ENV-NAME LOG-NAME TIMEOUT-S [flash options...]
#   BOARD: b1, b2 (s3b only for the memory experiment)
#   ENV-NAME: env/<ENV-NAME>.envelope; logs go to logs/<LOG-NAME>.txt.
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/liveness
case $1 in
  s3b) PORT=/dev/ttyEsp32s3Board2; CHIP=ESP32-S3 ;;
  b1) PORT=/dev/ttyEsp32Board1; CHIP=ESP32 ;;
  b2) PORT=/dev/ttyEsp32Board2; CHIP=ESP32 ;;
  *) echo "unknown board $1" >&2; exit 2 ;;
esac
ENV=$A/env/$2.envelope
LOG=$A/logs/$3.txt
T=$4
shift 4
STOP=${STOP:-"SUITE done|BENCH done|Guru Meditation|abort\(\)|Potential dead|Backtrace:|Rebooting"}
if [ "${NOFLASH:-0}" != 1 ]; then
  if ! bash "$A/scripts/flash.sh" "$PORT" "$CHIP" "$ENV" "$@" > "$LOG.flash" 2>&1; then
    echo "flash failed"; tail -20 "$LOG.flash"; exit 1
  fi
fi
bash "$A/scripts/mon.sh" "$PORT" "$CHIP" "$LOG" "$T" "$STOP"
grep -a -E "^(SUITE|TIME|MEM|BENCH|SPIN|WIFI)|Guru|abort|Potential|Backtrace|watchdog|Rebooting|rst:" "$LOG" | head -150
