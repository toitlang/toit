#!/usr/bin/env bash
# Runs an idf-app build under Espressif's QEMU (esp32 machine), no hardware.
# -icount shift=0: virtual time follows executed instructions, so CCOUNT
# deltas compare instruction counts (not real cycles: no cache/flash
# wait-state or pipeline model).
# Usage: qemu-run.sh <build-dir-name>
set -euo pipefail
B=$1
ROOT=/home/flo/work/opentoit-sandbox-artifacts/xtensa-rust
export IDF_PATH=/home/flo/work/opentoit-sandbox/third_party/esp-idf
export IDF_TOOLS_PATH=$HOME/.espressif
# shellcheck disable=SC1091
. "$IDF_PATH/export.sh" > /dev/null 2>&1
QEMU=$HOME/.espressif/tools/qemu-xtensa/esp_develop_9.2.2_20261109/qemu/bin/qemu-system-xtensa
cd "$ROOT/idf-app/$B"
esptool.py --chip esp32 merge_bin --fill-flash-size 4MB -o flash.bin @flash_args > merge.log 2>&1
timeout 120 "$QEMU" -nographic -machine esp32 -icount shift=0 \
  -drive file=flash.bin,if=mtd,format=raw -serial mon:stdio -no-reboot > qemu.log 2>&1 &
pid=$!
for _ in $(seq 1 120); do
  if grep -q 'xtensa-rust-eval done\|abort()\|Guru Meditation\|rust panic' qemu.log; then break; fi
  sleep 1
done
kill $pid 2>/dev/null || true
wait $pid 2>/dev/null || true
sed -n '/xtensa-rust-eval start/,$p' qemu.log | tr -d '\r' | tee qemu-result.txt
