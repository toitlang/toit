#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
#
# liveness: the per-minute heap reports of a soak log (progs/soakl: "Heap
# report @ soak t=N") as a table, one row per report: t, total allocated,
# free, and the bytes of every tag (malloc tags and per-process Toit heap
# pages), then for every column the minimum over each window of W seconds
# (default 1800) and the least-squares slope of those minima over the run
# (bytes per hour; time: the host time stamps, across restarts). A leak shows as a steady rise of a column's minima; a
# drift to a plateau as minima that stop rising.
# Usage: heap-trend.sh LOG [W]   (writes LOG.heap.tsv and LOG.heap-windows.txt)
set -uo pipefail
LOG=$1
W=${2:-1800}
awk -v W="$W" -v TSV="$LOG.heap.tsv" -v WIN="$LOG.heap-windows.txt" '
  function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
  /Heap report @ soak t=/ {
    in_report = 1
    t = $0; sub(/.*soak t=/, "", t); sub(/:.*/, "", t); t = t + 0
    if (t < last_t) boot++
    last_t = t
    # The host time stamp of the line: one axis across restarts.
    host = $1 + 0; if (!start) start = host
    T = host - start
    boots[n + 1] = boot
    n++; times[n] = T; delete row; next
  }
  in_report && /Total:/ {
    tot = $0; sub(/.*Total: /, "", tot); sub(/ bytes.*/, "", tot)
    fr = $0; sub(/.*total free /, "", fr); sub(/k.*/, "", fr)
    val[n, "total"] = tot + 0; val[n, "free"] = fr * 1024
    cols["total"] = 1; cols["free"] = 1
    in_report = 0; next
  }
  in_report && /│/ {
    line = $0; sub(/^[0-9]+ /, "", line)
    split(line, f, "│")
    bytes = trim(f[2]); type = trim(f[4])
    if (bytes !~ /^[0-9]+$/) next
    if (type ~ /^(system|current|other) +[0-9]+ /) {
      split(type, p, " +"); type = "proc:" p[1] (p[1] == "other" ? p[2] : "")
    }
    gsub(/ /, "_", type)
    val[n, type] += bytes; cols[type] = 1
  }
  END {
    ncol = 0
    for (c in cols) names[++ncol] = c
    # Sort the column names.
    for (i = 1; i <= ncol; i++) for (j = i + 1; j <= ncol; j++) if (names[j] < names[i]) { x = names[i]; names[i] = names[j]; names[j] = x }
    printf "t" > TSV
    for (i = 1; i <= ncol; i++) printf "\t%s", names[i] > TSV
    printf "\n" > TSV
    for (r = 1; r <= n; r++) {
      printf "%d", times[r] > TSV
      for (i = 1; i <= ncol; i++) printf "\t%d", val[r, names[i]] > TSV
      printf "\n" > TSV
    }
    # Window minima and maxima.
    printf "%-28s", "window (s)" > WIN
    nw = 0
    for (r = 1; r <= n; r++) { w = int(times[r] / W); if (!(w in seen)) { seen[w] = 1; ws[++nw] = w } }
    for (k = 1; k <= nw; k++) printf " %9d", ws[k] * W > WIN
    printf "   slope of the minima (B/h)\n" > WIN
    for (i = 1; i <= ncol; i++) {
      c = names[i]
      delete mn
      for (r = 1; r <= n; r++) { w = int(times[r] / W); v = val[r, c]; if (!((w) in mn) || v < mn[w]) mn[w] = v }
      printf "%-28s", c > WIN
      sx = 0; sy = 0; sxx = 0; sxy = 0; m = 0
      for (k = 1; k <= nw; k++) {
        printf " %9d", mn[ws[k]] > WIN
        x = (ws[k] * W + W / 2) / 3600; y = mn[ws[k]]; m++; sx += x; sy += y; sxx += x * x; sxy += x * y
      }
      slope = (m > 1 && m * sxx - sx * sx != 0) ? (m * sxy - sx * sy) / (m * sxx - sx * sx) : 0
      printf "   %8.0f\n", slope > WIN
    }
  }' "$LOG"
echo "$LOG.heap.tsv: $(wc -l < "$LOG.heap.tsv") rows"
cat "$LOG.heap-windows.txt"
