#!/usr/bin/env bash
# Builds the ESP32-C6 firmware of this worktree (never flashes), as
# device-cert/scripts/esp32c6.sh, and prints the section sizes.
# Usage: esp32c6.sh NAME [core OPT-LEVEL [infer] [checked] [src=VERIFIED-DIR]]
set -e
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a11f10728217c321a
cd "$WT"
NAME="$1"
export IDF_PATH=/home/flo/work/opentoit-sandbox/third_party/esp-idf
export IDF_TOOLS_PATH=$HOME/.espressif
source "$IDF_PATH/export.sh" > /dev/null
export IDF_TARGET=esp32c6
export IDF_CCACHE_ENABLE=1
export IGNORE_SUBMODULE=1
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
SIZE=$(ls -d "$HOME"/.espressif/tools/riscv32-esp-elf/esp-14.2.0_20241119/riscv32-esp-elf/bin)/riscv32-esp-elf-size
NM=$(dirname "$SIZE")/riscv32-esp-elf-nm
echo "== $NAME: toit.bin $(stat -c %s "$B/toit.bin")"
"$SIZE" -A "$B/toit.elf" | grep -E "^\.(iram0\.text|dram0\.data|dram0\.bss|flash\.text|flash\.rodata) "
"$NM" -S "$B/toit.elf" | grep -E " toit_v2_run$|run_loop|_ZN4toit11Interpreter3runEv$|toit_vmverify_verify$" || true
