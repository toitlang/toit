#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
#
# liveness: per boot of a soak log, the minima over 30-minute windows (from
# 30 minutes after the boot, after the first WiFi round) of the allocated
# total, of the memory outside the Toit heaps (total - "toit processes"), of
# the untagged malloc bytes and of the system process's allocated Toit heap
# (SOAKP sys=), and the least-squares slope of each (bytes per hour).
# Usage: boot-slopes.sh LOG   (needs LOG.heap.tsv from heap-trend.sh)
set -uo pipefail
LOG=$1
start=$(grep -a -m1 "Heap report @ soak t=" "$LOG" | cut -d' ' -f1)
boots=$(grep -a "INFO: starting <" "$LOG" | cut -d' ' -f1 | awk -v s="$start" '{ printf "%d ", ($1 - s > 0 ? $1 - s : 0) }')
sys=$(grep -a " SOAKP " "$LOG" | awk -v s="$start" '{ split($4, a, "[=,]"); printf "%d:%d ", $1 - s, a[2] }')
awk -F'\t' -v boots="$boots" -v sys="$sys" '
  BEGIN { nb = split(boots, B, " "); B[nb + 1] = 1e12
          ns = split(sys, SY, " ")
          for (i = 1; i <= ns; i++) { split(SY[i], p, ":"); st[i] = p[1]; sv[i] = p[2] } }
  NR == 1 { for (i = 1; i <= NF; i++) c[$i] = i; next }
  { t = $1; for (b = 1; b <= nb; b++) if (t >= B[b] && t < B[b + 1]) break
    if (t < B[b] + 1800) next
    w = int((t - B[b]) / 1800)
    v1 = $(c["total"]); v2 = v1 - $(c["toit_processes"]); v3 = $(c["untagged"])
    k = b SUBSEP w
    if (!(k in m1) || v1 < m1[k]) m1[k] = v1
    if (!(k in m2) || v2 < m2[k]) m2[k] = v2
    if (!(k in m3) || v3 < m3[k]) m3[k] = v3
    if (w > maxw[b]) maxw[b] = w; seen[b] = 1 }
  END {
    for (i = 1; i <= ns; i++) { t = st[i]; for (b = 1; b <= nb; b++) if (t >= B[b] && t < B[b + 1]) break
      if (t < B[b] + 1800) continue; w = int((t - B[b]) / 1800); k = b SUBSEP w
      if (!(k in m4) || sv[i] < m4[k]) m4[k] = sv[i] }
    for (b = 1; b <= nb; b++) {
      if (!seen[b]) continue
      printf "boot %d (from %d s, %.1f h of 30-min windows after the first)\n", b, B[b], (maxw[b]) / 2
      split("total outside-toit-heaps untagged sys-toit-alloc", names, " ")
      for (s = 1; s <= 4; s++) {
        printf "  %-18s", names[s]; n = 0; sx = 0; sy = 0; sxx = 0; sxy = 0
        for (w = 1; w <= maxw[b]; w++) { k = b SUBSEP w
          v = (s == 1 ? m1[k] : s == 2 ? m2[k] : s == 3 ? m3[k] : m4[k])
          if (v == "") continue
          printf " %6d", v; x = w / 2; n++; sx += x; sy += v; sxx += x * x; sxy += x * v }
        slope = (n > 1 && n * sxx - sx * sx != 0) ? (n * sxy - sx * sy) / (n * sxx - sx * sx) : 0
        printf "   slope %6.0f B/h\n", slope
      }
    }
  }' "$LOG.heap.tsv"
