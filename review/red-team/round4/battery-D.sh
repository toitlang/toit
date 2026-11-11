#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Red-team round 4, line D: runtime-built crafted/inconsistent collections and
# objects, driving the builtins (LOOP_REPEAT, LOOP_ARRAY, HASH_FIND) and the
# allowed C++ primitives (rebuild_hash_index, array_*, blit, slices) with
# adversarial state. Each program is compiled --untrusted and run on the normal
# and the ASan/UBSan build; a Toit exception is acceptable, a sanitizer trip or
# crash is a finding. Compares the normal-build output against the recorded one.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WT="${WT:-$(cd "$HERE/../../.." && pwd)}"
cd "$WT" || exit 2
R64="${HOSTRUN:-build/host/sdk/lib/toit/bin/toit.run}"
ASANRUN="${ASANRUN:-build/asan/sdk/lib/toit/bin/toit.run}"
TC="$(dirname "$R64")/../../../bin/toit"
WORK="${WORK:-build/rt4}"; mkdir -p "$WORK/dcoll"
RES="${RES:-$WORK/D-results.txt}"; : > "$RES"
EXPECTED="$HERE/repro/D-results.txt"
FILT='primitive\.h\|gc_metadata'
if [ ! -x "$ASANRUN" ]; then echo "SKIP line D: no ASan build at $ASANRUN" | tee -a "$RES"; exit 0; fi
status=0; n=0
for f in "$HERE"/repro/dcoll/*.toit; do
  name="$(basename "$f" .toit)"; n=$((n+1))
  snap="$WORK/dcoll/$name.snapshot"
  "$TC" compile --untrusted --snapshot -o "$snap" "$f" 2>/dev/null || { echo "[$name] COMPILE-FAIL" | tee -a "$RES"; status=1; continue; }
  ho=$("$R64" --untrusted "$snap" 2>&1 | grep -v "$FILT" | tr '\n' '|'); hx=${PIPESTATUS[0]}
  ao=$(ASAN_OPTIONS=detect_leaks=false:halt_on_error=1 UBSAN_OPTIONS=halt_on_error=0 "$ASANRUN" --untrusted "$snap" 2>&1 | grep -v "$FILT"); ax=${PIPESTATUS[0]}
  flag=""
  echo "$ao" | grep -qiE "AddressSanitizer|runtime error:|SUMMARY: (Address|Undef)|assertion|FATAL|SIGSEGV|Segmentation|heap-buffer|stack-buffer|use-after" && { flag="SANITIZER/CRASH"; status=1; }
  [ "$ax" -ge 128 ] && [ "$ax" -ne 134 ] && { flag="${flag} asan-exit:$ax"; status=1; }
  printf '[%s] x{%s/%s} %s %s\n' "$name" "$hx" "$ax" "$(echo "$ho" | cut -c1-48)" "${flag:+<<< $flag}" | tee -a "$RES"
done
echo "# done $(date): $n programs" | tee -a "$RES"
if [ -f "$EXPECTED" ]; then
  diffs=$(diff <(grep '^\[' "$EXPECTED" | sed -E 's/ x\{[0-9]*\/[0-9]*\}//' | sort) <(grep '^\[' "$RES" | sed -E 's/ x\{[0-9]*\/[0-9]*\}//' | sort) || true)
  [ -n "$diffs" ] && { echo "battery D: output differs from recorded:"; echo "$diffs"; status=1; }
fi
[ $status = 0 ] && echo "battery D: $n programs, no sanitizer/crash" || echo "battery D: FINDING (see above)"
exit $status
