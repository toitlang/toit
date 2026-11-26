#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# esp32-layout: per benchmark of a stall-sample log, the mean wall time of
# its runs and, per mode, the stall cycles per run (samples x period, both
# cores) in millions, split by the region of the sampled PC (flash code,
# IRAM, ROM). At 240 MHz, 1 M cycles = 4.2 ms.
# Usage: stall-summary.sh LOG-NAME...
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/memory-pressure
for L in "$@"; do
  echo "== $L"
  tr -d '\r' < "$A/logs/$L.txt" | awk '
    function region(a) {
      if (a >= 0x40080000 && a < 0x400a0000) return "iram"
      if (a >= 0x400d0000 && a < 0x40400000) return "flash"
      if (a >= 0x40000000 && a < 0x40070000) return "rom"
      return "other"
    }
    /\[hw-perf\] begin / { b = $3; if (!(b in seen)) { seen[b] = 1; order[++nb] = b }; next }
    /\[hw-perf\] wall / { m = $6; wall[b] += $3; runs[b]++; mr[b, m]++; next }
    /^\[hw-pc\] core [01] samples/ { period = $9; next }
    /^\[hw-pc\] [01] / { for (i = 3; i <= NF; i++) { split($i, a, ":"); s[b, m, region(strtonum("0x" a[1]))] += a[2] } }
    END {
      printf "%-15s %8s | %-28s | %-28s\n", "bench", "wall ms", "i-stall-busy Mcyc/run fl ir rom", "d-stall-busy Mcyc/run fl ir rom"
      for (k = 1; k <= nb; k++) {
        b = order[k]
        printf "%-15s %8.1f |", b, wall[b] / runs[b] / 1000
        split("i-stall-busy d-stall-busy", ms, " ")
        for (j = 1; j <= 2; j++) {
          m = ms[j]; n = mr[b, m]; if (n == 0) { printf " %-28s |", "-"; continue }
          f = s[b, m, "flash"] * period / n / 1e6; ir = s[b, m, "iram"] * period / n / 1e6; ro = s[b, m, "rom"] * period / n / 1e6
          printf " %6.1f = %6.1f %6.1f %5.1f  |", f + ir + ro, f, ir, ro
        }
        printf "\n"
      }
    }'
done
