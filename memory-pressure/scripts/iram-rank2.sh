#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# esp32-layout: the IRAM ranking of the verified core's functions (the
# ones TOIT_VERIFIED_CORE_IRAM_FUNCTIONS can place: the Rust library) on
# the classic ESP32. Per function: region in the profiled build (flash or
# already IRAM), size, share (%) of the time of rpc-200, tasks-1k and
# yield-2k (cycle samples of f2stall-pin1c, logs/bt-f2-pin1c) and of the
# fetch-stall samples of the installs (f2timestall, two layouts); score =
# mean of the four; ranked by score per KB. Markdown table; RE filters the
# demangled names (default: the Rust core's functions).
# Usage: iram-rank2.sh [TOP] [RE]
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/memory-pressure
S=$A/scripts
TOP=${1:-40}
RE=${2:-toit_verified_core|toit_v2_}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
c=0
for b in rpc-200 tasks-1k yield-2k; do
  c=$((c + 1))
  awk -F'\t' -v c=$c -v l="$b" '{print c "\t" l "\t" $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6}' "$A/logs/bt-f2-pin1c/$b.tsv" >> "$T/all"
done
c=$((c + 1))
for L in b2-f2timestall-base-install:esp32-f2timestall-base b1-f2timestall-p6272-base-install:esp32-f2timestall-p6272-base; do
  MODE=i-stall-busy bash "$S/func-samples.sh" "${L#*:}" 'install-(a-hello|c-map|g-big)' "${L%%:*}" |
    awk -F'\t' -v c=$c '{print c "\tinstall\t" $2 / 2 "\t" $3 "\t" $4 "\t" $5 "\t" $6}' >> "$T/all"
done
awk -F'\t' -v top="$TOP" -v re="$RE" -v ncol=$c '
  $6 == "?" || $7 !~ re { next }
  { k = $6; v[$1, k] += $3; size[k] = $4; if ($1 <= 3 || !(k in reg)) reg[k] = $5; nm[k] = $7; lab[$1] = $2; seen[k] = 1 }
  END {
    for (k in seen) { sc = 0; for (i = 1; i <= ncol; i++) sc += v[i, k]; score[k] = sc / ncol; m++; key[m] = k; d[k] = score[k] / (size[k] > 16 ? size[k] : 16) }
    for (i = 1; i <= m; i++) for (j = i + 1; j <= m; j++) if (d[key[j]] > d[key[i]]) { t = key[i]; key[i] = key[j]; key[j] = t }
    printf "| # | function | now in | size B |"
    for (i = 1; i <= ncol; i++) printf " %s %% |", lab[i]
    printf " score %% | score %%/KB | cum. flash B |\n|---:|---|---|---:|"
    for (i = 1; i <= ncol; i++) printf "---:|"
    printf "---:|---:|---:|\n"
    for (i = 1; i <= m && i <= top; i++) {
      k = key[i]; if (reg[k] == "flash") cum += size[k]
      printf "| %d | %s | %s | %d |", i, substr(nm[k], 1, 64), reg[k], size[k]
      for (j = 1; j <= ncol; j++) printf " %.2f |", v[j, k]
      printf " %.3f | %.2f | %s |\n", score[k], 1024 * d[k], reg[k] == "flash" ? cum : ""
    }
  }' "$T/all"
