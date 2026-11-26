#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
#
# OTA update without Jaguar: flashes env <TARGET>-<CONFIG>-ota (hwota.toit)
# with the rig's WiFi, serves the binary of <TARGET>-<CONFIG>-ota-after
# (with the same WiFi config, size-prefixed) on TCP port 7999 and waits for
# the new firmware's "SUITE done".
# Usage: ota.sh BOARD TARGET CONFIG [flash options...]
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/memory-pressure
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a2ae466cd9dbd080f
TOIT=$WT/build/host/sdk/bin/toit
BOARD=$1
TARGET=$2
CONFIG=$3
shift 3
umask 077
tmp=$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/ota.XXXXXX")
trap 'rm -rf "$tmp"; [ -n "${srv:-}" ] && kill "$srv" 2> /dev/null' EXIT
(
  # shellcheck disable=SC1091
  . /home/flo/work/opentoit-fix-ci/GITIGNORE/esp32-test.env
  printf '{"wifi":{"wifi.ssid":"%s","wifi.password":"%s"}}\n' "$ESP32_WIFI_SSID" "$ESP32_WIFI_PASSWORD" > "$tmp/cfg.json"
)
"$TOIT" tool firmware -e "$A/env/$TARGET-$CONFIG-ota-after.envelope" extract --format binary --config "$tmp/cfg.json" -o "$tmp/fw.bin" || exit 1
size=$(stat -c %s "$tmp/fw.bin")
echo "ota: new firmware $size bytes"
printf "%08x" "$size" | sed 's/\(..\)\(..\)\(..\)\(..\)/\4\3\2\1/' | xxd -r -p > "$tmp/payload"
cat "$tmp/fw.bin" >> "$tmp/payload"
socat -u "FILE:$tmp/payload" TCP-LISTEN:7999,reuseaddr &
srv=$!
STOP="SUITE done|Guru Meditation|abort\(\)|Potential dead" bash "$A/scripts/hwrun.sh" "$BOARD" "$TARGET-$CONFIG-ota" "$BOARD-$CONFIG-ota" 300 --wifi "$@"
