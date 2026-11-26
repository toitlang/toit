#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# esp32-layout: flash-cache set analysis of a stall-sample log (f2stall,
# f1stall: [hw-pc] lines hold the PCs of i-stall-busy or d-stall-busy
# cycles). The classic ESP32's flash cache (TRM 3.3.4): 32 KB per CPU,
# two-way set-associative, 32-byte blocks -> 512 sets, set = (addr >> 5) &
# 511, i.e. two addresses compete when they are equal modulo 16 KB.
# For the runs of the benchmarks matching BENCH-REGEX in MODE (default
# i-stall-busy): the samples per flash line (pc >> 5), then per set the
# lines that missed in it. A set with three or more lines that miss is a
# conflict (two ways); a set with one missing line competes with lines we
# do not see (data, or code that did not stall).
# Usage: stall-sets.sh LOG-NAME BIN-NAME BENCH-REGEX [TOP-SETS]
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/esp32-layout
T=$HOME/.espressif/tools
LOG=$A/logs/$1.txt
ELF=$A/bins/$2/toit.elf
RE=$3
TOP=${4:-25}
MODE=${MODE:-i-stall-busy}
NM=$T/xtensa-esp-elf/esp-14.2.0_20241119/xtensa-esp-elf/bin/xtensa-esp32-elf-nm
SYMS=$(mktemp)
trap 'rm -f "$SYMS"' EXIT
"$NM" -S -C "$ELF" | awk 'NF >= 4 && ($3 ~ /^[tTwW]$/) { name = $4; for (i = 5; i <= NF; i++) name = name " " $i; print $1, $2, name }' | sort -k1,1 > "$SYMS"
tr -d '\r' < "$LOG" | awk -v re="$RE" -v mode="$MODE" '
  /\[hw-perf\] begin / { on = ($3 ~ re); next }
  /\[hw-perf\] wall / { if ($6 != mode) on = 0; next }
  /\[hw-perf\] end/ { on = 0; next }
  on && /^\[hw-pc\] [01] / { for (i = 3; i <= NF; i++) { split($i, a, ":"); print a[1], a[2] } }
' | awk -v top="$TOP" -v syms="$SYMS" '
  BEGIN {
    n = 0
    while ((getline line < syms) > 0) {
      split(line, f, " "); n++
      sa[n] = strtonum("0x" f[1]); ss[n] = strtonum("0x" f[2])
      nm = f[3]; for (i = 4; i <= length(f); i++) nm = nm " " f[i]; sn[n] = nm
    }
  }
  function fname(pc,   lo, hi, mid) {
    lo = 1; hi = n
    while (lo < hi) { mid = int((lo + hi + 1) / 2); if (sa[mid] <= pc) lo = mid; else hi = mid - 1 }
    if (sa[lo] <= pc && pc < sa[lo] + (ss[lo] > 0 ? ss[lo] : 4096)) return substr(sn[lo], 1, 60)
    return sprintf("?%x", pc)
  }
  {
    pc = strtonum("0x" $1); c = $2; total += c
    if (pc >= 0x400d0000 && pc < 0x40400000) {
      flash += c; line = int(pc / 32); lc[line] += c
      if (!(line in lf)) lf[line] = fname(pc)
    } else if (pc >= 0x40080000 && pc < 0x400a0000) iram += c
    else if (pc >= 0x40000000 && pc < 0x40070000) rom += c
    else other += c
  }
  END {
    printf "mode %s samples %d: flash %d (%.1f%%), iram %d, rom %d, other %d\n", mode, total, flash, 100 * flash / (total ? total : 1), iram, rom, other
    nl = 0
    for (l in lc) { nl++; s = l % 512; sc[s] += lc[l]; sl[s] = sl[s] sprintf(" %x:%d", l * 32, lc[l]); sn2[s]++; if (lc[l] * 100 >= flash) big[s]++ }
    printf "flash lines with samples %d\n", nl
    # Sets by samples.
    m = 0; for (s in sc) { m++; key[m] = s }
    for (i = 1; i <= m; i++) for (j = i + 1; j <= m; j++) if (sc[key[j]] > sc[key[i]]) { t = key[i]; key[i] = key[j]; key[j] = t }
    cum = 0; c3 = 0
    for (i = 1; i <= m; i++) { if (sn2[key[i]] >= 3) c3 += sc[key[i]] }
    printf "samples in sets with >= 3 missing lines: %d (%.1f%% of flash)\n", c3, 100 * c3 / (flash ? flash : 1)
    for (i = 1; i <= m && i <= top; i++) {
      s = key[i]; cum += sc[s]
      printf "set %3d (off 0x%04x) %6d %5.1f%% cum %5.1f%% lines %d:", s, s * 32, sc[s], 100 * sc[s] / flash, 100 * cum / flash, sn2[s]
      split(sl[s], ll, " ")
      for (k in ll) { split(ll[k], q, ":"); a = strtonum("0x" q[1]); if (q[2] * 200 >= sc[s]) printf " %s(%s)", lf[a / 32], q[2] }
      printf "\n"
    }
  }'
