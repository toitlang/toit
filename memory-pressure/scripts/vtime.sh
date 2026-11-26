#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# memory-pressure: median (min-max) verification time per program from the
# [install-trace] lines of hwinstall logs (a-hello 801 methods, c-map 986,
# g-big 1050). Usage: vtime.sh LOG...
for log in "$@"; do
  tr -d '\r' < "$log" | grep -a "install-trace\] accepted" | awk -v name="$(basename "$log" .txt)" '
    { m = $3 + 0; us = $(NF - 1) / 1e6
      p = (m == 801) ? "a-hello" : (m == 986) ? "c-map" : (m == 1050) ? "g-big" : ""
      if (p != "") { n[p]++; v[p, n[p]] = us } }
    END {
      printf "%s:", name
      split("a-hello c-map g-big", ps, " ")
      for (k = 1; k <= 3; k++) {
        p = ps[k]; c = n[p]; if (c == 0) continue
        for (i = 1; i <= c; i++) for (j = i + 1; j <= c; j++) if (v[p, j] < v[p, i]) { t = v[p, i]; v[p, i] = v[p, j]; v[p, j] = t }
        printf " %s %.2f (%.2f-%.2f, n=%d);", p, v[p, int((c + 1) / 2)], v[p, 1], v[p, c], c
      }
      printf "\n"
    }'
done
