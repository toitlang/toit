#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
#
# oom-confirm: the counters of a soak log (soak.sh: each line prefixed with
# the host's Unix time), per boot and in total:
#   boot: start time, length, how it ended (the cause lines before the next
#   "[toit] INFO: starting": system OOM restart, Guru Meditation, dead-lock
#   reboot, watchdog, abort; "capture end" if the capture ended first),
#   RPC calls, installs ok/failed, WiFi rounds ok/failed, worker restarts,
#   stalls (last SOAK/SOAKP line of the boot), free heap and largest block
#   minimum (SOAK lines), out-of-memory heap reports, "more failed
#   allocations" lines (and the sum of their counts), system-process
#   requests failed without restart, the longest silence between two lines
#   and the silence from the last line to the end of the capture.
# Usage: run-summary.sh LOG [CAPTURE-END-UNIX-TIME]
set -uo pipefail
LOG=$1
END=${2:-}
if [ -z "$END" ] && [ -f "${LOG%.txt}.run" ]; then
  d=$(sed -n 's/^soak: done \([^,]*\),.*/\1/p' "${LOG%.txt}.run")
  [ -n "$d" ] && END=$(date -d "$d" +%s)
fi
awk -v END_T="${END:-0}" '
function flush() {
  if (!started) return
  n++
  printf "boot %d: start %s, %d s, end: %s\n", n, strftime("%H:%M:%S", bstart), last - bstart, (cause == "" ? "-" : cause)
  printf "  calls %s installs %s net %s worker-restarts %s stalls %s; free min %s largest min %s (SOAK lines %d)\n", calls, installs, net, wrest, stalls, (minf == "" ? "-" : minf), (minl == "" ? "-" : minl), soaks
  printf "  oom heap reports %d (not-enough-memory %d); more-failed lines %d (sum %d); system requests failed w/o restart %d; longest silence %d s at %s\n", oomr, nemr, mfl, mfs, sysfail, gap, strftime("%H:%M:%S", gapat)
  tc += calls; tsoak += soaks; toomr += oomr; tmfl += mfl; tmfs += mfs; tsys += sysfail
  split(installs, a, "/"); tio += a[1]; tif += a[2]
  split(net, b, "/"); tno += b[1]; tnf += b[2]
  if (minf != "" && (gminf == "" || minf + 0 < gminf + 0)) gminf = minf
  if (minl != "" && (gminl == "" || minl + 0 < gminl + 0)) gminl = minl
}
function reset() {
  started = 1; cause = ""; calls = 0; installs = "0/0"; net = "0/0"; wrest = 0; stalls = 0; minf = ""; minl = ""; soaks = 0
  oomr = 0; nemr = 0; mfl = 0; mfs = 0; sysfail = 0; gap = 0; gapat = 0
}
{
  t = $1 + 0
  if (first == 0) first = t
  if (started && last > 0 && t - last > gap) { gap = t - last; gapat = last }
}
/\[toit\] INFO: starting/ { flush(); reset(); bstart = t }
/Out of memory in system process; restarting/ { cause = cause "system OOM restart; " }
/Guru Meditation/ { cause = cause "Guru Meditation (" gensub(/.*\((.*)\).*/, "\\1", 1, $0) "); " }
/Potential deadlock/ { cause = cause "dead-lock reboot; " }
/abort\(\)/ { cause = cause "abort; " }
/Task watchdog/ { cause = cause "task watchdog; " }
/rst:0x/ { if (started && cause == "") cause = "reset without cause line (" $2 " " $3 "); " }
/Heap report @ out of memory/ { oomr++ }
/Not enough memory for a heap report/ { nemr++ }
/more failed allocations of process group/ { mfl++; if (match($0, /: [0-9]+ more/)) mfs += substr($0, RSTART + 2, RLENGTH - 7) }
/the operation fails, no restart/ { sysfail++ }
/ SOAK t=/ {
  soaks++
  for (i = 2; i <= NF; i++) {
    split($i, kv, "=")
    if (kv[1] == "free") { if (minf == "" || kv[2] + 0 < minf + 0) minf = kv[2] }
    else if (kv[1] == "largest") { if (minl == "" || kv[2] + 0 < minl + 0) minl = kv[2] }
    else if (kv[1] == "calls") calls = kv[2]
    else if (kv[1] == "installs") installs = kv[2]
    else if (kv[1] == "net") net = kv[2]
    else if (kv[1] == "restarts") wrest = kv[2]
  }
}
/ SOAKP t=/ { if (match($0, /stalls=[0-9]+/)) stalls = substr($0, RSTART + 7, RLENGTH - 7) }
{ last = t }
END {
  if (started && END_T > 0 && cause == "") cause = "capture end"
  flush()
  printf "total: %d boots, %d s logged; calls %d, installs %d/%d, net %d/%d, free min %s, largest min %s; oom heap reports %d, more-failed lines %d (sum %d), system requests failed w/o restart %d\n", n, last - first, tc, tio, tif, tno, tnf, gminf, gminl, toomr, tmfl, tmfs, tsys
  if (END_T > 0) printf "silence from the last line to the end of the capture: %d s\n", END_T - last
}' "$LOG"
echo "== SOAK-EVENT kinds"
grep -a "SOAK-EVENT" "$LOG" | sed 's/^[0-9]* //; s/.*SOAK-EVENT t=[0-9]* //' | sed 's/[0-9a-f]\{8\}-[0-9a-f-]*/<uuid>/g' | sort | uniq -c | sort -rn | head -20
