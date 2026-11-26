#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
#
# Flashes a firmware envelope onto one of the allowed boards after checking
# the port and the chip type. Never run with esp-idf's export.sh sourced.
# Usage: flash.sh PORT CHIP ENVELOPE [--wifi] [--erase]
#   --wifi: the rig's WiFi credentials (esp32-test.env) go into the device
#   config; the file holding them is private and deleted afterwards.
#   --erase: erase the whole flash first.
#   --test-partitions: progs/partitions-test.csv instead of the envelope's.
set -euo pipefail
S=$(dirname "$0")
WT=${WT:-/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-ad2fa912738994022}
TOIT=$WT/build/host/sdk/bin/toit
PORT=$1
CHIP=$2
ENV=$3
shift 3
WIFI=0
ERASE=0
PARTS=0
for a in "$@"; do
  case $a in
    --wifi) WIFI=1 ;;
    --erase) ERASE=1 ;;
    --test-partitions) PARTS=1 ;;
    --ota-partitions) PARTS=2 ;;
    *) echo "flash: unknown option $a" >&2; exit 2 ;;
  esac
done
"$S/guard.sh" "$PORT" "$CHIP" > /dev/null
if [ $ERASE = 1 ]; then
  esptool --port "$PORT" erase-flash
fi
args=()
# The test layout (one 2.75 MB app partition, 1.1 MB programs) for
# envelopes carrying the untrusted images as assets.
[ $PARTS = 1 ] && args+=(--partitions /home/flo/work/opentoit-sandbox-artifacts/hardware/progs/partitions-test.csv)
# Two 0x1c0000 OTA partitions (the format-2 ESP32 firmware with a container).
[ $PARTS = 2 ] && args+=(--partitions /home/flo/work/opentoit-sandbox-artifacts/hardware/progs/partitions-ota-1c.csv)
cfg=""
if [ $WIFI = 1 ]; then
  umask 077
  cfg=$(mktemp "${XDG_RUNTIME_DIR:-/tmp}/hwcfg.XXXXXX")
  trap 'rm -f "$cfg"' EXIT
  (
    # shellcheck disable=SC1091
    set +x
    . /home/flo/work/opentoit-fix-ci/GITIGNORE/esp32-test.env
    printf '{"wifi":{"wifi.ssid":"%s","wifi.password":"%s"}}\n' "$ESP32_WIFI_SSID" "$ESP32_WIFI_PASSWORD" > "$cfg"
  )
  args+=(--config "$cfg")
fi
"$TOIT" tool firmware -e "$ENV" flash --port "$PORT" "${args[@]}"
