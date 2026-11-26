#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Calls per iteration of every function: (calls in run B - calls in run A) / DIV,
# from callgrind_annotate's caller trees.
# Usage: cgcalls.sh A.out B.out DIV [REGEX]
set -euo pipefail
A=$1; B=$2; DIV=$3; RE=${4:-.}
calls() {
  callgrind_annotate --tree=caller --auto=no --threshold=100 "$1" 2> /dev/null |
    awk '
      /^$/ { n = 0; next }
      /^ *[0-9,]+ \([ 0-9.]+%\)  < / {
        if (match($0, /\(([0-9,]+)x\)/, a)) { x = a[1]; gsub(",", "", x); n += x }
        next
      }
      /^ *[0-9,]+ \([ 0-9.]+%\)  \*  / {
        s = $0; sub(/^.*\*  /, "", s); sub(/ \[.*$/, "", s); sub(/^[^:]*:/, "", s)
        c[s] += n; n = 0; next
      }
      END { for (k in c) print k "\t" c[k] }'
}
T=${TMPDIR:-/tmp}
calls "$A" > "$T/cgcalls.a"
calls "$B" > "$T/cgcalls.b"
awk -F'\t' -v d="$DIV" '
  FNR == NR { a[$1] = $2; next }
  { x = ($2 - a[$1]) / d; if (x >= 0.5) printf "%9.1f  %s\n", x, $1 }' "$T/cgcalls.a" "$T/cgcalls.b" |
  grep -E "$RE" | sort -rn
