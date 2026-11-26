#!/usr/bin/env bash
# Instructions of install-time verification with the shipped certificate
# (untrusted rules, no inference: what a device runs), x86-64 host:
# callgrind inside toit_vmverify_verify (conversion, heap check, proven
# certificate check) and inside V2MethodTable::compute (the C++ method
# table), on the format-2 snapshots of images/.
# Usage: verify-ir.sh [TOIT.RUN]
A=/home/flo/work/opentoit-sandbox-artifacts/esp32-build
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a11f10728217c321a
BIN=${1:-$WT/build/host/sdk/lib/toit/bin/toit.run}
OUT=$A/verify-ir
mkdir -p "$OUT"
for s in "$A"/images/*.snapshot; do
  n=$(basename "$s" .snapshot)
  (
    info=$(TOIT_VERIFY_TIME=1 "$BIN" --verify --require-certificate "$s" 2>&1 | grep '^verifier:' | head -1)
    valgrind --tool=callgrind --toggle-collect=toit_vmverify_verify --callgrind-out-file="$OUT/v.$n" \
      "$BIN" --verify --require-certificate "$s" > /dev/null 2>&1
    valgrind --tool=callgrind "--toggle-collect=toit::V2MethodTable::compute*" --callgrind-out-file="$OUT/t.$n" \
      "$BIN" --verify --require-certificate "$s" > /dev/null 2>&1
    v=$(awk '/^summary:/ { print $2 }' "$OUT/v.$n")
    t=$(awk '/^summary:/ { print $2 }' "$OUT/t.$n")
    echo "$n verify_ir=$v table_ir=$t :: $info"
  ) &
done | sort > "$OUT/results.txt"
wait
cat "$OUT/results.txt"
