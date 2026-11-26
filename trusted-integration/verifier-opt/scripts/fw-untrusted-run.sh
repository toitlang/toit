#!/usr/bin/env bash
# Builds a QEMU flash image from an ESP32 firmware envelope (with the Rust
# verified core) plus the trusted installer container, whose assets are the
# untrusted test images (make-images.sh), and runs it under Espressif's
# QEMU until the installer reports (as xtensa-fixes/scripts, other paths).
# Never touches hardware.
# Usage: fw-untrusted-run.sh <firmware-build-dir> <name> <seconds> <image>...
#   QEMU_EXTRA: extra QEMU arguments (e.g. "-icount shift=0").
set -uo pipefail
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a60156e1f881a93e7
B=$1
NAME=$2
SECS=$3
shift 3
ROOT=/home/flo/work/opentoit-sandbox-artifacts/esp32-build/fw-qemu
OUTROOT=/home/flo/work/opentoit-sandbox-artifacts/trusted-integration/verifier-opt/fw-qemu
OUT=$OUTROOT/run-$NAME
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
start=$(date +%s)
timeout "$SECS" "$QEMU" -nographic -machine esp32 ${QEMU_EXTRA:-} -drive file="$OUT/flash.bin",if=mtd,format=raw \
  -serial file:"$OUT/serial.log" -monitor none -no-reboot > "$OUT/qemu.log" 2>&1 &
qp=$!
while kill -0 $qp 2>/dev/null; do
  if grep -q 'XTENSA-CORE done\|Guru Meditation\|abort()\|Potential dead' "$OUT/serial.log" 2>/dev/null; then
    sleep 2; kill $qp 2>/dev/null; break
  fi
  sleep 2
done
wait $qp 2>/dev/null
end=$(date +%s)
tr -d '\r' < "$OUT/serial.log" > "$OUT/serial.txt"
echo "wall $((end - start)) s" > "$OUT/wall.txt"
grep -E 'XTENSA-CORE|install-trace|Guru|abort|EXCEPTION|panic|dead-lock|deadlock|verifier:' "$OUT/serial.txt" | head -80
