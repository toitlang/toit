#!/usr/bin/env bash
# Builds the Toit ESP32 (classic, Xtensa) firmware of a worktree with the
# verified core at opt-level 3 and the Rust library built from a level's
# copy of verified/ (make-copies.sh: the verifier+glue package opt-level).
# Build only, never flashes. (Adapted from esp32-build/scripts/fw-esp32.sh.)
# Usage: fw-esp32.sh <worktree> <level>
set -euo pipefail
WT=$1
L=$2
NAME=vopt-$L
cd "$WT"
export IDF_PATH=/home/flo/work/opentoit-sandbox/third_party/esp-idf
export IDF_TOOLS_PATH=$HOME/.espressif
# shellcheck disable=SC1091
. "$IDF_PATH/export.sh" > /dev/null 2>&1
export IDF_TARGET=esp32
export IDF_CCACHE_ENABLE=1
export IGNORE_SUBMODULE=1
B="$WT/build/esp32-$NAME"
mkdir -p "$B"
cp toolchains/esp32/sdkconfig "$B.sdkconfig"
sed -i '/CONFIG_TOIT_VERIFIED_CORE/d' "$B.sdkconfig"
echo "CONFIG_TOIT_VERIFIED_CORE=y" >> "$B.sdkconfig"
echo "CONFIG_TOIT_VERIFIED_CORE_OPT_LEVEL=\"3\"" >> "$B.sdkconfig"
start=$(date +%s)
python "$IDF_PATH/tools/idf.py" -C toolchains/esp32 -B "$B" -DSDKCONFIG="$B.sdkconfig" \
  -DTOIT_VERIFIED_CORE_SOURCE_DIR="$WT/build/vopt/$L/verified" build
end=$(date +%s)
echo "build $NAME: $((end - start)) s"
grep -E "^TOIT_VERIFIED_CORE_(SOURCE_DIR|OPT_LEVEL)" "$B/CMakeCache.txt"
ls -l "$B"/verified_core/xtensa-esp32-none-elf/device/libtoit_rust.a 2>/dev/null || find "$B" -name libtoit_rust.a -exec ls -l {} \;
xtensa-esp32-elf-size -A "$B/toit.elf" | grep -E "^\.(iram0\.text|dram0\.data|dram0\.bss|flash\.text|flash\.rodata) "
ls -l "$B/toit.bin"
