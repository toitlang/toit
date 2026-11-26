#!/usr/bin/env bash
# In-VM verifier memory with the shipped certificate on the 32-bit host
# (or BUILD=build/host): rebuilds the VM, then verifies the snapshots in
# device-cert/ram (made by verified/vmverify/tests/measure_shipped.sh) with
# TOIT_VERIFY_MEM=1 TOIT_VERIFY_TIME=1. --untrusted: the untrusted rules.
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a9365a74954333c15
BUILD="${BUILD:-build/host32}"
cd "$WT"
ninja -C "$BUILD" build_tools > /home/flo/work/opentoit-sandbox-artifacts/device-cert/ram-build.log 2>&1 || { tail -20 /home/flo/work/opentoit-sandbox-artifacts/device-cert/ram-build.log; exit 1; }
RULES=--trusted
[ "${1:-}" = --untrusted ] && RULES=
cd /home/flo/work/opentoit-sandbox-artifacts/device-cert/ram
for f in heat-pump-test run-image toit.run; do
  echo "== $f"
  TOIT_VERIFY_MEM=1 TOIT_VERIFY_TIME=1 "$WT/$BUILD/sdk/lib/toit/bin/toit.run" --verify $RULES --require-certificate "$f.snapshot" 2>&1 \
    | grep -E "vmverify mem|verifier:"
done
