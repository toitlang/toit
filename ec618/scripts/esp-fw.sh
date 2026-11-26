#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Builds an ESP32 firmware of this worktree (never flashes), as the gate for
# shared build files (device-format2/scripts/fw.sh).
# Usage: esp-fw.sh TARGET NAME [SDKCONFIG-LINE...]
set -euo pipefail
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a6c88832d90141abe
TARGET=$1
NAME=$2
shift 2
cd "$WT"
export IDF_PATH=/home/flo/work/opentoit-sandbox/third_party/esp-idf
export IDF_TOOLS_PATH=$HOME/.espressif
# shellcheck disable=SC1091
. "$IDF_PATH/export.sh" > /dev/null 2>&1
export IDF_TARGET=$TARGET
export IDF_CCACHE_ENABLE=1
export IGNORE_SUBMODULE=1
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
python "$IDF_PATH/tools/idf.py" -C "toolchains/$TARGET" -B "$B" -DSDKCONFIG="$B.sdkconfig" build
echo "build $TARGET-$NAME: $(( $(date +%s) - start )) s, toit.bin $(stat -c %s "$B/toit.bin")"
