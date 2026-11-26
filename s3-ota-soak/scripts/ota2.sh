#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
#
# One OTA scenario: flashes firmware A (env/<A-ENV>.envelope, otaa.toit, with
# the rig's WiFi, after erasing the flash), serves the binary of firmware B
# (env/<B-ENV>.envelope, extracted with the same WiFi config, size-prefixed)
# on TCP port 7999 and captures the console until B's "SUITE done".
# Usage: ota2.sh BOARD A-ENV B-ENV LOG-NAME [--nv] [flash options...]
#   --nv:   B never validates (otabnv): after B's "not validating" line the
#           board is reset from the host, and the capture continues until
#           firmware A's "SUITE done" (the rollback).
# Another system uuid for B: an envelope with `property set uuid` (the
# device config's "uuid" key has no effect; ota-queue.sh, s2).
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/s3-ota-soak
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-ab8ae657bf5edfc00
TOIT=$WT/build/host/sdk/bin/toit
BOARD=$1
AENV=$2
BENV=$3
LOGN=$4
shift 4
NV=0
opts=()
for a in "$@"; do
  case $a in
    --nv) NV=1 ;;
    *) opts+=("$a") ;;
  esac
done
case $BOARD in
  c6) PORT=/dev/serial/by-id/usb-1a86_USB_Single_Serial_5959032636-if00; CHIP=ESP32-C6 ;;
  s3a) PORT=/dev/ttyEsp32s3Board1; CHIP=ESP32-S3 ;;
  s3b) PORT=/dev/ttyEsp32s3Board2; CHIP=ESP32-S3 ;;
  *) echo "unknown board $BOARD" >&2; exit 2 ;;
esac
umask 077
tmp=$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/ota.XXXXXX")
trap 'rm -rf "$tmp"; [ -n "${srv:-}" ] && kill "$srv" 2> /dev/null' EXIT
(
  set +x
  # shellcheck disable=SC1091
  . /home/flo/work/opentoit-fix-ci/GITIGNORE/esp32-test.env
  printf '{"wifi":{"wifi.ssid":"%s","wifi.password":"%s"}}\n' "$ESP32_WIFI_SSID" "$ESP32_WIFI_PASSWORD" > "$tmp/cfg.json"
)
"$TOIT" tool firmware -e "$A/env/$BENV.envelope" extract --format binary --config "$tmp/cfg.json" -o "$tmp/fw.bin" || exit 1
size=$(stat -c %s "$tmp/fw.bin")
echo "ota2: firmware B $BENV: $size bytes"
printf "%08x" "$size" | sed 's/\(..\)\(..\)\(..\)\(..\)/\4\3\2\1/' | xxd -r -p > "$tmp/payload"
cat "$tmp/fw.bin" >> "$tmp/payload"
socat -u "FILE:$tmp/payload" TCP-LISTEN:7999,reuseaddr &
srv=$!
FAIL="Guru Meditation|abort\(\)|Potential dead|Backtrace:|assert"
if [ $NV = 0 ]; then
  STOP="SUITE done|$FAIL" bash "$A/scripts/hwrun.sh" "$BOARD" "$AENV" "$LOGN" 400 --wifi --erase "${opts[@]}"
else
  STOP="OTA-B not validating|$FAIL" bash "$A/scripts/hwrun.sh" "$BOARD" "$AENV" "$LOGN" 400 --wifi --erase "${opts[@]}"
  sleep 2
  echo "ota2: resetting the board before B validates"
  bash "$A/scripts/mon.sh" "$PORT" "$CHIP" "$A/logs/$LOGN-after-reset.txt" 120 "SUITE done|$FAIL"
  grep -a -E "^(OTA|TICKER|SUITE)|Failed to start|FORMAT|VERIFICATION|$FAIL" "$A/logs/$LOGN-after-reset.txt"
  # One more plain reset: firmware A stays.
  bash "$A/scripts/mon.sh" "$PORT" "$CHIP" "$A/logs/$LOGN-after-reset2.txt" 60 "SUITE done|$FAIL"
  grep -a -E "^(OTA-A firmware|OTA-A again|SUITE)" "$A/logs/$LOGN-after-reset2.txt"
fi
