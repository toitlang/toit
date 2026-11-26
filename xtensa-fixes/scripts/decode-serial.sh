#!/usr/bin/env bash
# Decodes the Toit system messages (stack traces) in a QEMU serial log.
# Usage: decode-serial.sh <run-dir>   (uses the run's installer snapshot)
set -uo pipefail
D=$1
TOIT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a13f01ee86eed5211/build/host/sdk/bin/toit
grep -o 'jag decode [A-Za-z0-9+/=]*' "$D/serial.txt" | cut -d' ' -f3 | while read -r m; do
  "$TOIT" decode "$m" 2>&1 | head -25
  echo ----
done
