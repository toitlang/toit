#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Builds a Toit firmware of the device/check-messages worktree for a target
# (never flashes) against the private ESP-IDF overlay (idf-overlay.sh; the
# shared checkout is used with IDF=shared) and copies the envelope, elf,
# map, sdkconfig and section sizes to bins/<target>-<name>.
# Usage: [IDF=shared|overlay] fw.sh TARGET NAME [SDKCONFIG-LINE...]
set -euo pipefail
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a761e44286b8f7807
A=/home/flo/work/opentoit-sandbox-artifacts/check-messages
TARGET=$1
NAME=$2
shift 2
cd "$WT"
export TMPDIR=$WT/build/tmp
mkdir -p "$TMPDIR"
if [ "${IDF:-overlay}" = shared ]; then
  IDF_SEL=/home/flo/work/opentoit-sandbox/third_party/esp-idf
else
  IDF_SEL=$WT/build/idf-overlay/esp-idf
  # Its version.txt (the shared checkout's git describe, v5.2-dev) would
  # make idf.py check the Python packages against v5.2's constraints.
  export IDF_PYTHON_CHECK_CONSTRAINTS=no
  # The overlay has no .git: git must not find the Toit repository above it
  # (ESP-IDF would describe it and try to initialize its submodules).
  export IDF_SKIP_CHECK_SUBMODULES=1
  export GIT_CEILING_DIRECTORIES=$WT/build/idf-overlay
fi
export IDF_TOOLS_PATH=$HOME/.espressif
# The environment (tools, Python) of the shared checkout: the overlay's
# version.txt would make export.sh look for a v5.2 environment.
# shellcheck disable=SC1091
. /home/flo/work/opentoit-sandbox/third_party/esp-idf/export.sh > /dev/null 2>&1
export IDF_PATH=$IDF_SEL
export IDF_TARGET=$TARGET
export IDF_CCACHE_ENABLE=1
export IGNORE_SUBMODULE=1
export TOIT_GIT_VERSION=v2.0.1-pre.999+check-messages
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
ninja -C "$B" -j "${JOBS:-8}" all
end=$(date +%s)
echo "build $TARGET-$NAME: $((end - start)) s"
O="$A/bins/$TARGET-$NAME"
mkdir -p "$O"
cp "$B/toit.elf" "$B/toit.bin" "$B/toit.map" "$B/firmware.envelope" "$B.sdkconfig" "$O/"
[ -f "$B/toit.dlog" ] && cp "$B/toit.dlog" "$O/"
case $TARGET in
  esp32|esp32s2|esp32s3) SIZE=xtensa-$TARGET-elf-size ;;
  *) SIZE=riscv32-esp-elf-size ;;
esac
"$SIZE" -A "$B/toit.elf" > "$O/sections.txt"
echo "toit.bin $(stat -c %s "$B/toit.bin")"
