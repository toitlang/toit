#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# esp32-final: the OTA scenarios on one classic ESP32 board (ota2.sh;
# firmware A installs t-ticker-f1, t-ticker-f2 and u-ticker with
# FLAG-RUN-BOOT, then updates to B), with progs/partitions-ota-1c.csv:
#   s1  f2 -> f2 rebuild (PAD=2400), B validates
#   s3  f2 -> f2 rebuild that never validates: host reset, rollback to A
#   s4  f1 -> f2
#   s5  f2 -> f1
#   ep  f2 -> f2 with another verification epoch (EPOCHBUMP build f2-ep,
#       progs/ota/otab-epoch.toit: runs the images, reinstalls the refused
#       untrusted one, runs it again)
# Usage: ota-final.sh BOARD [SCENARIOS...]   (logs <board>-ota-<s>.txt)
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/esp32-final
cd "$A" || exit 1
B=$1
shift
show() { grep -a -E "^(OTA|TICKER|SUITE)|Failed to start|FORMAT|VERIFICATION|untrusted image|verification epoch|reinstall|without wakeup|Guru|abort|rst:" "logs/$1.txt" | cut -c1-200; }
for s in ${*:-s1 s3 s4 s5 ep}; do
  echo "=== $s"
  case $s in
    s1) bash scripts/ota2.sh "$B" esp32-f2-fin-otaa esp32-f2-p2400-fin-otab "$B-ota-s1" --ota-partitions ;;
    s3) bash scripts/ota2.sh "$B" esp32-f2-fin-otaa esp32-f2-p2400-fin-otabnv "$B-ota-s3" --nv --ota-partitions ;;
    s4) bash scripts/ota2.sh "$B" esp32-f1-fin-otaa esp32-f2-fin-otab "$B-ota-s4" --ota-partitions ;;
    s5) bash scripts/ota2.sh "$B" esp32-f2-fin-otaa esp32-f1-fin-otab "$B-ota-s5" --ota-partitions ;;
    ep) bash scripts/ota2.sh "$B" esp32-f2-fin-otaa esp32-f2-ep-otabep "$B-ota-ep" --ota-partitions ;;
  esac > "logs/$B-ota-$s.run" 2>&1
  grep "^ota2:" "logs/$B-ota-$s.run"
  show "$B-ota-$s"
done
echo "ota queue done"
