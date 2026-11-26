#!/usr/bin/env bash
# Runs given untrusted test images alone (fresh boot each, in parallel)
# under QEMU with -icount: with shift=0 one guest instruction is one ns of
# virtual time, so the "[install-trace] ... N us" of a traced firmware is
# kilo-instructions of the Xtensa core (verification of one install).
# With a larger shift the guest runs slower in virtual time (2^shift ns per
# instruction): used to make a verification exceed the scheduler's 10 s
# dead-lock limit. Usage: fw-qemu-icount.sh <build-dir> <tag> <shift> <test>...
set -uo pipefail
B=$1
TAG=$2
SHIFT=$3
shift 3
A=/home/flo/work/opentoit-sandbox-artifacts/esp32-build
S=$A/scripts/fw-untrusted-run.sh
pids=()
for t in "$@"; do
  QEMU_EXTRA="-icount shift=$SHIFT" bash "$S" "$B" "$TAG-$t" 7200 "$A/images/$t-test.image" > "$A/fw-qemu/$TAG-$t.out" 2>&1 &
  pids+=($!)
done
for p in "${pids[@]}"; do wait "$p"; done
for t in "$@"; do
  grep -h -E 'XTENSA-CORE .* (exit|install-failed)|install-trace|dead|Guru' "$A/fw-qemu/run-$TAG-$t/serial.txt" | sed "s/^/$t: /"
  cat "$A/fw-qemu/run-$TAG-$t/wall.txt" | sed "s/^/$t: /"
done
