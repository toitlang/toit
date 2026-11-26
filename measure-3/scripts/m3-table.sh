#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# measure-3's speed tables. Per benchmark of one envelope kind (bench =
# hwbench, perf = perfbench), per column: the mean over builds of each
# build's mean session median (median of 7 runs), and the min-max over
# builds; then the ratios RATIOS (e.g. "2/1 4/3": column 2 over column 1).
# Usage: RATIOS="2/1 ..." m3-table.sh KIND "LABEL|DIR|BUILD;BUILD..." ...
#   BUILD: comma-separated session log stems with % for the kind, e.g.
#   b1-f1-%-r1,b2-f1-%-r2 (a build measured in two sessions).
set -uo pipefail
KIND=$1
shift
labels=(); specs=()
for c in "$@"; do labels+=("${c%%|*}"); specs+=("${c#*|}"); done
first=${specs[0]}
fdir=${first%%|*}; fb=${first#*|}; fb=${fb%%;*}; fb=${fb%%,*}
benches=$(grep -a "^BENCH " "$fdir/${fb//%/$KIND}.txt" | awk '$3 == "min" {print $2}')
printf '| %s |' "bench ($KIND)"
for l in "${labels[@]}"; do printf ' %s |' "$l"; done
for r in ${RATIOS:-}; do printf ' %s/%s |' "${labels[$((${r%/*} - 1))]}" "${labels[$((${r#*/} - 1))]}"; done
echo
printf '|---|'; for _ in "${labels[@]}" ${RATIOS:-}; do printf -- '---:|'; done; echo
for b in $benches; do
  printf '| %s |' "$b"
  means=()
  for i in "${!specs[@]}"; do
    dir=${specs[$i]%%|*}; builds=${specs[$i]#*|}
    r=$(IFS=';'; for build in $builds; do
          IFS=','; for s in $build; do
            grep -a "^BENCH $b " "$dir/${s//%/$KIND}.txt" 2> /dev/null | sed -n 's/.* median \([0-9]*\) .*/\1/p' | head -1
          done | awk 'NF {s += $1; n++} END {if (n) printf "%f\n", s / n}'
        done | awk 'NF {s += $1; n++; if (n == 1 || $1 < lo) lo = $1; if (n == 1 || $1 > hi) hi = $1}
                    END {if (n == 0) print "- - - 0"; else printf "%.1f %.1f %.1f %d\n", s / n / 1000, lo / 1000, hi / 1000, n}')
    read -r m lo hi n <<< "$r"
    means+=("$m")
    if [ "$n" -gt 1 ]; then printf ' %s (%s-%s) |' "$m" "$lo" "$hi"; else printf ' %s |' "$m"; fi
  done
  for rr in ${RATIOS:-}; do
    awk -v a="${means[$((${rr%/*} - 1))]}" -v c="${means[$((${rr#*/} - 1))]}" 'BEGIN { if (a == "-" || c == "-") printf " - |"; else printf " %.2f |", a / c }'
  done
  echo
done
