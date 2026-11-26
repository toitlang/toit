#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Summarizes the [hw-perf] dumps of a perfbench log (TOIT_HW_PERF firmware):
# per benchmark, the buckets summed over both cores and averaged over the
# runs (cycles and instructions in thousands; the second counter per mode,
# averaged over the runs with that mode), then the top primitives.
# Usage: perf-table.sh LOG-NAME [BENCH-REGEX] [TOP]
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/hw-perf
LOG=$A/logs/$1.txt
RE=${2:-.}
TOP=${3:-8}
PRIMS=$A/primitives.txt
tr -d '\r' < "$LOG" | awk -v re="$RE" -v top="$TOP" -v prims="$PRIMS" '
  BEGIN {
    while ((getline line < prims) > 0) {
      split(line, f, " ")
      if (f[1] == "MODULE_CORE") name[f[2]] = f[3]   # core primitives only (module 0)
    }
  }
  /\[hw-perf\] begin / { bench = $3; if (!(bench in seen)) { seen[bench] = 1; order[++nb] = bench } runs[bench]++; next }
  /\[hw-perf\] wall / { mode = $6; modes[bench, mode]++; next }
  /\[hw-perf\] core [01] prim [0-9]/ {
    key = bench SUBSEP $5
    pc[key] += $9; pn[key] += $7; pi[key] += $11; po[key, mode] += $13
    if (!((bench, $5) in pseen)) { pseen[bench, $5] = 1; plist[bench] = plist[bench] " " $5 }
    next
  }
  /\[hw-perf\] core [01] / {
    b = $4
    c[bench, b] += $8; n[bench, b] += $6; ins[bench, b] += $10; oth[bench, b, mode] += $12
    if (!((bench, b) in bseen)) { bseen[bench, b] = 1; blist[bench] = blist[bench] " " b }
    next
  }
  END {
    for (k = 1; k <= nb; k++) {
      bench = order[k]
      if (bench !~ re) continue
      r = runs[bench]
      printf "== %s (%d runs; per run: count, kcycles, kinsns, CPI; second counter per mode in kcycles)\n", bench, r
      split(blist[bench], bl, " ")
      for (i in bl) {
        b = bl[i]
        line = sprintf("  %-10s n %8.1f kcyc %9.1f kins %9.1f", b, n[bench, b] / r, c[bench, b] / r / 1000, ins[bench, b] / r / 1000)
        if (ins[bench, b] > 0) line = line sprintf(" cpi %5.2f", c[bench, b] / ins[bench, b])
        ms = ""
        for (mk in modes) { split(mk, mm, SUBSEP); if (mm[1] != bench) continue
          if (modes[mk] > 0) ms = ms sprintf(" %s %.1f", mm[2], oth[bench, b, mm[2]] / modes[mk] / 1000) }
        print line ms
      }
      # Top primitives by cycles.
      split(plist[bench], pl, " ")
      np = 0
      for (i in pl) { np++; keys[np] = pl[i] }
      for (i = 1; i <= np; i++) for (j = i + 1; j <= np; j++)
        if (pc[bench SUBSEP keys[j]] > pc[bench SUBSEP keys[i]]) { t = keys[i]; keys[i] = keys[j]; keys[j] = t }
      for (i = 1; i <= np && i <= top; i++) {
        p = keys[i]; key = bench SUBSEP p
        split(p, mi, ":"); nm = (mi[1] == "0") ? name[mi[2]] : ""
        printf "    prim %-6s %-22s n %7.1f kcyc %8.1f kins %8.1f", p, nm, pn[key] / r, pc[key] / r / 1000, pi[key] / r / 1000
        if (pi[key] > 0) printf " cpi %5.2f", pc[key] / pi[key]
        printf "\n"
      }
      delete keys
    }
  }'
