#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# One measurement session per build: the bench and perf envelopes of each
# CONFIG on BOARD (ESP32 with --test-partitions, C6 with the default ones).
# Usage: session.sh BOARD TARGET RUN CONFIG...   (logs <board>-<config>-<kind>-<run>.txt)
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/esp32-layout
BOARD=$1
TARGET=$2
RUN=$3
shift 3
OPTS=()
[ "$TARGET" = esp32 ] && OPTS=(--test-partitions)
for c in "$@"; do
  for k in bench perf; do
    [ -f "$A/env/$TARGET-$c-$k.envelope" ] || bash "$A/scripts/mkenvs.sh" "$TARGET" "$c" "$k" > /dev/null
    bash "$A/scripts/hwrun.sh" "$BOARD" "$TARGET-$c-$k" "$BOARD-$c-$k-$RUN" 400 "${OPTS[@]}" > /dev/null 2>&1
    if grep -q "BENCH done" "$A/logs/$BOARD-$c-$k-$RUN.txt"; then
      echo "ok $BOARD-$c-$k-$RUN"
    else
      echo "INCOMPLETE $BOARD-$c-$k-$RUN"
    fi
  done
done
