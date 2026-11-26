#!/usr/bin/env bash
# Builds the untrusted container images of the QEMU suite with the
# worktree's SDK (32-bit images; names sort in install order):
#   a-hello, b-fold, c-map, d-string-slice, e-exception, f-lambda: accepted
#   r1-deep-sleep: rejected (untrusted programs may not halt the VM)
#   r2-bare: no certificate (devices reject it)
#   r3-forged: the certificate of another program
#   r4-trusted: trusted-compiled format 2 (unchecked twins)
#   r5-format1: format 1 (FORMAT_2_REQUIRED)
# and the assets file with all of them. Usage: make-untrusted.sh OUT-DIR
set -euo pipefail
WT=${WT:-/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-aacd03814db0a2e22}
A=/home/flo/work/opentoit-sandbox-artifacts/rpc-task-speed
SRC=$A/progs/untrusted-src
OUT=$1
rm -rf "$OUT"
mkdir -p "$OUT"
TOIT=$WT/build/host/sdk/bin/toit
COMPILE=$WT/build/host/sdk/lib/toit/bin/toit.compile
image() {  # name source [compile-args...] -- [image-args...]
  local name=$1 src=$2
  shift 2
  local cargs=() iargs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do cargs+=("$1"); shift; done
  [ $# -gt 0 ] && shift
  iargs=("$@")
  (cd "$SRC" && "$COMPILE" "${cargs[@]}" -w "$OUT/$name.snapshot" "$SRC/$src")
  "$TOIT" tool snapshot-to-image --format=binary -m32 "${iargs[@]}" -o "$OUT/$name.image" "$OUT/$name.snapshot"
}
image a-hello hello.toit --untrusted
image b-fold fold-test.toit --untrusted
image c-map map-test.toit --untrusted
image d-string-slice string-slice-test.toit --untrusted
image e-exception exception-test.toit --untrusted
image f-lambda lambda-test.toit --untrusted
image r1-deep-sleep deep-sleep.toit --untrusted
image r2-bare hello.toit --untrusted -- --no-certificate
image x-other fold-test.toit --untrusted
image x-other-bare fold-test.toit --untrusted -- --no-certificate
other_size=$(stat -c %s "$OUT/x-other-bare.image")
{ cat "$OUT/r2-bare.image"; tail -c +"$((other_size + 1))" "$OUT/x-other.image"; } > "$OUT/r3-forged.image"
image r4-trusted hello.toit
image r5-format1 hello.toit -Xbytecode_format=1
"$TOIT" tool assets -e "$OUT/untrusted.assets" create
for img in "$OUT"/[a-r]*.image; do
  "$TOIT" tool assets -e "$OUT/untrusted.assets" add "$(basename "$img" .image)" "$img"
done
ls -l "$OUT"/*.image "$OUT/untrusted.assets"
