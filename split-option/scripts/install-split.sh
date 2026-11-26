#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Verification time ([install-trace], TOIT_TRACE_INSTALL firmware) against
# the whole install time of the accepted images of a hwinstall log.
# Usage: install-split.sh LOG-NAME...
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/split-option
for f in "$@"; do
  echo "== $f"
  paste <(grep -a "install-trace\] accepted" "$A/logs/$f.txt" | sed 's/.*; \([0-9]*\) us.*$/\1/') \
        <(grep -a "^TIME install-[a-f]-" "$A/logs/$f.txt" | awk '{print $2, $3}') |
    awk '{printf "%-24s verify %.2f s  total %.2f s  rest %.2f s\n", $2, $1/1e6, $3/1e6, ($3-$1)/1e6}'
done
