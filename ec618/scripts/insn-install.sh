#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Instructions of three untrusted installs (a-hello, c-map, e-exception) on a
# format-2 harness build: the program with the installs against the same
# program with the untrusted assets but no installs (bench-empty).
# Usage: insn-install.sh CONFIG-NAME BUILD-DIR
set -euo pipefail
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a6c88832d90141abe
A=/home/flo/work/opentoit-sandbox-artifacts/ec618
NAME=$1
B=$2
TOIT=$WT/build/host/sdk/bin/toit
OUT=$A/qemu/install-$NAME
mkdir -p "$OUT"
PLUGIN=$A/qemu/build/tests/tcg/plugins/libinsn.so
for p in install empty; do
  TOIT_BYTECODE_FORMAT=2 "$TOIT" compile --snapshot -o "$OUT/$p.snapshot" "$A/qemu/progs/bench-$p.toit"
  cp "$WT/$B/firmware.envelope" "$OUT/$p.envelope"
  "$TOIT" tool firmware -e "$OUT/$p.envelope" container install --assets "$A/qemu/untrusted/untrusted.assets" bench "$OUT/$p.snapshot"
  bash "$A/scripts/qrun.sh" "$OUT/run-$p.txt" "$B" "$OUT/$p.envelope" -plugin "$PLUGIN" -d plugin > /dev/null
  echo "$p $(sed -n 's/^total insns: //p' "$OUT/run-$p.txt")"
  grep -E '^INSTALL|verifier' "$OUT/run-$p.txt" || true
done
