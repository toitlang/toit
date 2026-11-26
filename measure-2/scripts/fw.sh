#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Builds a Toit firmware of the device/measure-2 worktree for a target (never
# flashes) and copies the envelope, elf, map and sizes to bins/<target>-<name>.
# Usage: fw.sh TARGET NAME [SDKCONFIG-LINE...]
#   TARGET: esp32, esp32c6, esp32c3, esp32s2, esp32s3
#   SDKCONFIG lines are appended to the target's sdkconfig (e.g.
#   CONFIG_TOIT_VERIFIED_CORE=y CONFIG_TOIT_CXX_INTERPRETER=n).
# The version string is pinned (the host SDK is built with the same value,
# sdk.sh), so container install accepts snapshots after new commits.
set -euo pipefail
WT=${WT:-/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a341bf2ad86813fd0}
A=/home/flo/work/opentoit-sandbox-artifacts/measure-2
TARGET=$1
NAME=$2
shift 2
cd "$WT"
export TMPDIR=$WT/build/tmp
mkdir -p "$TMPDIR"
export IDF_PATH=/home/flo/work/opentoit-sandbox/third_party/esp-idf
export IDF_TOOLS_PATH=$HOME/.espressif
# shellcheck disable=SC1091
. "$IDF_PATH/export.sh" > /dev/null 2>&1
export IDF_TARGET=$TARGET
export IDF_CCACHE_ENABLE=1
export IGNORE_SUBMODULE=1
export TOIT_GIT_VERSION=v2.0.1-pre.999+measure-2
export CARGO_BUILD_JOBS=8
B="$WT/build/$TARGET-$NAME"
mkdir -p "$B"
cp "toolchains/$TARGET/sdkconfig" "$B.sdkconfig"
for line in "$@"; do
  key=${line%%=*}
  sed -i "/^$key=/d;/^# $key is not set/d" "$B.sdkconfig"
  case "$line" in
    *=n) echo "# $key is not set" >> "$B.sdkconfig" ;;
    *) echo "$line" >> "$B.sdkconfig" ;;
  esac
done
start=$(date +%s)
python "$IDF_PATH/tools/idf.py" -C "toolchains/$TARGET" -B "$B" -DSDKCONFIG="$B.sdkconfig" reconfigure
ninja -C "$B" -j "${JOBS:-10}" all
end=$(date +%s)
echo "build $TARGET-$NAME: $((end - start)) s"
O="$A/bins/$TARGET-$NAME"
mkdir -p "$O"
cp "$B/toit.elf" "$B/toit.bin" "$B/toit.map" "$B/firmware.envelope" "$B/system.snapshot" "$B.sdkconfig" "$O/"
case $TARGET in
  esp32|esp32s2|esp32s3) SIZE=xtensa-$TARGET-elf-size ;;
  *) SIZE=riscv32-esp-elf-size ;;
esac
"$SIZE" -A "$B/toit.elf" > "$O/sections.txt"
grep -E "^\.(iram0\.text|iram0\.vectors|dram0\.data|dram0\.bss|flash\.text|flash\.rodata|flash\.appdesc) " "$O/sections.txt" || true
echo "toit.bin $(stat -c %s "$B/toit.bin")"
