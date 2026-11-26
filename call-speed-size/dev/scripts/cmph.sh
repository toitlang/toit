#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Per-handler instructions of several qprof.sh profiles side by side.
# Usage: cmph.sh NAME:CONFIG...   (profiles prof/NAME.tb, firmware bins/esp32-CONFIG)
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/call-speed-size/dev
cd "$A" || exit 1
names=()
for nc in "$@"; do
  n=${nc%%:*}; c=${nc##*:}
  bash scripts/byhandler.sh "prof/$n" "$c" > "prof/$n.byh"
  names+=("$n")
done
awk -v N="${names[*]}" '
  BEGIN { k = split(N, nm, " ") }
  { f = FILENAME; sub(/.*\//, "", f); sub(/\.byh$/, "", f); v[$2, f] = $3; ops[$2] = 1 }
  END {
    printf "%-26s", "handler"; for (i = 1; i <= k; i++) printf " %11s", nm[i]; for (i = 2; i <= k; i++) printf " %9s", "d" i; printf "\n"
    for (o in ops) {
      printf "%-26s", o; for (i = 1; i <= k; i++) printf " %11d", v[o, nm[i]]
      for (i = 2; i <= k; i++) printf " %+9d", v[o, nm[i]] - v[o, nm[i - 1]]
      printf "\n"
    }
  }' $(for n in "${names[@]}"; do echo "prof/$n.byh"; done) | sort -k2,2rn
