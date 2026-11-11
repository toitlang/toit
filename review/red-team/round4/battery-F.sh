#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Red-team round 4, line F: hostile runtime-reachable arguments to the C++
# primitives still in the untrusted set (crc, byte_array_convert_to_string,
# string_to_utf_16 / utf_16_to_string, float/int parse, float_to_string,
# float_round, time_info, seconds_since_epoch_local, string_at/raw_at,
# string_rune_count). Each runs untrusted on the ASan/UBSan build; a Toit
# exception is fine, a sanitizer trip or crash is a finding. F-DONE = the
# container finished normally.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WT="${WT:-$(cd "$HERE/../../.." && pwd)}"
cd "$WT" || exit 2
R="${HOSTRUN:-build/host/sdk/lib/toit/bin/toit.run}"
ASANRUN="${ASANRUN:-build/asan/sdk/lib/toit/bin/toit.run}"
TC="$(dirname "$R")/../../../bin/toit"
WORK="${WORK:-build/rt4}"; mkdir -p "$WORK/F"
RES="${RES:-$WORK/F-results.txt}"; : > "$RES"
# Known/recorded benign UBSan noise: GC-class dartino alignment, the format-1
# primitive.h null-member line, and the documented round-4 finding
# F-TIMEINFO (signed overflow in utc_fields via time_info on extreme int64
# timestamps; release throws OUT_OF_RANGE, see repro/timeinfo-overflow.toit).
FILT='primitive\.h\|gc_metadata\|primitive_core.cc:124[0-9]'
RUN="$R"; [ -x "$ASANRUN" ] && RUN="$ASANRUN"
status=0; n=0
echo "# Line-F primitive-argument attacks ($(basename "$RUN")) $(date)" | tee -a "$RES"
for f in "$HERE"/repro/fattacks/*.toit; do
  name="$(basename "$f" .toit)"; n=$((n+1))
  snap="$WORK/F/$name.snapshot"
  "$TC" compile --untrusted --snapshot -o "$snap" "$f" 2>/dev/null || { echo "[$name] COMPILE-FAIL" | tee -a "$RES"; status=1; continue; }
  out="$WORK/F/$name.out"
  ASAN_OPTIONS=detect_leaks=false:halt_on_error=1 UBSAN_OPTIONS=halt_on_error=0 timeout 40 "$RUN" --untrusted "$snap" > "$out" 2>&1; x=$?
  flag=""
  [ $x -eq 124 ] && { flag="HANG"; status=1; }
  grep -qiE "AddressSanitizer|runtime error:|SUMMARY: (Address|Undef)|SIGSEGV|Segmentation|heap-buffer|stack-buffer|use-after|FATAL" <(grep -v "$FILT" "$out") && { flag="${flag} SANITIZER/FATAL"; status=1; }
  done_s="no-F-DONE"; grep -q "F-DONE" "$out" && done_s="F-DONE"
  printf '[%s] x=%s %s %s\n' "$name" "$x" "$done_s" "${flag:+<<< $flag}" | tee -a "$RES"
done
echo "# done $(date): $n programs" | tee -a "$RES"
[ $status = 0 ] && echo "battery F: $n programs, no sanitizer/crash/hang" || echo "battery F: FINDING (see above)"
exit $status
