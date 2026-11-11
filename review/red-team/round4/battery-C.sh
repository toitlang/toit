#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Red-team round 4, line C: 64-bit vs 32-bit host differential on 30 crafted
# programs around word-size edges (smi range, large ints, shifts, lengths,
# hashes, collection sizes). Each is compiled --untrusted once, run on the
# 64-bit (HOSTRUN) and 32-bit (HOST32) build with --untrusted; the outputs
# must be byte-identical (there are no documented differences in these
# programs: they avoid BITS-PER-WORD/architecture/platform). Any divergence,
# crash or sanitizer trip is a finding.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WT="${WT:-$(cd "$HERE/../../.." && pwd)}"
cd "$WT" || exit 2
R64="${HOSTRUN:-build/host/sdk/lib/toit/bin/toit.run}"
R32="${HOST32:-build/host32/sdk/lib/toit/bin/toit.run}"
TC="$(dirname "$R64")/../../../bin/toit"
WORK="${WORK:-build/rt4}"; mkdir -p "$WORK/cedges"
RES="${RES:-$WORK/C-results.txt}"; : > "$RES"
if [ ! -x "$R32" ]; then echo "SKIP line C: no 32-bit build at $R32" | tee -a "$RES"; exit 0; fi
status=0; n=0
for f in "$HERE"/repro/cedges/*.toit; do
  name="$(basename "$f" .toit)"; n=$((n+1))
  snap="$WORK/cedges/$name.snapshot"
  "$TC" compile --untrusted --snapshot -o "$snap" "$f" 2>/dev/null || { echo "[$name] COMPILE-FAIL" | tee -a "$RES"; status=1; continue; }
  o64="$WORK/cedges/$name.64"; o32="$WORK/cedges/$name.32"
  ASAN_OPTIONS=detect_leaks=false "$R64" --untrusted "$snap" > "$o64" 2>&1; x64=$?
  ASAN_OPTIONS=detect_leaks=false "$R32" --untrusted "$snap" > "$o32" 2>&1; x32=$?
  flag=""
  grep -qiE "AddressSanitizer|Segmentation|SIGSEGV|runtime error" "$o64" "$o32" && flag="SANITIZER"
  [ "$x64" != "$x32" ] && flag="${flag} EXITDIFF:$x64/$x32"
  if ! diff -q "$o64" "$o32" >/dev/null; then flag="${flag} OUTDIFF"; fi
  if [ -n "$flag" ]; then status=1; printf '[%s] x{%s/%s} <<< %s\n' "$name" "$x64" "$x32" "$flag" | tee -a "$RES"
  else printf '[%s] x{%s/%s} identical\n' "$name" "$x64" "$x32" | tee -a "$RES"; fi
done
echo "# done $(date): $n programs" | tee -a "$RES"
[ $status = 0 ] && echo "battery C: $n programs, 64==32, no crash" || echo "battery C: DIVERGENCE/CRASH (see above)"
exit $status
