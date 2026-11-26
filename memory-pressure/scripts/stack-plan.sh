#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# memory-pressure: the stack-size measurements on one board: bench and perf
# sessions and memprobe for each configuration given (e.g. f2-base f2-stk).
# Usage: stack-plan.sh BOARD RUN CONFIG...
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/memory-pressure
BOARD=$1
RUN=$2
shift 2
cd "$A"
bash scripts/session.sh "$BOARD" esp32 "$RUN" "$@"
for c in "$@"; do
  STOP="MP done|Guru Meditation|abort\(\)|Backtrace:" bash scripts/hwrun.sh "$BOARD" "esp32-$c-memprobe" "$BOARD-$c-memprobe-$RUN" 1500 --test-partitions > /dev/null 2>&1
  echo "memprobe $c: $(grep -a -c '^MP ' "logs/$BOARD-$c-memprobe-$RUN.txt") MP lines"
done
