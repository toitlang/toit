#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Instruction profile of an ESP32 firmware under QEMU (never touches
# hardware): installs PROGRAM as the only container, runs QEMU with the
# in_asm,exec,nochain trace into a FIFO and counts executed instructions
# per translation block; writes OUT.tb (start, instructions per execution,
# executions) and OUT.fn (instructions per function, from the ELF's
# symbols, descending).
# Usage: qprof.sh CONFIG PROGRAM.toit OUT [SECONDS]
#   CONFIG: bins/esp32-CONFIG (firmware.envelope, toit.elf)
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/call-speed-size/dev
WT=${WT:-/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a61139585de4882bc}
TOIT=$WT/build/host/sdk/bin/toit
QEMU=/home/flo/.espressif/tools/qemu-xtensa/esp_develop_9.2.2_20261109/qemu/bin/qemu-system-xtensa
NM=/home/flo/.espressif/tools/xtensa-esp-elf/esp-13.2.0_20240530/xtensa-esp-elf/bin/xtensa-esp32-elf-nm
C=$1
PROG=$2
OUT=$3
SECS=${4:-900}
format=2
case $C in f1*) format=1 ;; esac
TMP=$(mktemp -d "$A/qemu/qprof-XXXX")
TOIT_BYTECODE_FORMAT=$format "$TOIT" compile --snapshot -o "$TMP/p.snapshot" "$PROG" || exit 1
cp "$A/bins/esp32-$C/firmware.envelope" "$TMP/fw.envelope"
"$TOIT" tool firmware -e "$TMP/fw.envelope" container install prog "$TMP/p.snapshot" || exit 1
"$TOIT" tool firmware -e "$TMP/fw.envelope" extract --format image \
  --partitions "$A/qemu/partitions-qemu.csv" -o "$TMP/flash.bin" || exit 1
mkfifo "$TMP/trace"
/home/flo/work/opentoit-sandbox-artifacts/call-speed-size/tools/tbcount < "$TMP/trace" > "$OUT.tb" &
ap=$!
timeout "$SECS" "$QEMU" -nographic -machine esp32 -drive file="$TMP/flash.bin",if=mtd,format=raw \
  -serial file:"$TMP/serial.log" -monitor none -no-reboot -d in_asm,exec,nochain -D "$TMP/trace" > /dev/null 2>&1 &
qp=$!
while kill -0 $qp 2>/dev/null; do
  if grep -a -q "PROFILE done" "$TMP/serial.log" 2>/dev/null; then kill $qp; break; fi
  sleep 1
done
wait $qp 2>/dev/null
wait $ap
tr -d '\r' < "$TMP/serial.log" > "$OUT.serial"
# Functions: sorted symbol starts; each TB is attributed to the last
# symbol at or below its start.
"$NM" -n --defined-only "$A/bins/esp32-$C/toit.elf" | awk '$2 ~ /[tTwW]/ { print $1, $3 }' > "$TMP/syms"
sort "$OUT.tb" | awk -v syms="$TMP/syms" '
function hex(s) { return strtonum("0x" s) }
BEGIN { n = 0; while ((getline line < syms) > 0) { split(line, p, " "); addr[n] = hex(p[1]); name[n] = p[2]; n++ } }
{ pc = hex($1); lo = 0; hi = n - 1
  while (lo < hi) { mid = int((lo + hi + 1) / 2); if (addr[mid] <= pc) lo = mid; else hi = mid - 1 }
  total[name[lo]] += $2 * $3; all += $2 * $3 }
END { for (f in total) printf "%12d %6.2f%% %s\n", total[f], 100 * total[f] / all, f; printf "%12d total\n", all > "/dev/stderr" }' 2> "$OUT.total" | sort -rn > "$OUT.fn"
rm -rf "$TMP"
cat "$OUT.total"
head -25 "$OUT.fn"
