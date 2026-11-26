#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# WiFi RX throughput (progs/suite/hwrx.toit): serves 1 MB of zeros per TCP
# connection on port 7998, flashes env <ENV> with the rig's WiFi and
# captures the "RX" lines into logs/<LOG>.txt.
# Usage: rx.sh BOARD ENV LOG [flash options...]
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/rpc-task-speed-3
BOARD=$1
ENV=$2
LOG=$3
shift 3
socat TCP-LISTEN:7998,reuseaddr,fork SYSTEM:"head -c 1048576 /dev/zero" &
srv=$!
trap 'kill "$srv" 2> /dev/null' EXIT
STOP="RX done|Guru Meditation|abort\(\)|Backtrace:" bash "$A/scripts/hwrun.sh" "$BOARD" "$ENV" "$LOG" 300 --wifi "$@" > /dev/null
grep -a -E "^RX|Guru|abort" "$A/logs/$LOG.txt"
