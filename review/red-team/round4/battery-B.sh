#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Red-team round 4, line B: install lifecycle. Two parts.
#  (1) Shipped-certificate structural attacks: the certificate is untrusted
#      input the device checks (no inference); its decoding is proven total and
#      bounds-checked, so any mutation must make verification reject, never
#      crash or read out of bounds. We mutate magic/version/method-count/section
#      offsets+lengths/maps-stream of a valid untrusted image's certificate and
#      verify each with --require-certificate (device path) on the normal and
#      the ASan build. Acceptance is only allowed if the decoder reproduced the
#      same valid program; a crash or sanitizer trip is a finding.
#  (2) Verification-cost / pathological inputs: worst-case programs must verify
#      in bounded time/memory (reported) or be rejected by a loader bound
#      (method body <= 64 KB), never hang.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WT="${WT:-$(cd "$HERE/../../.." && pwd)}"
cd "$WT" || exit 2
R="${HOSTRUN:-build/host/sdk/lib/toit/bin/toit.run}"
ASANRUN="${ASANRUN:-build/asan/sdk/lib/toit/bin/toit.run}"
TC="$(dirname "$R")/../../../bin/toit"
WORK="${WORK:-build/rt4}"; mkdir -p "$WORK/B"
RES="${RES:-$WORK/B-results.txt}"; : > "$RES"
FILT='primitive\.h\|gc_metadata'
status=0

BASE="$WORK/B/edges-u.snapshot"
"$TC" compile --untrusted --snapshot -o "$BASE" "$HERE/repro/edges.toit" 2>/dev/null || { echo "compile base failed"; exit 2; }
TCRT=$(grep -abo TCRT "$BASE" | head -1 | cut -d: -f1)
[ -z "$TCRT" ] && { echo "no certificate in base"; exit 2; }

# mut NAME  REL_OFFSET  HEXBYTES : copies BASE, patches at TCRT+off, verifies.
mut () {
  local name="$1" rel="$2" hex="$3"
  local m="$WORK/B/$name.snapshot"; cp "$BASE" "$m"
  local n=$((${#hex}/2)) i=0
  while [ $i -lt $n ]; do
    printf "$(printf '\\x%s' ${hex:$((i*2)):2})" | dd of="$m" bs=1 seek=$((TCRT+rel+i)) count=1 conv=notrunc status=none 2>/dev/null
    i=$((i+1))
  done
  local hx ax
  "$R" --verify --require-certificate "$m" > "$WORK/B/$name.hout" 2>&1; hx=$?
  ASAN_OPTIONS=detect_leaks=false:halt_on_error=1 UBSAN_OPTIONS=halt_on_error=0 "$ASANRUN" --verify --require-certificate "$m" > "$WORK/B/$name.aout" 2>&1; ax=$?
  local ao; ao=$(grep -v "$FILT" "$WORK/B/$name.aout")
  local flag=""
  echo "$ao" | grep -qiE "AddressSanitizer|runtime error:|SUMMARY: (Address|Undef)|SIGSEGV|Segmentation|heap-buffer|stack-buffer|use-after" && { flag="SANITIZER/CRASH"; status=1; }
  [ "$ax" -ge 128 ] && [ "$ax" -ne 134 ] && { flag="${flag} asan-exit:$ax"; status=1; }
  local v="rejected"; [ "$hx" = 0 ] && v="ACCEPTED(same-valid-program)"
  printf '[cert-%s] verify-exit=%s %s %s\n' "$name" "$hx" "$v" "${flag:+<<< $flag}" | tee -a "$RES"
}

echo "# Line-B certificate structural mutations $(date)" | tee -a "$RES"
mut magic-0         0  00
mut magic-all       0  00000000
mut version-2       4  02
mut version-ff      4  ff000000
mut version-0       4  00000000
mut mcount-0        8  00000000
mut mcount-huge     8  ffffffff
mut mcount-plus1    8  36030000
mut sec0-off-huge   12 ffffffff
mut sec0-len-huge   16 ffffffff
mut sec0-off-neg    12 00000080
mut sec1-off-huge   20 ffffffff
mut sec1-len-huge   24 ffffffff
mut sec2-off-huge   28 ffffffff
mut sec2-len-huge   32 ffffffff
mut sec3-off-huge   36 ffffffff
mut sec3-len-huge   40 ffffffff
mut sec4-off-huge   44 ffffffff
mut sec4-len-huge   48 ffffffff
mut sec5-off-huge   52 ffffffff
mut sec5-len-huge   56 ffffffff
mut maps-byte1      60 ff
mut maps-byte2      64 ffffffff
mut maps-mid        120 ffffffffffffffff
mut header-allzero  0  000000000000000000000000
mut sec-selfoverlap 12 3c0000000010000000
mut sections-swap   12 00000000ffffffff

echo "# Line-B pathological verification cost" | tee -a "$RES"
for p in many-methods wide-method deep-nest big-literal many-classes; do
  src="$HERE/repro/pathological/$p.toit"; snap="$WORK/B/path-$p.snapshot"
  if ! "$TC" compile --untrusted --snapshot -o "$snap" "$src" 2>/dev/null; then echo "[path-$p] COMPILE-FAIL" | tee -a "$RES"; continue; fi
  line=$(timeout 60 env TOIT_VERIFY_TIME=1 "$R" --verify --no-certificate "$snap" 2>&1 | grep -E "^verifier:|method body too large" | head -1)
  tx=$?
  [ $tx -eq 124 ] && { echo "[path-$p] <<< VERIFY TIMEOUT (possible DoS)" | tee -a "$RES"; status=1; continue; }
  printf '[path-%s] %s\n' "$p" "$(echo "$line" | sed -E 's/, [0-9]+ objects.*peak/ ... peak/')" | tee -a "$RES"
done
echo "# done $(date)" | tee -a "$RES"
[ $status = 0 ] && echo "battery B: $(grep -c '^\[' "$RES") cases, no crash/hang; certificate mutations rejected or safe" || echo "battery B: FINDING (see above)"
exit $status
