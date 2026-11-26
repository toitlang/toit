#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# PC-sample profile of a perfbench log (TOIT_HW_PERF firmware, [hw-pc]
# lines): the samples of the runs of the benchmarks matching a regex,
# summed over cores and runs, mapped to functions of the firmware ELF,
# with the memory each function is in. Also a per-region summary.
# Usage: pc-profile.sh LOG-NAME BIN-NAME BENCH-REGEX [TOP]
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/size-2
T=$HOME/.espressif/tools
LOG=$A/logs/$1.txt
ELF=$A/bins/$2/toit.elf
RE=$3
TOP=${4:-40}
case $2 in
  esp32c6*|esp32c3*) NM=$T/riscv32-esp-elf/esp-14.2.0_20241119/riscv32-esp-elf/bin/riscv32-esp-elf-nm ;;
  esp32s3*) NM=$T/xtensa-esp-elf/esp-14.2.0_20241119/xtensa-esp-elf/bin/xtensa-esp32s3-elf-nm ;;
  *) NM=$T/xtensa-esp-elf/esp-14.2.0_20241119/xtensa-esp-elf/bin/xtensa-esp32-elf-nm ;;
esac
SYMS=$(mktemp)
trap 'rm -f "$SYMS"' EXIT
case $2 in
  esp32c6*) ROMLD=esp32c6 ;; esp32s3*) ROMLD=esp32s3 ;; *) ROMLD=esp32 ;;
esac
{
  "$NM" -S -C "$ELF" | awk 'NF >= 4 && ($3 ~ /^[tTwW]$/) { name = $4; for (i = 5; i <= NF; i++) name = name " " $i; print $1, $2, name }'
  # ROM functions from Espressif's ROM ELF (no sizes: up to the next symbol).
  "$NM" -n "$HOME/.espressif/tools/esp-rom-elfs/20230320/${ROMLD}_rev0_rom.elf" |
    awk 'NF == 3 && $2 ~ /^[tTwW]$/ { print $1, 0, "rom:" $3 }'
} | sort -k1,1 > "$SYMS"
tr -d '\r' < "$LOG" | awk -v re="$RE" '
  /\[hw-perf\] begin / { on = ($3 ~ re); next }
  /\[hw-perf\] end/ { on = 0; next }
  on && /^\[hw-pc\] [01] / { for (i = 3; i <= NF; i++) { split($i, a, ":"); print a[1], a[2] } }
' | awk -v top="$TOP" -v syms="$SYMS" '
  function region(a) {
    if (a >= 0x40080000 && a < 0x400a0000) return "iram"
    if (a >= 0x40370000 && a < 0x403e0000) return "iram"
    if (a >= 0x40800000 && a < 0x40880000) return "sram"
    if (a >= 0x400d0000 && a < 0x40400000) return "flash"
    if (a >= 0x42000000 && a < 0x42800000) return "flash"
    if (a >= 0x40000000 && a < 0x40070000) return "rom"
    return "other"
  }
  BEGIN {
    n = 0
    while ((getline line < syms) > 0) {
      split(line, f, " "); n++
      sa[n] = strtonum("0x" f[1]); ss[n] = strtonum("0x" f[2])
      nm = f[3]; for (i = 4; i <= length(f); i++) nm = nm " " f[i]; sn[n] = nm
    }
  }
  {
    pc = strtonum("0x" $1); c = $2; total += c
    # Binary search for the last symbol at or before pc.
    lo = 1; hi = n
    while (lo < hi) { mid = int((lo + hi + 1) / 2); if (sa[mid] <= pc) lo = mid; else hi = mid - 1 }
    if (sa[lo] <= pc && pc < sa[lo] + (ss[lo] > 0 ? ss[lo] : 4096)) name = sn[lo]; else name = sprintf("?%x", pc)
    r = region(pc)
    fn[name] += c; fr[name] = r; rc[r] += c
  }
  END {
    printf "samples %d\n", total
    for (r in rc) printf "  region %-6s %6d %5.1f%%\n", r, rc[r], 100 * rc[r] / total
    m = 0; for (k in fn) { m++; key[m] = k }
    for (i = 1; i <= m; i++) for (j = i + 1; j <= m; j++) if (fn[key[j]] > fn[key[i]]) { t = key[i]; key[i] = key[j]; key[j] = t }
    for (i = 1; i <= m && i <= top; i++) printf "%6d %5.1f%% %-5s %s\n", fn[key[i]], 100 * fn[key[i]] / total, fr[key[i]], substr(key[i], 1, 110)
  }'
