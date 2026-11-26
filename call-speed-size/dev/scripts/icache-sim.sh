#!/usr/bin/env bash
# Instruction-cache estimate for the classic ESP32 under QEMU (which does
# not model the flash cache): runs an envelope with QEMU's in_asm+exec
# trace (TB start addresses, without chaining) into a FIFO and simulates
# the flash cache for the instruction fetches only: 32 KB, 2-way LRU,
# 32-byte lines (per CPU). Data fetches from flash (rodata, the Toit
# program images with their bytecodes) share the cache on the ESP32 and
# are not counted, so the misses are a lower bound.
# Prints executed instructions by region (ROM, IRAM, flash) and the flash
# lines fetched and missed. Usage: icache-sim.sh ENVELOPE OUT-FILE SECONDS
set -uo pipefail
WT=${WT:-/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a61139585de4882bc}
A=/home/flo/work/opentoit-sandbox-artifacts/call-speed-size/dev
ENV=$1
OUT=$2
SECS=$3
QEMU=$HOME/.espressif/tools/qemu-xtensa/esp_develop_9.2.2_20261109/qemu/bin/qemu-system-xtensa
TMP=$(mktemp -d "$A/qemu/icache-XXXX")
"$WT/build/host/sdk/bin/toit" tool firmware -e "$ENV" extract --format image \
  --partitions "$A/qemu/partitions-qemu.csv" -o "$TMP/flash.bin" || exit 1
mkfifo "$TMP/trace"
awk '
function hex(s) { return strtonum("0x" s) }
BEGIN { WAYS = 2; SETS = 512; LINE = 32 }
/^IN:/ { inblock = 1; first = -1; next }
inblock && /^0x[0-9a-f]+:/ {
  a = hex(substr($1, 3, length($1) - 3)); if (first < 0) first = a; last = a; n++
  next
}
inblock && /^$/ { if (first >= 0) { size[first] = last + 3 - first; count[first] = n } inblock = 0; n = 0; next }
/^Trace / {
  split($4, f, "/"); pc = hex(f[2])
  ins = count[pc]; if (ins == 0) ins = 1
  if (pc < 1073741824 + 458752) rom += ins          # 0x40000000..0x40070000 ROM
  else if (pc < 1074528256) iram += ins             # ..0x400C0000 IRAM
  else if (pc < 1086324736) {                        # ..0x40C00000 flash (IROM)
    flash += ins
    s = size[pc]; if (s <= 0) s = 3
    for (l = int(pc / LINE); l <= int((pc + s - 1) / LINE); l++) {
      set = l % SETS; accesses++
      if (w0[set] == l) { lru[set] = 1 }
      else if (w1[set] == l) { lru[set] = 0 }
      else { misses++; if (lru[set] == 0) { w0[set] = l; lru[set] = 1 } else { w1[set] = l; lru[set] = 0 }; if (!(l in seen)) { seen[l] = 1; distinct++ } }
    }
  } else other += ins
}
END {
  printf "instructions rom %d iram %d flash %d other %d\n", rom, iram, flash, other
  printf "flash lines fetched %d missed %d distinct %d\n", accesses, misses, distinct
}' "$TMP/trace" > "$OUT" &
ap=$!
timeout "$SECS" "$QEMU" -nographic -machine esp32 -drive file="$TMP/flash.bin",if=mtd,format=raw \
  -serial file:"$TMP/serial.log" -monitor none -no-reboot -d in_asm,exec,nochain -D "$TMP/trace" > /dev/null 2>&1 &
qp=$!
while kill -0 $qp 2>/dev/null; do
  if grep -a -q "ICACHE done" "$TMP/serial.log" 2>/dev/null; then kill $qp; break; fi
  sleep 1
done
wait $qp 2>/dev/null
wait $ap
tr -d '\r' < "$TMP/serial.log" > "$OUT.serial"
rm -rf "$TMP"
cat "$OUT"
