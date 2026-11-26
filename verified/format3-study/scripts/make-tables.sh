#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Compiles the study's programs as format-2 snapshots with the worktree's
# host SDK and saves the verifier's input tables of each
# (`toit.run --verify --emit-canonical=X.tables`), for the static
# statistics and the certificate prototypes (f3study).
#   untrusted: a-hello, c-map, g-big (install-speed's programs)
#   trusted (unchecked twins, as the device's first-party containers):
#     opbench, taskbench, esp32-system (system/extensions/esp32/boot.toit)
# Output: data/<name>.snapshot, data/<name>.tables
set -uo pipefail
WT=${WT:-/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a8868e80a23e89460}
A=/home/flo/work/opentoit-sandbox-artifacts/format3-study
BIN=${BIN:-$WT/build/host/sdk/lib/toit/bin}
export TMPDIR=$WT/build/tmp
D=$A/data
mkdir -p "$D"
compile() {  # name source [args...]
  local name=$1 src=$2
  shift 2
  (cd "$(dirname "$src")" && "$BIN/toit.compile" "$@" -w "$D/$name.snapshot" "$src") || { echo "compile $name failed"; return 1; }
  "$BIN/toit.run" --verify --emit-canonical="$D/$name.tables" "$D/$name.snapshot" > "$D/$name.emit.log" 2>&1
  ls -l "$D/$name.tables" | awk '{print $5, $9}'
}
U=$A/progs/untrusted-src
compile a-hello "$U/hello.toit" --untrusted
compile c-map "$U/map-test.toit" --untrusted
compile g-big "$U/big.toit" --untrusted
TOIT_V2_UNCHECKED=1 compile opbench "$A/progs/host/opbench.toit" -Xbytecode_format=2
TOIT_V2_UNCHECKED=1 compile taskbench "$A/progs/host/taskbench.toit" -Xbytecode_format=2
TOIT_V2_UNCHECKED=1 compile esp32-system "$WT/system/extensions/esp32/boot.toit" -Xbytecode_format=2
