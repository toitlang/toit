#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# esp32-layout: per function of the firmware ELF, the PC samples of the
# runs of the benchmarks matching BENCH-REGEX in one or more logs (MODE as
# in pc-profile.sh: i-stall-busy / d-stall-busy for stall-sample builds,
# empty for timer ticks). Prints TSV: samples, share of all samples (%),
# size, region, mangled name, demangled name; sorted by samples.
# Usage: func-samples.sh BIN-NAME BENCH-REGEX LOG-NAME...
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/esp32-final
T=$HOME/.espressif/tools
ELF=$A/bins/$1/toit.elf
RE=$2
shift 2
NM=$T/xtensa-esp-elf/esp-14.2.0_20241119/xtensa-esp-elf/bin/xtensa-esp32-elf-nm
SYMS=$(mktemp)
trap 'rm -f "$SYMS"' EXIT
# address size mangled demangled (demangled may contain spaces: last field).
paste -d' ' <("$NM" -S "$ELF" | awk 'NF >= 4 && ($3 ~ /^[tTwW]$/) {print $1, $2, $4}') \
            <("$NM" -S -C "$ELF" | awk 'NF >= 4 && ($3 ~ /^[tTwW]$/) {n = $4; for (i = 5; i <= NF; i++) n = n "_" $i; print n}') |
  sort -k1,1 > "$SYMS"
for L in "$@"; do tr -d '\r' < "$A/logs/$L.txt"; done | awk -v re="$RE" -v mode="${MODE:-}" '
  /\[hw-perf\] begin / { on = ($3 ~ re); next }
  /\[hw-perf\] wall / { if (mode != "" && $6 != mode) on = 0; next }
  /\[hw-perf\] end/ { on = 0; next }
  on && /^\[hw-pc\] [01] / { for (i = 3; i <= NF; i++) { split($i, a, ":"); print a[1], a[2] } }
' | awk -v syms="$SYMS" '
  function region(a) {
    if (a >= 0x40080000 && a < 0x400a0000) return "iram"
    if (a >= 0x400d0000 && a < 0x40400000) return "flash"
    if (a >= 0x40000000 && a < 0x40070000) return "rom"
    return "other"
  }
  BEGIN {
    n = 0
    while ((getline line < syms) > 0) {
      split(line, f, " "); n++
      sa[n] = strtonum("0x" f[1]); ss[n] = strtonum("0x" f[2]); sm[n] = f[3]; sd[n] = f[4]
    }
  }
  {
    pc = strtonum("0x" $1); c = $2; total += c
    lo = 1; hi = n
    while (lo < hi) { mid = int((lo + hi + 1) / 2); if (sa[mid] <= pc) lo = mid; else hi = mid - 1 }
    if (sa[lo] <= pc && pc < sa[lo] + (ss[lo] > 0 ? ss[lo] : 4096)) k = lo; else k = 0
    cnt[k] += c
  }
  END {
    for (k in cnt) {
      if (k == 0) { printf "%d\t%.2f\t0\tother\t?\t?\n", cnt[k], 100 * cnt[k] / total; continue }
      printf "%d\t%.2f\t%d\t%s\t%s\t%s\n", cnt[k], 100 * cnt[k] / total, ss[k], region(sa[k]), sm[k], substr(sd[k], 1, 100)
    }
  }' | sort -t$'\t' -k1,1nr
