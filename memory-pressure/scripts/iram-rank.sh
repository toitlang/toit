#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# esp32-layout: IRAM candidates of the classic ESP32 format-2 firmware. For
# each function (the region it is in in the profiled builds), its size and
# its share (%) of the PC samples of rpc-200, tasks-1k and yield-2k
# (timer ticks of f2perf; i-stall samples of the two f2stall layouts) and
# of the installs (i-stall samples of the two f2timestall layouts). Score =
# mean share over the eight columns; ranked by score per byte. Prints a
# Markdown table of the TOP functions (default 40) with RE matching the
# demangled name (default: everything).
# Usage: iram-rank.sh [TOP] [RE]
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/memory-pressure
S=$A/scripts
TOP=${1:-40}
RE=${2:-.}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
n=0
col() {  # label bin regex mode logs...
  local label=$1 bin=$2 re=$3 mode=$4; shift 4
  n=$((n + 1))
  MODE=$mode bash "$S/func-samples.sh" "$bin" "$re" "$@" | awk -F'\t' -v c="$n" -v l="$label" '{print c "\t" l "\t" $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6}' >> "$T/all"
}
for b in rpc-200 tasks-1k yield-2k; do
  col "tick $b" esp32-f2perf-base "^$b\$" "" b2-f2perf-base-perf-r1
  col "stall $b" esp32-f2stall-base "^$b\$" i-stall-busy b2-f2stall-base-perf-r1
  # The second layout's table is merged into the same column (mean below).
  MODE=i-stall-busy bash "$S/func-samples.sh" esp32-f2stall-p2400-base "^$b\$" b2-f2stall-p2400-base-perf-r1 |
    awk -F'\t' -v c="$n" -v l="stall $b" '{print c "\t" l "\t" $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6}' >> "$T/all2"
done
col "stall install" esp32-f2timestall-base "install-(a-hello|c-map|g-big)" i-stall-busy b2-f2timestall-base-install
MODE=i-stall-busy bash "$S/func-samples.sh" esp32-f2timestall-p6272-base "install-(a-hello|c-map|g-big)" b1-f2timestall-p6272-base-install |
  awk -F'\t' -v c="$n" -v l="stall install" '{print c "\t" l "\t" $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6}' >> "$T/all2"
cat "$T/all" "$T/all2" | awk -F'\t' -v top="$TOP" -v re="$RE" -v ncol="$n" '
  $6 == "?" || $7 ~ /hw_perf/ { next }
  { k = $6; share[$1, k] += $3; cnt[$1, k]++; size[k] = $4; reg[k] = $5; nm[k] = $7; lab[$1] = $2; seen[k] = 1 }
  END {
    for (k in seen) {
      if (nm[k] !~ re) continue
      sc = 0
      for (c = 1; c <= ncol; c++) { v[c, k] = ((c, k) in share) ? share[c, k] / ((lab[c] ~ /^stall/) ? 2 : 1) : 0; sc += v[c, k] }
      score[k] = sc / ncol; m++; key[m] = k; d[k] = score[k] / (size[k] > 16 ? size[k] : 16)
    }
    for (i = 1; i <= m; i++) for (j = i + 1; j <= m; j++) if (d[key[j]] > d[key[i]]) { t = key[i]; key[i] = key[j]; key[j] = t }
    printf "| # | function | region | size B |"
    for (c = 1; c <= ncol; c++) printf " %s %% |", lab[c]
    printf " score | score/KB |\n|---:|---|---|---:|"
    for (c = 1; c <= ncol; c++) printf "---:|"
    printf "---:|---:|\n"
    cum = 0
    for (i = 1; i <= m && i <= top; i++) {
      k = key[i]
      printf "| %d | %s | %s | %d |", i, substr(nm[k], 1, 70), reg[k], size[k]
      for (c = 1; c <= ncol; c++) printf " %.2f |", v[c, k]
      printf " %.3f | %.2f |\n", score[k], 1024 * d[k]
    }
  }'
