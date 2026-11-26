#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
#
# Soak run: flashes env/<ENV>.envelope (progs/soak/soak.toit; test partitions, with the rig's
# WiFi, after erasing the flash), runs the TCP echo server the controller
# uses (port 7998) and captures the console for DURATION seconds, each line
# prefixed with the host's Unix time; then soak-check.sh lists the lines a
# human must look at (crashes, resets, assertions, heap reports, worker
# events) and the free-heap trend.
# Usage: soak.sh BOARD ENV LOG DURATION-S [--noflash]
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/memory-pressure
BOARD=$1
ENV=$2
LOGN=$3
DUR=$4
NOFLASH=0
[ "${5:-}" = --noflash ] && NOFLASH=1
case $BOARD in
  b1) PORT=/dev/ttyEsp32Board1; CHIP=ESP32 ;;
  b2) PORT=/dev/ttyEsp32Board2; CHIP=ESP32 ;;
  s3a) PORT=/dev/ttyEsp32s3Board1; CHIP=ESP32-S3 ;;
  s3b) PORT=/dev/ttyEsp32s3Board2; CHIP=ESP32-S3 ;;
  *) echo "unknown board $BOARD" >&2; exit 2 ;;
esac
LOG=$A/logs/$LOGN.txt
if [ $NOFLASH = 0 ]; then
  bash "$A/scripts/flash.sh" "$PORT" "$CHIP" "$A/env/$ENV.envelope" --wifi --erase --test-partitions > "$LOG.flash" 2>&1 || { echo "flash failed"; tail -5 "$LOG.flash"; exit 1; }
fi
socat TCP-LISTEN:7998,reuseaddr,fork EXEC:cat &
echo_pid=$!
trap 'kill $echo_pid 2> /dev/null' EXIT
GUARD_SKIP_CHIP=1 bash "$A/scripts/guard.sh" "$PORT" "$CHIP" > /dev/null || exit 1
esptool --port "$PORT" --before default-reset --after hard-reset read-mac > "$LOG.reset" 2>&1 || { echo "reset failed"; exit 1; }
stty -F "$PORT" 115200 raw -echo -echoe -echok -echoctl -echoke -icanon -hupcl min 1 time 0 || exit 1
echo "soak: $ENV on $BOARD for $DUR s from $(date -Is)"
timeout "$DUR" cat "$PORT" | awk '{ print systime(), $0; fflush() }' > "$LOG"
echo "soak: done $(date -Is), $(wc -l < "$LOG") lines"
bash "$A/scripts/soak-check.sh" "$LOG"
