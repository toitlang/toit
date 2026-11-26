#!/usr/bin/env bash
# Builds the ESP32-C6 firmware (never flashes), as phase5's build/esp32c6.sh.
# Usage: esp32c6.sh NAME [core OPT-LEVEL [infer] [checked] [src=VERIFIED-DIR]]
#   infer, checked: link the inference / the checked loop (Kconfig
#   TOIT_VERIFIED_CORE_INFER / _CHECKED_LOOP); src=DIR: build the Rust
#   library from a (patched) copy of verified/.
set -e
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a9365a74954333c15
cd "$WT"
NAME="$1"
export IDF_PATH=/home/flo/work/opentoit-sandbox/third_party/esp-idf
source "$IDF_PATH/export.sh" > /dev/null
export IDF_TARGET=esp32c6
export IDF_CCACHE_ENABLE=1
B="$WT/build/esp32c6-$NAME"
mkdir -p "$B"
cp toolchains/esp32c6/sdkconfig "$B.sdkconfig"
SRC="$WT/verified"
if [ "${2:-}" = core ]; then
  sed -i '/CONFIG_TOIT_VERIFIED_CORE/d' "$B.sdkconfig"
  echo "CONFIG_TOIT_VERIFIED_CORE=y" >> "$B.sdkconfig"
  echo "CONFIG_TOIT_VERIFIED_CORE_OPT_LEVEL=\"${3:-3}\"" >> "$B.sdkconfig"
  for extra in "${@:4}"; do
    case "$extra" in
      infer) echo "CONFIG_TOIT_VERIFIED_CORE_INFER=y" >> "$B.sdkconfig" ;;
      checked) echo "CONFIG_TOIT_VERIFIED_CORE_CHECKED_LOOP=y" >> "$B.sdkconfig" ;;
      src=*) SRC="${extra#src=}" ;;
    esac
  done
fi
python "$IDF_PATH/tools/idf.py" -C toolchains/esp32c6 -B "$B" -DSDKCONFIG="$B.sdkconfig" \
  -DTOIT_VERIFIED_CORE_SOURCE_DIR="$SRC" build
