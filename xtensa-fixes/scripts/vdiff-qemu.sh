#!/usr/bin/env bash
# Runs the verifier differential under Espressif's QEMU (esp32 machine) in
# JOBS parallel instances, each on its own copy of the flash image with its
# range of mutants in the `cfg` partition (0x310000), and compares every
# verdict line with the 32-bit x86 host runner on the same mutants.
# Usage: vdiff-qemu.sh <build-name> <seed> <mutants-per-program> <jobs> [timeout-s]
set -uo pipefail
NAME=$1
SEED=$2
TOTAL=$3
JOBS=$4
TMO=${5:-3600}
ROOT=/home/flo/work/opentoit-sandbox-artifacts/xtensa-fixes/qemu
QEMU=$HOME/.espressif/tools/qemu-xtensa/esp_develop_9.2.2_20261109/qemu/bin/qemu-system-xtensa
B=$ROOT/idf-vdiff/build-$NAME
OUT=$ROOT/runs/$NAME-seed$SEED-n$TOTAL
rm -rf "$OUT"
mkdir -p "$OUT"
le32() { printf "\\x$(printf %02x $(($1 & 255)))\\x$(printf %02x $((($1 >> 8) & 255)))\\x$(printf %02x $((($1 >> 16) & 255)))\\x$(printf %02x $((($1 >> 24) & 255)))"; }
PER=$(( (TOTAL + JOBS - 1) / JOBS ))
pids=()
for j in $(seq 0 $((JOBS - 1))); do
  first=$((j * PER))
  count=$PER
  [ $((first + count)) -gt "$TOTAL" ] && count=$((TOTAL - first))
  [ "$count" -le 0 ] && continue
  cp "$B/flash.bin" "$OUT/flash-$j.bin"
  { printf 'VDIF'; le32 "$SEED"; le32 0; le32 "$first"; le32 "$count"; le32 31; } > "$OUT/cfg-$j.bin"
  dd if="$OUT/cfg-$j.bin" of="$OUT/flash-$j.bin" bs=1 seek=$((0x310000)) conv=notrunc status=none
  (
    timeout "$TMO" "$QEMU" -nographic -machine esp32 -drive file="$OUT/flash-$j.bin",if=mtd,format=raw \
      -serial file:"$OUT/serial-$j.log" -monitor none -no-reboot > "$OUT/qemu-$j.log" 2>&1 &
    qp=$!
    while kill -0 $qp 2>/dev/null; do
      if grep -q 'VDIFF done\|RUST PANIC\|abort()\|Guru Meditation' "$OUT/serial-$j.log" 2>/dev/null; then
        kill $qp 2>/dev/null; break
      fi
      sleep 2
    done
    wait $qp 2>/dev/null
  ) &
  pids+=($!)
done
for p in "${pids[@]}"; do wait "$p"; done
cat "$OUT"/serial-*.log | tr -d '\r' | grep '^V ' | sort -k2,2n -k3,3n > "$OUT/device.txt"
grep -h 'VDIFF\|PANIC\|Guru\|abort' "$OUT"/serial-*.log | tr -d '\r' > "$OUT/markers.txt"
cd "$ROOT/tables"
"$ROOT/vdiff/target-host/i686-unknown-linux-gnu/release/vdiff-host" run "$SEED" 0 "$TOTAL" \
  hello.tables lambda-test.tables exception-test.tables class-id-test.tables task-test.tables \
  | sort -k2,2n -k3,3n > "$OUT/host.txt"
echo "device lines $(wc -l < "$OUT/device.txt"), host lines $(wc -l < "$OUT/host.txt")"
echo "differences: $(diff "$OUT/host.txt" "$OUT/device.txt" | grep -c '^[<>]')"
awk '{ c[$4]++ } END { for (k in c) printf "code %s: %d\n", k, c[k] }' "$OUT/device.txt" | sort
cat "$OUT/markers.txt"
