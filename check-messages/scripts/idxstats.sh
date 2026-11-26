#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Index statistics of dictionary builds: records in .esp_log_dict, records
# the linked code refers to (Xtensa literal scan; on RISC-V the calls of
# esp_log_dict_write counted in the disassembly), check records among them,
# index sizes (UBJSON, gzip -9; full and live-only). Text dumps go to acct/.
# Usage: idxstats.sh TARGET-CONFIG...
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a761e44286b8f7807
A=/home/flo/work/opentoit-sandbox-artifacts/check-messages
TOIT=$WT/build/host/sdk/bin/toit  # run on the source: the SDK binary may predate --live-only
export TMPDIR=$WT/build/tmp
for b in "$@"; do
  e=$A/bins/$b/toit.elf
  full=$TMPDIR/$b-full.dlog
  live=$TMPDIR/$b-live.dlog
  "$TOIT" run $WT/tools/esp_log_dict.toit -- index -o "$full" "$e" > /dev/null 2>&1
  "$TOIT" run $WT/tools/esp_log_dict.toit -- index --format=text -o "$A/acct/index-$b.txt" "$e" > /dev/null 2>&1
  "$TOIT" run $WT/tools/esp_log_dict.toit -- index --live-only -o "$live" "$e" > /dev/null 2>&1
  "$TOIT" run $WT/tools/esp_log_dict.toit -- index --live-only --format=text -o "$A/acct/index-$b-live.txt" "$e" > /dev/null 2>&1
  nfull=$(grep -vc "^#" "$A/acct/index-$b.txt")
  nlive=$(grep -vc "^#" "$A/acct/index-$b-live.txt")
  nchk=$(grep -c " check " "$A/acct/index-$b-live.txt")
  section=$(awk '$1 == ".esp_log_dict" {print $2}' "$A/bins/$b/sections.txt")
  calls=""
  case $b in
    esp32c6-*)
      calls=$($HOME/.espressif/tools/riscv32-esp-elf/esp-14.2.0_20241119/riscv32-esp-elf/bin/riscv32-esp-elf-objdump -d "$e" | grep -cE "jal.*<esp_log_dict_write(_kinds)?>")
      ;;
  esac
  printf "%s: section %s B, records %d, live %d (checks %d)%s, index %d B (gzip %d), live index %d B (gzip %d)\n" \
    "$b" "$section" "$nfull" "$nlive" "$nchk" "${calls:+, calls in code $calls}" \
    "$(stat -c %s "$full")" "$(gzip -9c "$full" | wc -c)" "$(stat -c %s "$live")" "$(gzip -9c "$live" | wc -c)"
done
