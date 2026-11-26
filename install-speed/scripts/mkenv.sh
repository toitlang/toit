#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
#
# Builds a test envelope from a firmware build in bins/.
# Usage: mkenv.sh TARGET CONFIG KIND   -> env/TARGET-CONFIG-KIND.envelope
#   KIND: suite (the device suite with provider, thrower, spinner and the
#         untrusted images), bench (hwbench), install (hwinstall with the
#         untrusted images), spin (a 60 s busy loop, watchdog check).
set -euo pipefail
WT=${WT:-/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a5e90db27d1fea9b4}
A=/home/flo/work/opentoit-sandbox-artifacts/install-speed
TOIT=$WT/build/host/sdk/bin/toit
TARGET=$1
C=$2
KIND=$3
FORMAT=2
case $C in f1*) FORMAT=1 ;; esac
IN=$A/bins/$TARGET-$C/firmware.envelope
mkdir -p "$A/env"
OUT=$A/env/$TARGET-$C-$KIND.envelope
D=$A/env/snap-f$FORMAT
mkdir -p "$D"
snap() {  # name
  TOIT_BYTECODE_FORMAT=$FORMAT "$TOIT" compile --snapshot -o "$D/$1.snapshot" "$A/progs/suite/$1.toit"
}
case $KIND in
  suite)
    bash "$A/scripts/suite-envelope.sh" "$IN" "$OUT" "$FORMAT"
    ;;
  bench)
    snap hwbench
    cp "$IN" "$OUT"
    "$TOIT" tool firmware -e "$OUT" container install hwbench "$D/hwbench.snapshot"
    ;;
  bench-ramtable)
    # The container's method table built in RAM (no table literal in flash).
    (cd "$A/progs/suite" && TOIT_BYTECODE_FORMAT=$FORMAT "$WT/build/host/sdk/lib/toit/bin/toit.compile" -Xv2_table_literal=false -w "$D/hwbench-ramtable.snapshot" hwbench.toit)
    cp "$IN" "$OUT"
    "$TOIT" tool firmware -e "$OUT" container install hwbench "$D/hwbench-ramtable.snapshot"
    ;;
  perf)
    # The RPC/json component benchmarks with the provider container.
    snap perfbench
    snap provider
    cp "$IN" "$OUT"
    "$TOIT" tool firmware -e "$OUT" container install perfbench "$D/perfbench.snapshot"
    "$TOIT" tool firmware -e "$OUT" container install --trigger none provider "$D/provider.snapshot"
    ;;
  install)
    snap hwinstall
    cp "$IN" "$OUT"
    "$TOIT" tool firmware -e "$OUT" container install --assets "$A/progs/untrusted/installer.assets" hwinstall "$D/hwinstall.snapshot"
    ;;
  ota|ota-after)
    name=hwota
    [ "$KIND" = ota-after ] && name=hwota-after
    snap $name
    cp "$IN" "$OUT"
    "$TOIT" tool firmware -e "$OUT" container install $name "$D/$name.snapshot"
    ;;
  rx)
    snap hwrx
    cp "$IN" "$OUT"
    "$TOIT" tool firmware -e "$OUT" container install hwrx "$D/hwrx.snapshot"
    ;;
  uncaught)
    # A critical container whose spawned process dies with an uncaught
    # exception (the scheduler exit-code fix, 9c3ff7ea).
    snap uncaught
    cp "$IN" "$OUT"
    "$TOIT" tool firmware -e "$OUT" container install --critical uncaught "$D/uncaught.snapshot"
    ;;
  spin)
    snap hwspin
    cp "$IN" "$OUT"
    "$TOIT" tool firmware -e "$OUT" container install hwspin "$D/hwspin.snapshot"
    ;;
  *) echo "unknown kind $KIND" >&2; exit 2 ;;
esac
echo "$OUT"
