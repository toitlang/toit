#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
#
# Runs the repository's ESP32 hardware test suite (tests/hw/esp32) on the
# rig's two classic ESP32 boards with a firmware build of bins/.
# Usage: hwsuite.sh CONFIG TAG [ctest args...]
#   CONFIG f1: format-1 envelope, tests compiled in format 1, standard layout.
#   other:     format-2 envelope bins/esp32-CONFIG, progs/partitions-ota-1c.csv.
# Results: logs/hwsuite-CONFIG-TAG.txt (ctest summary) and the ctest logs
# with the WiFi password removed. Never sources esp-idf's export.sh.
set -uo pipefail
A=/home/flo/work/opentoit-sandbox-artifacts/esp32-final
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-ac50d68544beaea91
CONFIG=$1
TAG=$2
shift 2
for p in /dev/ttyEsp32Board1 /dev/ttyEsp32Board2; do
  "$A/scripts/guard.sh" "$p" ESP32 > /dev/null || exit 1
done
cd "$WT" || exit 1
# shellcheck disable=SC1091
. build/worktree-env.sh
set +x
# shellcheck disable=SC1091
. /home/flo/work/opentoit-fix-ci/GITIGNORE/esp32-test.env
# Only the two classic boards: the S3 ports stay unset for this run.
unset ESP32S3_BOARD1_PORT ESP32S3_BOARD2_PORT ESP32S3_ENVELOPE
export TOIT_EXE_HW=$WT/build/host/sdk/bin/toit
export ESP32_ENVELOPE=$A/bins/esp32-$CONFIG/firmware.envelope
if [ "$CONFIG" = f1 ]; then
  export TOIT_BYTECODE_FORMAT=1
  unset ESP32_PARTITIONS
else
  export TOIT_BYTECODE_FORMAT=2
  export ESP32_PARTITIONS=$A/progs/partitions-ota-1c.csv
fi
make rebuild-cmake-hw download-packages-hw-esp32 > "$A/logs/hwsuite-$CONFIG-$TAG.cmake.log" 2>&1 || { echo "cmake failed"; tail -20 "$A/logs/hwsuite-$CONFIG-$TAG.cmake.log"; exit 1; }
start=$(date +%s)
ctest --test-dir build/hw -C esp32 --timeout 600 "$@" > "$A/logs/hwsuite-$CONFIG-$TAG.txt" 2>&1
status=$?
echo "wall $(( $(date +%s) - start )) s, ctest exit $status" >> "$A/logs/hwsuite-$CONFIG-$TAG.txt"
for f in LastTest.log LastTestsFailed.log; do
  src=build/hw/Testing/Temporary/$f
  [ -f "$src" ] || continue
  # Remove the password from the copy and from the build tree's log.
  PW="$ESP32_WIFI_PASSWORD" awk 'BEGIN { pw = ENVIRON["PW"] }
    { out = ""; line = $0
      while ((i = index(line, pw)) > 0) { out = out substr(line, 1, i - 1) "<wifi-password>"; line = substr(line, i + length(pw)) }
      print out line }' "$src" > "$A/logs/hwsuite-$CONFIG-$TAG.$f"
  cp "$A/logs/hwsuite-$CONFIG-$TAG.$f" "$src"
done
tail -40 "$A/logs/hwsuite-$CONFIG-$TAG.txt"
