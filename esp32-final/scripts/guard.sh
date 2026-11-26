#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
#
# esp32-final: refuses every serial device but the ones this work may use
# (the rig's classic ESP32 boards 1 and 2; the S3 rig boards only for the
# no-PSRAM memory experiment), and checks the chip type esptool reports.
# The ESP32-C6 is NOT allowed (another agent uses it).
# Usage: guard.sh PORT EXPECTED-CHIP   (EXPECTED-CHIP: ESP32, ESP32-S3)
# Prints the port on success; exits 1 otherwise.
set -uo pipefail
PORT=$1
EXPECT=$2
C6=/dev/serial/by-id/usb-1a86_USB_Single_Serial_5959032636-if00
declare -A ALLOWED=(
  [/dev/ttyEsp32Board1]=ESP32
  [/dev/ttyEsp32Board2]=ESP32
  [/dev/ttyEsp32s3Board1]=ESP32-S3
  [/dev/ttyEsp32s3Board2]=ESP32-S3
)
if [ -z "${ALLOWED[$PORT]+x}" ]; then
  echo "guard: $PORT is not an allowed device" >&2; exit 1
fi
if [ "${ALLOWED[$PORT]}" != "$EXPECT" ]; then
  echo "guard: $PORT is a ${ALLOWED[$PORT]}, not $EXPECT" >&2; exit 1
fi
real=$(readlink -f -- "$PORT")
# The resolved node must not be the node of any other known device link.
for p in /dev/ttyEsp32Board1 /dev/ttyEsp32Board2 $C6 /dev/ttyEsp32s3Board1 /dev/ttyEsp32s3Board2; do
  [ "$p" = "$PORT" ] && continue
  if [ -e "$p" ] && [ "$(readlink -f -- "$p")" = "$real" ]; then
    echo "guard: $PORT and $p resolve to the same node $real" >&2; exit 1
  fi
done
[ -c "$real" ] || { echo "guard: $PORT ($real) missing" >&2; exit 1; }
if [ "${GUARD_SKIP_CHIP:-0}" != 1 ]; then
  out=$(env -u PYTHONPATH -u IDF_PYTHON_ENV_PATH esptool --port "$PORT" --after hard-reset chip-id 2>&1)
  chip=$(printf '%s\n' "$out" | sed -n 's/^Chip type: *\([^ ]*\).*/\1/p; s/^Detecting chip type\.\.\. *\(.*\)$/\1/p' | head -1)
  case "$chip" in
    "$EXPECT"|"$EXPECT "*) ;;
    *) echo "guard: $PORT reports chip '$chip', expected $EXPECT" >&2; printf '%s\n' "$out" >&2; exit 1 ;;
  esac
fi
echo "$PORT"
