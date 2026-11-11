#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Red-team round 4, line A (certificate / trusted-untrusted confusion via the
# shipped certificate). Device-like path: `toit.run --verify` with
# --require-certificate (no inference fallback) and --trusted selecting the
# rules. A trusted certificate must not make the untrusted rules accept a twin;
# a corrupt/short/wrong-count certificate must be rejected, never run. Exit 0 =
# accepted, 1 = rejected, 2 = usage. The battery asserts each verdict.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WT="${WT:-$(cd "$HERE/../../.." && pwd)}"
cd "$WT" || exit 2
R="${HOSTRUN:-build/host/sdk/lib/toit/bin/toit.run}"
TC="$(dirname "$R")/../../../bin/toit"
WORK="${WORK:-build/rt4}"; mkdir -p "$WORK"
RES="${RES:-$WORK/A-cert-results.txt}"; : > "$RES"
status=0

compile_u () { "$TC" compile --untrusted --snapshot -o "$2" "$1" 2>/dev/null; }
compile_t () { "$TC" compile --snapshot -o "$2" "$1" 2>/dev/null; }

verify () {  # name  expected-exit  args...
  local name="$1"; local want="$2"; shift 2
  "$R" --verify "$@" >/dev/null 2>"$WORK/$name.err"; local got=$?
  local tag="OK"; [ "$got" != "$want" ] && { tag="MISMATCH"; status=1; }
  printf '[%s] exit=%s want=%s %s  %s\n' "$name" "$got" "$want" "$tag" \
    "$(grep -oiE 'unchecked opcode [0-9]+|shipped certificate[^\"]*|malformed certificate[^\"]*|no shipped certificate|REJECTED|ACCEPTED' "$WORK/$name.err" | head -1)" | tee -a "$RES"
}

compile_u "$HERE/repro/edges.toit" "$WORK/Ac-edges-u.snapshot"
compile_t "$HERE/repro/fields.toit" "$WORK/Ac-twins-t.snapshot"

# Baselines.
verify base-untrusted-cert      0 --require-certificate "$WORK/Ac-edges-u.snapshot"
verify base-untrusted-infer     0 --no-certificate "$WORK/Ac-edges-u.snapshot"
verify twins-untrusted-infer    1 --no-certificate "$WORK/Ac-twins-t.snapshot"
verify twins-trusted-rules      0 --trusted --no-certificate "$WORK/Ac-twins-t.snapshot"
# A valid TRUSTED certificate must not make the untrusted rules accept twins.
"$R" --certify --trusted "$WORK/Ac-twins-t.snapshot" -o "$WORK/Ac-twins-trustedcert.snapshot" 2>/dev/null
verify twins-trustedcert-untrusted 1 --require-certificate "$WORK/Ac-twins-trustedcert.snapshot"
verify twins-trustedcert-trusted   0 --trusted --require-certificate "$WORK/Ac-twins-trustedcert.snapshot"
# Corrupt the certificate body (4 bytes past the TCRT magic).
off=$(grep -abo TCRT "$WORK/Ac-edges-u.snapshot" | head -1 | cut -d: -f1)
if [ -n "$off" ]; then
  cp "$WORK/Ac-edges-u.snapshot" "$WORK/Ac-certbody.snapshot"
  printf '\xaa\xbb\xcc\xdd' | dd of="$WORK/Ac-certbody.snapshot" bs=1 seek=$((off+40)) count=4 conv=notrunc status=none
  verify cert-body-corrupt-require 1 --require-certificate "$WORK/Ac-certbody.snapshot"
  # Host default must not silently infer past a present-but-corrupt certificate.
  verify cert-body-corrupt-default 1 "$WORK/Ac-certbody.snapshot"
  cp "$WORK/Ac-edges-u.snapshot" "$WORK/Ac-certcount.snapshot"
  printf '\x00\x00\x00\x00' | dd of="$WORK/Ac-certcount.snapshot" bs=1 seek=$((off+8)) count=4 conv=notrunc status=none
  verify cert-count-zero-require 1 --require-certificate "$WORK/Ac-certcount.snapshot"
fi
echo "# done $(date)" | tee -a "$RES"
[ $status = 0 ] && echo "battery A-cert: $(grep -c '^\[' "$RES") cases, verdicts as expected" || echo "battery A-cert: MISMATCH (see above)"
exit $status
