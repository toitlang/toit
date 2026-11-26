#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# memory-pressure: hwinstall with a time-only build per config on one board
# (waits for each envelope to exist). Usage: time-runs.sh BOARD CONFIG...
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/memory-pressure
cd "$A"
BOARD=$1
shift
for c in "$@"; do
  until [ -f "env/esp32-$c-install.envelope" ]; do sleep 10; done
  sleep 5
  bash scripts/hwrun.sh "$BOARD" "esp32-$c-install" "$BOARD-$c-install" 900 --test-partitions --wifi > /dev/null 2>&1
  echo "$c: $(bash scripts/vtime.sh "logs/$BOARD-$c-install.txt")"
done
