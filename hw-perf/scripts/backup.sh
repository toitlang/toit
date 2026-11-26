#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Dumps a rig board's whole flash into backup/ (before the first flash).
# The dump holds the board's WiFi configuration: delete it after restore.sh.
# Usage: backup.sh BOARD   (b1, b2, s3a, s3b)
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/hw-perf
case $1 in
  b1) PORT=/dev/ttyEsp32Board1; CHIP=ESP32; IMG=$A/backup/board1-original.bin ;;
  b2) PORT=/dev/ttyEsp32Board2; CHIP=ESP32; IMG=$A/backup/board2-original.bin ;;
  s3a) PORT=/dev/ttyEsp32s3Board1; CHIP=ESP32-S3; IMG=$A/backup/s3board1-original.bin ;;
  s3b) PORT=/dev/ttyEsp32s3Board2; CHIP=ESP32-S3; IMG=$A/backup/s3board2-original.bin ;;
  *) echo "unknown board $1" >&2; exit 2 ;;
esac
[ -e "$IMG" ] && { echo "backup: $IMG exists, not overwriting" >&2; exit 1; }
"$A/scripts/guard.sh" "$PORT" "$CHIP" > /dev/null || exit 1
mkdir -p "$A/backup"
chmod 700 "$A/backup"
umask 077
esptool --port "$PORT" -b 921600 read-flash 0 ALL "$IMG" > "$A/logs/backup-$1.log" 2>&1 || { tail -5 "$A/logs/backup-$1.log"; exit 1; }
ls -l "$IMG"
sha256sum "$IMG" > "$IMG.sha256"
