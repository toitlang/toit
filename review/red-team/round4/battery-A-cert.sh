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
# T2 (2026-11-26): a certificate names the primitive table of the policy it
# was made for (header version 2, policy id), and a verdict counts only for
# that policy. repro/prims.toit calls spawn and write_on_stdout, which the
# trusted policy allows and the untrusted one denies: its untrusted
# certificate must not be taken under the trusted rules and a trusted
# certificate not under the untrusted ones, also when the program is run
# (not only verified). (The in-memory verdict, V2MethodTable::runs_verified,
# is checked by tests/ctest/v2-verdict-policy-test.cc.)
compile_u "$HERE/repro/prims.toit" "$WORK/Ac-prims-u.snapshot"
"$R" --certify --trusted "$WORK/Ac-prims-u.snapshot" -o "$WORK/Ac-prims-trustedcert.snapshot" 2>/dev/null
verify prims-untrustedcert-untrusted 0 --require-certificate "$WORK/Ac-prims-u.snapshot"
verify prims-untrustedcert-trusted   1 --trusted --require-certificate "$WORK/Ac-prims-u.snapshot"
verify prims-trustedcert-trusted     0 --trusted --require-certificate "$WORK/Ac-prims-trustedcert.snapshot"
verify prims-trustedcert-untrusted   1 --require-certificate "$WORK/Ac-prims-trustedcert.snapshot"
# Refused for the policy, up front (the certificate's header), not by chance.
for name in prims-untrustedcert-trusted prims-trustedcert-untrusted; do
  grep -q "certificate made for another primitive policy" "$WORK/$name.err" \
    || { echo "[$name] MISMATCH: not refused for its policy" | tee -a "$RES"; status=1; }
done
"$R" --untrusted "$WORK/Ac-prims-trustedcert.snapshot" >/dev/null 2>"$WORK/prims-trustedcert-run.err"; got=$?
tag="OK"; { [ "$got" = 0 ] || ! grep -q "another primitive policy" "$WORK/prims-trustedcert-run.err"; } && { tag="MISMATCH"; status=1; }
printf '[%s] exit=%s want=%s %s  %s\n' prims-trustedcert-run-untrusted "$got" 1 "$tag" \
  "$(grep -oiE 'shipped certificate[^\"]*' "$WORK/prims-trustedcert-run.err" | head -1)" | tee -a "$RES"
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
