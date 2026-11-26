#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
#
# Analyses a soak log (soak.sh): resets and crashes, assertion failures,
# heap corruption reports, watchdog and dead-lock reports, worker events,
# and the trend of the free heap (SOAK lines, one per minute): first and
# last values, minimum, and the least-squares slope of the free heap over
# the second half of the run (bytes per hour; a leak shows as a steady
# negative slope).
# Usage: soak-check.sh LOG
set -uo pipefail
LOG=$1
echo "== alerts (resets, crashes, assertions, heap, watchdog)"
grep -a -n -E "rst:0x|Guru Meditation|abort\(\)|Backtrace:|assert|ASSERT|CORRUPT|heap corrupt|Potential dead|watchdog|Rebooting|panic|deep sleep|Out of memory|OUT_OF_MEMORY|ALLOCATION_FAILED|MALLOC_FAILED|starting <" "$LOG" | cut -c1-220 | head -40
echo "== events"
grep -a -c "SOAK-EVENT" "$LOG" | sed 's/^/SOAK-EVENT lines: /'
grep -a "SOAK-EVENT" "$LOG" | sed 's/^[0-9]* //; s/t=[0-9]* //' | sort | uniq -c | sort -rn | head -15
echo "== first and last SOAK lines"
grep -a " SOAK t=" "$LOG" | head -2 | cut -c1-300
grep -a " SOAK t=" "$LOG" | tail -2 | cut -c1-300
echo "== free heap trend"
grep -a " SOAK t=" "$LOG" | sed -n 's/.* SOAK t=\([0-9]*\) free=\([0-9]*\) largest=\([0-9]*\) .*/\1 \2 \3/p' | awk '
  { t[NR] = $1; f[NR] = $2; l[NR] = $3 }
  END {
    if (NR == 0) { print "no SOAK lines"; exit }
    minf = f[1]; minl = l[1]
    for (i = 1; i <= NR; i++) { if (f[i] < minf) minf = f[i]; if (l[i] < minl) minl = l[i] }
    s = int(NR / 2) + 1; n = 0; sx = 0; sy = 0; sxx = 0; sxy = 0
    for (i = s; i <= NR; i++) { x = t[i] / 3600; y = f[i]; n++; sx += x; sy += y; sxx += x * x; sxy += x * y }
    slope = (n > 1 && n * sxx - sx * sx != 0) ? (n * sxy - sx * sy) / (n * sxx - sx * sx) : 0
    printf "samples %d, uptime %d s; free first %d last %d min %d; largest first %d last %d min %d\n", NR, t[NR], f[1], f[NR], minf, l[1], l[NR], minl
    printf "free-heap slope over the second half: %.0f bytes/hour\n", slope
  }'
echo "== per 15 minutes: free heap min/max, largest min, RPC calls, installs, network rounds"
grep -a " SOAK t=" "$LOG" | sed -n 's/.* SOAK t=\([0-9]*\) free=\([0-9]*\) largest=\([0-9]*\) .* calls=\([0-9]*\) restarts=\([0-9]*\) installs=\([0-9/]*\) net=\([0-9/]*\).*/\1 \2 \3 \4 \5 \6 \7/p' | awk '
  { w = int($1 / 900); if (!(w in mn) || $2 < mn[w]) mn[w] = $2; if ($2 > mx[w]) mx[w] = $2
    if (!(w in lm) || $3 < lm[w]) lm[w] = $3; calls[w] = $4; rs[w] = $5; ins[w] = $6; net[w] = $7; if (w > last) last = w }
  END { for (w = 0; w <= last; w++) if (w in mn) printf "%3d-%3d min: free %6d..%6d largest>=%6d calls %8d restarts %d installs %s net %s\n", w * 15, w * 15 + 15, mn[w], mx[w], lm[w], calls[w], rs[w], ins[w], net[w] }'
