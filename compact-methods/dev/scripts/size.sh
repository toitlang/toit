#!/usr/bin/env bash
# Size report of a firmware build copied by fw.sh (bins/<target>-<name>):
# esp_idf_size by archive and by object file (the toit_vm objects of the
# C++ interpreter and the Rust library), the largest Rust symbols, and the
# section totals. Writes size-*.txt next to the elf.
# Usage: size.sh BIN-DIR [xtensa|riscv]
set -uo pipefail
D=$1
ARCH=${2:-xtensa}
export IDF_PATH=/home/flo/work/opentoit-sandbox/third_party/esp-idf
export IDF_TOOLS_PATH=$HOME/.espressif
# shellcheck disable=SC1091
. "$IDF_PATH/export.sh" > /dev/null 2>&1
python -m esp_idf_size --archives "$D/toit.map" > "$D/size-archives.txt" 2>&1
python -m esp_idf_size --files "$D/toit.map" > "$D/size-files.txt" 2>&1
python -m esp_idf_size "$D/toit.map" > "$D/size-summary.txt" 2>&1
if [ "$ARCH" = xtensa ]; then
  NM=xtensa-esp32-elf-nm
else
  NM=riscv32-esp-elf-nm
fi
"$NM" -S --size-sort "$D/toit.elf" > "$D/nm-sizes.txt"
grep -E "libtoit_rust|libtoit_vm|libmain|libmbedcrypto|liblwip|libbt|libnet80211|libpp|libfreertos|libnewlib|libesp_hw|libheap|Total" "$D/size-archives.txt" | head -30
grep -E "interpreter_run|interpreter_v2|interpreter_core|interpreter\.cc|method_entries|verifier\.cc|verifier_v2|printing" "$D/size-files.txt"
