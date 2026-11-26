#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
#
# Builds a test envelope from a firmware build in bins/.
# Usage: mkenv.sh TARGET CONFIG KIND   -> env/TARGET-CONFIG-KIND.envelope
#   KIND: suite (the device suite with provider, thrower, spinner and the
#         untrusted images), bench (hwbench), install (hwinstall with the
#         untrusted images), spin (a 60 s busy loop, watchdog check).
set -euo pipefail
WT=${WT:-/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-aa2e69417f86ec26e}
A=/home/flo/work/opentoit-sandbox-artifacts/oom-confirm
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
  otaa|otab|otabnv)
    # s3-ota-soak: the OTA test's firmware A (installs progs/ota/ota.assets,
    # then updates) and firmware B (validates; otabnv: never validates).
    src=otaa
    [ "$KIND" = otab ] && src=otab
    [ "$KIND" = otabnv ] && src=otab-nv
    (cd "$A/progs/ota" && TOIT_BYTECODE_FORMAT=$FORMAT "$TOIT" compile --snapshot -o "$D/$src.snapshot" "$A/progs/ota/$src.toit")
    cp "$IN" "$OUT"
    # Firmware B carries the same assets (unused) as A, so that both map
    # about the same number of flash MMU pages: the programs partition is
    # mapped right after the firmware, and the images installed in it are
    # only valid at the address they were installed at.
    "$TOIT" tool firmware -e "$OUT" container install --assets "$A/progs/ota/ota.assets" "$src" "$D/$src.snapshot"
    ;;
  soak)
    # s3-ota-soak: the soak workload (progs/soak), with its untrusted
    # worker images as assets (scripts/make-soak-images.sh); the controller
    # provides the service itself.
    (cd "$A/progs/soak" && TOIT_BYTECODE_FORMAT=$FORMAT "$TOIT" compile --snapshot -o "$D/soak.snapshot" "$A/progs/soak/soak.toit")
    cp "$IN" "$OUT"
    "$TOIT" tool firmware -e "$OUT" container install --assets "$A/progs/soak/soak-f$FORMAT.assets" soak "$D/soak.snapshot"
    ;;
  soak1|soak2|soakd|soakd2|soakl|soakl2)
    # esp32-final: the soak workload with one / two workers (progs/soak1,
    # progs/soak2), the same assets.
    (cd "$A/progs/$KIND" && TOIT_BYTECODE_FORMAT=$FORMAT "$TOIT" compile --snapshot -o "$D/$KIND.snapshot" "$A/progs/$KIND/soak.toit")
    cp "$IN" "$OUT"
    "$TOIT" tool firmware -e "$OUT" container install --assets "$A/progs/soak/soak-f$FORMAT.assets" soak "$D/$KIND.snapshot"
    ;;
  soakl3|soakh)
    # oom-confirm: over capacity: three workers (soakl3); one worker and a
    # container that allocates until refused (soakh, assets with u-hog).
    assets=$A/progs/soak/soak-f$FORMAT.assets
    [ "$KIND" = soakh ] && assets=$A/progs/soak/soak-f2-hog.assets
    (cd "$A/progs/$KIND" && TOIT_BYTECODE_FORMAT=$FORMAT "$TOIT" compile --snapshot -o "$D/$KIND.snapshot" "$A/progs/$KIND/soak.toit")
    cp "$IN" "$OUT"
    "$TOIT" tool firmware -e "$OUT" container install --assets "$assets" soak "$D/$KIND.snapshot"
    ;;
  stuck)
    # esp32-final: the stuck-worker reproduction (progs/stuck/stuck-dev.toit:
    # three trusted workers with a 24 KB heap limit, RPC under memory
    # exhaustion).
    (cd "$A/progs/stuck" && TOIT_BYTECODE_FORMAT=$FORMAT "$TOIT" compile --snapshot -o "$D/stuck.snapshot" "$A/progs/stuck/stuck-dev.toit")
    cp "$IN" "$OUT"
    "$TOIT" tool firmware -e "$OUT" container install stuck "$D/stuck.snapshot"
    ;;
  memprobe)
    # esp32-final: per-worker memory (progs/memprobe), assets by format.
    (cd "$A/progs/memprobe" && TOIT_BYTECODE_FORMAT=$FORMAT "$TOIT" compile --snapshot -o "$D/memprobe.snapshot" "$A/progs/memprobe/memprobe.toit")
    cp "$IN" "$OUT"
    "$TOIT" tool firmware -e "$OUT" container install --assets "$A/progs/memprobe/memprobe-f$FORMAT.assets" memprobe "$D/memprobe.snapshot"
    ;;
  otabep)
    # esp32-final: firmware B of the verification-epoch scenario
    # (progs/ota/otab-epoch.toit; same assets as A).
    (cd "$A/progs/ota" && TOIT_BYTECODE_FORMAT=$FORMAT "$TOIT" compile --snapshot -o "$D/otab-epoch.snapshot" "$A/progs/ota/otab-epoch.toit")
    cp "$IN" "$OUT"
    "$TOIT" tool firmware -e "$OUT" container install --assets "$A/progs/ota/ota.assets" otab "$D/otab-epoch.snapshot"
    ;;
  churn)
    # s3-ota-soak: container start churn (progs/churn).
    (cd "$A/progs/churn" && TOIT_BYTECODE_FORMAT=$FORMAT "$TOIT" compile --snapshot -o "$D/churn.snapshot" "$A/progs/churn/churn.toit")
    cp "$IN" "$OUT"
    "$TOIT" tool firmware -e "$OUT" container install --assets "$A/progs/churn/churn-f$FORMAT.assets" churn "$D/churn.snapshot"
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
  install-old)
    # measure-3: the untrusted images of install-speed (its SDK), to
    # separate the program from the firmware in the verification time.
    snap hwinstall
    cp "$IN" "$OUT"
    "$TOIT" tool firmware -e "$OUT" container install --assets "$A/progs/untrusted-old/installer.assets" hwinstall "$D/hwinstall.snapshot"
    ;;
  drverr)
    # measure-3: driver calls ESP-IDF rejects (TOIT_SILENT_IDF_CHECKS check).
    snap drverr
    cp "$IN" "$OUT"
    "$TOIT" tool firmware -e "$OUT" container install drverr "$D/drverr.snapshot"
    ;;
  spin)
    snap hwspin
    cp "$IN" "$OUT"
    "$TOIT" tool firmware -e "$OUT" container install hwspin "$D/hwspin.snapshot"
    ;;
  *) echo "unknown kind $KIND" >&2; exit 2 ;;
esac
echo "$OUT"
