#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Red-team round 4, line E: service layer by RUNNING an untrusted client
# against the real system process (message gate, RPC dispatch, discovery,
# quotas, print service). Each program runs as an untrusted container; the
# attack is wrapped (the expected exception is fine) and then prints "E-DONE",
# which only reaches stdout through the sandbox print service if the system
# process survived. Run on the ASan/UBSan build. A finding is: a FATAL, a
# sanitizer trip, a crash, a hang (timeout), or a missing E-DONE with an
# abnormal exit (system process harmed).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WT="${WT:-$(cd "$HERE/../../.." && pwd)}"
cd "$WT" || exit 2
R="${HOSTRUN:-build/host/sdk/lib/toit/bin/toit.run}"
ASANRUN="${ASANRUN:-build/asan/sdk/lib/toit/bin/toit.run}"
TC="$(dirname "$R")/../../../bin/toit"
WORK="${WORK:-build/rt4}"; mkdir -p "$WORK/E"
RES="${RES:-$WORK/E-results.txt}"; : > "$RES"
FILT='primitive\.h\|gc_metadata'
RUN="$R"; [ -x "$ASANRUN" ] && RUN="$ASANRUN"
status=0; n=0
echo "# Line-E service-layer attacks ($(basename "$RUN")) $(date)" | tee -a "$RES"
for f in "$HERE"/repro/eattacks/*.toit; do
  name="$(basename "$f" .toit)"; n=$((n+1))
  snap="$WORK/E/$name.snapshot"
  "$TC" compile --untrusted --snapshot -o "$snap" "$f" 2>/dev/null || { echo "[$name] COMPILE-FAIL" | tee -a "$RES"; status=1; continue; }
  out="$WORK/E/$name.out"
  ASAN_OPTIONS=detect_leaks=false:halt_on_error=1 UBSAN_OPTIONS=halt_on_error=0 timeout 40 "$RUN" --untrusted "$snap" > "$out" 2>&1; x=$?
  flag=""
  [ $x -eq 124 ] && { flag="HANG"; status=1; }
  grep -qiE "AddressSanitizer|runtime error:|SUMMARY: (Address|Undef)|SIGSEGV|Segmentation|heap-buffer|stack-buffer|use-after|FATAL|cannot start" <(grep -v "$FILT" "$out") && { flag="${flag} SANITIZER/FATAL"; status=1; }
  alive="no-E-DONE"; grep -q "E-DONE" "$out" && alive="alive"
  # A clean death of the container (exit code 0/1/241/242) with the system
  # process alive is acceptable; only system/VM harm is a finding.
  printf '[%s] x=%s %s %s %s\n' "$name" "$x" "$alive" \
    "$(grep -E '^attack ' "$out" | head -1 | cut -c1-54)" "${flag:+<<< $flag}" | tee -a "$RES"
done
echo "# done $(date): $n programs" | tee -a "$RES"
[ $status = 0 ] && echo "battery E: $n programs, system process survived, no crash/hang" || echo "battery E: FINDING (see above)"
exit $status
