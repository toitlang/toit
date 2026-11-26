#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Writes a board's flash dump from backup/ back and checks that it boots.
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/liveness
case $1 in
  b1) PORT=/dev/ttyEsp32Board1; CHIP=ESP32; IMG=$A/backup/board1-original.bin ;;
  b2) PORT=/dev/ttyEsp32Board2; CHIP=ESP32; IMG=$A/backup/board2-original.bin ;;
  *) echo "unknown board $1" >&2; exit 2 ;;
esac
"$A/scripts/guard.sh" "$PORT" "$CHIP" > /dev/null || exit 1
esptool --port "$PORT" -b 921600 write-flash 0 "$IMG" > "$A/logs/restore-$1.log" 2>&1 || { tail -5 "$A/logs/restore-$1.log"; exit 1; }
grep -a "Hash of data verified" "$A/logs/restore-$1.log" | tail -1
bash "$A/scripts/mon.sh" "$PORT" "$CHIP" "$A/logs/restored-$1.txt" 30 "toit\] INFO: running|Guru|abort"
grep -a "toit\]" "$A/logs/restored-$1.txt" | head -3
