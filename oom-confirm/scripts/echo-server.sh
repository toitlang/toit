#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# oom-confirm: the TCP echo server the soak controllers use (port 7998), one
# for the whole session (runs of different lengths overlap). Writes its pid
# to logs/echo.pid; stop it with `kill $(cat logs/echo.pid)`.
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/oom-confirm
if ss -ltn | grep -q ":7998 "; then
  echo "echo-server: something already listens on 7998" >&2; exit 1
fi
nohup socat TCP-LISTEN:7998,reuseaddr,fork EXEC:cat > /dev/null 2>&1 &
echo $! > "$A/logs/echo.pid"
echo "echo-server: pid $(cat "$A/logs/echo.pid")"
