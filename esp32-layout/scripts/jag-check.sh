#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Flash budget of a firmware build in bins/: the flashed binary (extract
# --format binary) with the system only and with Jaguar (installed as in
# tests/esp32/check-partition-sizes.sh), against the OTA partition, and the
# pass/fail of check-partition-sizes.sh.
# Usage: jag-check.sh TARGET CONFIG [JAGUAR-SNAPSHOT]
#   The Jaguar snapshot defaults to jaguar/jaguar-f2.snapshot (f1 for
#   CONFIG f1).
set -uo pipefail
WT=${WT:-/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a075db46027697e45}
A=/home/flo/work/opentoit-sandbox-artifacts/esp32-layout
TOIT=$WT/build/host/sdk/bin/toit
TARGET=$1
C=$2
D=$A/bins/$TARGET-$C
J=${3:-$A/jaguar/jaguar-$([[ "$C" == f1* ]] && echo f1 || echo f2).snapshot}
case $TARGET in
  esp32) PART=$((0x1a0000)) ;;
  esp32c6) PART=$((0x1d0000)) ;;
  *) PART=0 ;;
esac
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
echo '{"id":"00000000-0000-0000-0000-000000000001","name":"partition-size-check","chip":"esp32s3"}' > "$T/jaguar.json"
echo '{"wifi":{"wifi.ssid":"partition-size-check","wifi.password":"partition-size-check"}}' > "$T/config.json"
"$TOIT" tool assets -e "$T/jaguar.assets" create
"$TOIT" tool assets -e "$T/jaguar.assets" add --format=tison config "$T/jaguar.json"
"$TOIT" tool firmware -e "$D/firmware.envelope" extract --format binary --config "$T/config.json" -o "$T/sys.bin" > /dev/null
"$TOIT" tool firmware -e "$D/firmware.envelope" container install -o "$T/jaguar.envelope" \
  --assets "$T/jaguar.assets" --trigger=boot --critical jaguar "$J" > /dev/null
"$TOIT" tool firmware -e "$T/jaguar.envelope" extract --format binary --config "$T/config.json" -o "$T/jag.bin" > /dev/null
s=$(stat -c %s "$T/sys.bin")
j=$(stat -c %s "$T/jag.bin")
printf "%s-%s toit.bin %d  system only %d (%+d)  with Jaguar %d (%+d) of %d\n" "$TARGET" "$C" \
  "$(stat -c %s "$D/toit.bin")" "$s" $((PART - s)) "$j" $((PART - j)) "$PART"
if TOIT="$TOIT" bash "$WT/tests/esp32/check-partition-sizes.sh" "$J" "$D/firmware.envelope" > "$T/check.log" 2>&1; then
  echo "check-partition-sizes: PASS"
else
  echo "check-partition-sizes: FAIL ($(grep -c FAIL "$T/check.log") failures)"
fi
