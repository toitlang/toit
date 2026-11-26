#!/usr/bin/env bash
# Size of the device Rust library by component (device_size.sh) for the
# feature sets of the size diet, at opt-levels 3, s and z.
# Usage: libsizes.sh [VERIFIED-DIR] [LABEL FEATURES]...
#   VERIFIED-DIR: a verified/ directory (default: the worktree's), e.g. a
#   patched copy. Default variants: before (infer + checked loop), noinfer
#   (checked loop only), device (neither).
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a9365a74954333c15
VERIFIED="${1:-$WT/verified}"
shift || true
VARIANTS=("before device-runtime,infer,checked-loop" "noinfer device-runtime,checked-loop" "device device-runtime")
if [ $# -gt 0 ]; then VARIANTS=("$@"); fi
OUT=/home/flo/work/opentoit-sandbox-artifacts/device-cert/device-size
for v in "${VARIANTS[@]}"; do
  set -- $v
  for o in 3 s z; do
    echo "=== $1 opt $o ($2)"
    TOIT="$WT/build/host/sdk/bin/toit" DEVICE_SIZE_FEATURES="$2" DEVICE_SIZE_SUFFIX="-$1" \
      "$VERIFIED/vmverify/tests/device_size.sh" "$o" "$OUT" 2>&1 | tail -20
  done
done
