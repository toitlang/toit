#!/usr/bin/env bash
# Builds the Toit ESP32 (classic, Xtensa) firmware of a worktree, optionally
# with the verified core and verifier (Rust, esp-rs fork, cargo +esp
# -Zbuild-std) linked in. Build only, never flashes.
# Usage: fw-esp32.sh <worktree> <name> [core <opt-level>]
set -euo pipefail
WT=$1
NAME=$2
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
if [ "${3:-}" = core ]; then
  sed -i '/CONFIG_TOIT_VERIFIED_CORE/d' "$B.sdkconfig"
  echo "CONFIG_TOIT_VERIFIED_CORE=y" >> "$B.sdkconfig"
  echo "CONFIG_TOIT_VERIFIED_CORE_OPT_LEVEL=\"${4:-3}\"" >> "$B.sdkconfig"
fi
# Extra sdkconfig lines (e.g. to free IRAM for the experiment).
if [ -n "${EXTRA_SDKCONFIG:-}" ]; then printf "%b\n" "$EXTRA_SDKCONFIG" >> "$B.sdkconfig"; fi
start=$(date +%s)
python "$IDF_PATH/tools/idf.py" -C toolchains/esp32 -B "$B" -DSDKCONFIG="$B.sdkconfig" build
end=$(date +%s)
echo "build $NAME: $((end - start)) s"
xtensa-esp32-elf-size -A "$B/toit.elf" | grep -E "^\.(iram0\.text|dram0\.data|dram0\.bss|flash\.text|flash\.rodata) "
ls -l "$B/toit.bin"
