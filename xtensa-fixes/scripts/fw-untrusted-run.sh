#!/usr/bin/env bash
# Builds a QEMU flash image from an ESP32 firmware envelope (with the Rust
# verified core) plus the trusted installer container, whose assets are the
# untrusted test images (make-images.sh), and runs it under Espressif's
# QEMU until the installer reports. Compares the exit codes with the host.
# Usage: fw-untrusted-run.sh <worktree> <firmware-build-dir> <name> <seconds> <image>...
set -uo pipefail
WT=$1
B=$2
NAME=$3
SECS=$4
shift 4
ROOT=/home/flo/work/opentoit-sandbox-artifacts/xtensa-fixes/fw-qemu
OUT=$ROOT/run-$NAME
rm -rf "$OUT"
mkdir -p "$OUT"
TOIT=$WT/build/host/sdk/bin/toit
QEMU=$HOME/.espressif/tools/qemu-xtensa/esp_develop_9.2.2_20261109/qemu/bin/qemu-system-xtensa
"$TOIT" tool assets -e "$OUT/tests.assets" create
for img in "$@"; do
  "$TOIT" tool assets -e "$OUT/tests.assets" add "$(basename "$img" .image)" "$img"
done
"$WT/build/host/sdk/lib/toit/bin/toit.compile" -w "$OUT/installer.snapshot" "$ROOT/installer/installer.toit" || exit 1
"$TOIT" tool firmware -e "$B/firmware.envelope" container install --assets "$OUT/tests.assets" \
  -o "$OUT/fw.envelope" installer "$OUT/installer.snapshot" || exit 1
"$TOIT" tool firmware -e "$OUT/fw.envelope" extract --format image \
  --partitions "$ROOT/partitions-qemu.csv" -o "$OUT/flash.bin" || exit 1
ls -l "$OUT/flash.bin"
timeout "$SECS" "$QEMU" -nographic -machine esp32 ${QEMU_EXTRA:-} -drive file="$OUT/flash.bin",if=mtd,format=raw \
  -serial file:"$OUT/serial.log" -monitor none -no-reboot > "$OUT/qemu.log" 2>&1 &
qp=$!
while kill -0 $qp 2>/dev/null; do
  if grep -q 'XTENSA-CORE done\|Guru Meditation\|abort()' "$OUT/serial.log" 2>/dev/null; then
    sleep 1; kill $qp 2>/dev/null; break
  fi
  sleep 2
done
wait $qp 2>/dev/null
tr -d '\r' < "$OUT/serial.log" > "$OUT/serial.txt"
grep -E 'XTENSA-CORE|Guru|abort|ERROR|EXCEPTION|panic' "$OUT/serial.txt" | head -60
