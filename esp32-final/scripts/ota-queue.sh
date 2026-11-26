#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# The OTA scenarios on one board (ota2.sh; firmware A installs t-ticker-f1,
# t-ticker-f2 and u-ticker with FLAG-RUN-BOOT, then updates to B):
#   s1  f2 -> f2 rebuild (PAD=2400), B validates
#   s3  f2 -> f2 rebuild that never validates: host reset, rollback to A
#   s2  f2 -> f2 rebuild with another system uuid (envelope property uuid,
#       as a firmware of another SDK version has; env ...-otabuuid)
#   s4  f1 -> f2
#   s5  f2 -> f1
# Usage: [OTA_FLASH_OPTS=--ota-partitions] ota-queue.sh BOARD TARGET [SCENARIOS...]
#   (logs <board>-ota-<s>.txt)
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/esp32-final
cd "$A" || exit 1
B=$1
T=$2
shift 2
show() { grep -a -E "^(OTA|TICKER|SUITE)|Failed to start|FORMAT|VERIFICATION|untrusted image|without wakeup|Guru|abort|rst:" "logs/$1.txt" | cut -c1-200; }
for s in ${*:-s1 s3 s2 s4 s5}; do
  echo "=== $s"
  case $s in
    s1) bash scripts/ota2.sh "$B" "$T-f2-otaa" "$T-f2-p2400-otab" "$B-ota-s1" ${OTA_FLASH_OPTS:-} ;;
    s3) bash scripts/ota2.sh "$B" "$T-f2-otaa" "$T-f2-p2400-otabnv" "$B-ota-s3" --nv ${OTA_FLASH_OPTS:-} ;;
    s2) bash scripts/ota2.sh "$B" "$T-f2-otaa" "$T-f2-p2400-otabuuid" "$B-ota-s2" ${OTA_FLASH_OPTS:-} ;;
    s4) bash scripts/ota2.sh "$B" "$T-f1-otaa" "$T-f2-otab" "$B-ota-s4" ${OTA_FLASH_OPTS:-} ;;
    s5) bash scripts/ota2.sh "$B" "$T-f2-otaa" "$T-f1-otab" "$B-ota-s5" ${OTA_FLASH_OPTS:-} ;;
  esac > "logs/$B-ota-$s.run" 2>&1
  grep "^ota2:" "logs/$B-ota-$s.run"
  show "$B-ota-$s"
done
echo "ota queue done"
