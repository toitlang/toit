#!/usr/bin/env bash
# The 12 untrusted suite tests of the Xtensa investigation under QEMU on a
# firmware build: all in one boot (TAG-all) and each alone after a fresh
# boot (TAG-<test>), in parallel. Usage: fw-qemu-suite.sh <firmware-build-dir> <tag> [seconds]
set -uo pipefail
B=$1
TAG=$2
SECS=${3:-2400}
A=/home/flo/work/opentoit-sandbox-artifacts/esp32-build
S=$A/scripts/fw-untrusted-run.sh
TESTS="byte-array constructor-super exception fold lambda non-local-branch-types string-slice format map list deque is-as-many"
imgs=()
for t in $TESTS; do imgs+=("$A/images/$t-test.image"); done
pids=()
bash "$S" "$B" "$TAG-all" "$SECS" "${imgs[@]}" > "$A/fw-qemu/$TAG-all.out" 2>&1 &
pids+=($!)
for t in $TESTS; do
  bash "$S" "$B" "$TAG-$t" "$SECS" "$A/images/$t-test.image" > "$A/fw-qemu/$TAG-$t.out" 2>&1 &
  pids+=($!)
done
for p in "${pids[@]}"; do wait "$p"; done
echo "== all in one boot"
grep -h -E 'XTENSA-CORE|install-trace|dead|Guru' "$A/fw-qemu/run-$TAG-all/serial.txt"
echo "== alone"
for t in $TESTS; do
  grep -h -E 'XTENSA-CORE .* (exit|install-failed)|install-trace|dead|Guru' "$A/fw-qemu/run-$TAG-$t/serial.txt" | sed "s/^/$t: /"
done
