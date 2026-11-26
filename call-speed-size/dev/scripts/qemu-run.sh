#!/usr/bin/env bash
# Runs a firmware envelope under Espressif's QEMU (never touches hardware):
# extracts a flash image with the QEMU partition table and boots it until
# a stop pattern appears in the serial output or the time runs out.
# Usage: qemu-run.sh TARGET ENVELOPE OUT-DIR SECONDS [STOP-REGEX]
#   TARGET: esp32 or esp32c6. QEMU_EXTRA: extra QEMU arguments
#   (e.g. "-icount shift=0").
set -uo pipefail
WT=${WT:-/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a61139585de4882bc}
A=/home/flo/work/opentoit-sandbox-artifacts/call-speed-size/dev
TARGET=$1
ENV=$2
OUT=$3
SECS=$4
STOP=${5:-SUITE done|Guru Meditation|abort\(\)|Potential dead}
rm -rf "$OUT"
mkdir -p "$OUT"
TOIT=$WT/build/host/sdk/bin/toit
case $TARGET in
  esp32)
    QEMU=$HOME/.espressif/tools/qemu-xtensa/esp_develop_9.2.2_20261109/qemu/bin/qemu-system-xtensa
    MACHINE=esp32
    PARTS=$A/qemu/partitions-qemu.csv
    ;;
  esp32c6)
    QEMU=$(ls -d "$HOME"/.espressif/tools/qemu-riscv32/*/qemu/bin | head -1)/qemu-system-riscv32
    MACHINE=esp32c6
    PARTS=$A/qemu/partitions-qemu.csv
    ;;
  *) echo "unknown target $TARGET"; exit 2 ;;
esac
"$TOIT" tool firmware -e "$ENV" extract --format image --partitions "$PARTS" -o "$OUT/flash.bin" || exit 1
start=$(date +%s)
# shellcheck disable=SC2086
timeout "$SECS" "$QEMU" -nographic -machine "$MACHINE" ${QEMU_EXTRA:-} \
  -drive file="$OUT/flash.bin",if=mtd,format=raw \
  -serial file:"$OUT/serial.log" -monitor none -no-reboot > "$OUT/qemu.log" 2>&1 &
qp=$!
while kill -0 $qp 2>/dev/null; do
  if grep -E -q "$STOP" "$OUT/serial.log" 2>/dev/null; then
    sleep 2; kill $qp 2>/dev/null; break
  fi
  sleep 1
done
wait $qp 2>/dev/null
end=$(date +%s)
tr -d '\r' < "$OUT/serial.log" > "$OUT/serial.txt"
echo "wall $((end - start)) s" > "$OUT/wall.txt"
