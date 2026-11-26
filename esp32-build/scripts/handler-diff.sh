#!/usr/bin/env bash
# Differences of two per-handler profiles (insn-profile.sh) above 100 K.
# Usage: handler-diff.sh PROF-A PROF-B   (prof/<label>.<bench> directories)
A=/home/flo/work/opentoit-sandbox-artifacts/esp32-build/prof
sort -k2 "$A/$1/handlers.txt" > "$A/$1/handlers.sorted"
sort -k2 "$A/$2/handlers.txt" > "$A/$2/handlers.sorted"
join -a1 -a2 -e0 -o 0,1.1,2.1 -1 2 -2 2 "$A/$1/handlers.sorted" "$A/$2/handlers.sorted" \
  | awk '{ d = $3 - $2; if (d > 100000 || d < -100000) printf "%12d %12d %12d %s\n", d, $2, $3, $1 }' | sort -n
