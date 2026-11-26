#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Per-function exclusive instruction counts of callgrind run B minus run A
# (e.g. N iterations minus 0), divided by DIV (iterations).
# Usage: cgdiff.sh A.out B.out DIV [TOP] [--inclusive]
set -euo pipefail
A=$1; B=$2; DIV=$3; TOP=${4:-40}; INC=${5:-}
opt=()
[ "$INC" = --inclusive ] && opt=(--inclusive=yes)
ann() {
  callgrind_annotate "${opt[@]}" --auto=no --threshold=100 "$1" 2> /dev/null |
    awk '/^ *[0-9,]+ \(/ { n = $1; gsub(",", "", n); $1 = ""; $2 = ""; sub(/^ +/, ""); sub(/ \[.*$/, ""); sub(/^[^:]*:/, ""); c[$0] += n }
         END { for (k in c) print k "\t" c[k] }'
}
ann "$A" > "${TMPDIR:-/tmp}/cgdiff.a"
ann "$B" > "${TMPDIR:-/tmp}/cgdiff.b"
awk -F'\t' -v d="$DIV" '
  FNR == NR { a[$1] = $2; next }
  { b[$1] = $2 }
  END {
    for (k in b) { x = (b[k] - a[k]) / d; if (x > 0.5 || x < -0.5) printf "%10.1f  %s\n", x, k }
    for (k in a) if (!(k in b)) { x = -a[k] / d; if (x < -0.5) printf "%10.1f  %s\n", x, k }
  }' "${TMPDIR:-/tmp}/cgdiff.a" "${TMPDIR:-/tmp}/cgdiff.b" | sort -rn | head -"$TOP"
