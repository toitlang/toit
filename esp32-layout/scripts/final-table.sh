#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# The report's speed table: per benchmark the means (over sessions or
# layout-perturbed builds) of f1 and f2 now, f2's min-max, f2/f1, and the
# same for measure-2 and for the 11-12 November logs (hw-perf final).
# Usage: final-table.sh "F1-LOGS" "F2-LOGS" "M2-F1-LOGS" "M2-F2-LOGS" "EARLY-F1-LOGS" "EARLY-F2-LOGS"
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/esp32-layout
stat() {  # bench logs... -> mean min max (ms)
  local b=$1; shift
  for n in "$@"; do grep -a "^BENCH $b " "$A/logs/$n.txt" 2>/dev/null | sed -n 's/.* median \([0-9]*\) .*/\1/p' | head -1; done |
    awk 'NF {s += $1; n++; if (n == 1 || $1 < lo) lo = $1; if (n == 1 || $1 > hi) hi = $1}
         END {if (n == 0) print "0 0 0"; else printf "%.1f %.1f %.1f\n", s / n / 1000, lo / 1000, hi / 1000}'
}
read -r -a F1 <<< "$1"; read -r -a F2 <<< "$2"; read -r -a M1 <<< "$3"; read -r -a M2 <<< "$4"
read -r -a E1 <<< "$5"; read -r -a E2 <<< "$6"
benches=$(grep -a "^BENCH " "$A/logs/${F1[0]}.txt" | awk '$3 == "min" {print $2}')
echo "| bench | f1 | f2 (min-max) | f2/f1 | m2 f2 | m2 f2/f1 | 11-12 Nov f2 | 11-12 Nov f2/f1 | f2 / m2 f2 | f2 / 11-12 Nov f2 |"
echo "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|"
for b in $benches; do
  read -r f1 _ _ <<< "$(stat "$b" "${F1[@]}")"
  read -r f2 lo hi <<< "$(stat "$b" "${F2[@]}")"
  read -r m1 _ _ <<< "$(stat "$b" "${M1[@]}")"
  read -r m2 _ _ <<< "$(stat "$b" "${M2[@]}")"
  read -r e1 _ _ <<< "$(stat "$b" "${E1[@]}")"
  read -r e2 _ _ <<< "$(stat "$b" "${E2[@]}")"
  awk -v b="$b" -v f1="$f1" -v f2="$f2" -v lo="$lo" -v hi="$hi" -v m1="$m1" -v m2="$m2" -v e1="$e1" -v e2="$e2" '
    function r(a, c) { return (a > 0 && c > 0) ? sprintf("%.2f", a / c) : "-" }
    function t(a) { return a > 0 ? sprintf("%.1f", a) : "-" }
    BEGIN { printf "| %s | %s | %s (%s-%s) | %s | %s | %s | %s | %s | %s | %s |\n", b, t(f1), t(f2), t(lo), t(hi), r(f2, f1),
            t(m2), r(m2, m1), t(e2), r(e2, e1), r(f2, m2), r(f2, e2) }'
done
