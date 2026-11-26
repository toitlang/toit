#!/usr/bin/env bash
# Builds the device side of the verifier differential: the vdiff static
# library for xtensa-esp32-none-elf (esp fork, build-std; opt-level OPT for
# the core, z for toit_spec as in the device profile) and the ESP-IDF app
# that embeds the inputs, then merges a 4 MB flash image for QEMU.
# Usage: vdiff-build.sh <name> [extra RUSTFLAGS...]   (env OPT=3|s|z, LTO=0|1)
set -euo pipefail
NAME=$1
shift
ROOT=/home/flo/work/opentoit-sandbox-artifacts/xtensa-fixes/qemu
export PATH="$HOME/.rustup/toolchains/esp/xtensa-esp-elf/esp-14.2.0_20241119/xtensa-esp-elf/bin:$PATH"
export CARGO_PROFILE_RELEASE_OPT_LEVEL=${OPT:-3}
if [ "${LTO:-0}" = 1 ]; then export CARGO_PROFILE_RELEASE_LTO=fat; fi
export RUSTFLAGS="${*:-}"
TD=$ROOT/vdiff/target-xt-$NAME
(cd "$ROOT/vdiff" && cargo +esp rustc --release --lib --crate-type staticlib --features device \
   -Zbuild-std=core,alloc --target xtensa-esp32-none-elf --target-dir "$TD") > "$ROOT/build-$NAME.log" 2>&1 \
   || { tail -20 "$ROOT/build-$NAME.log"; exit 1; }
LIB=$TD/xtensa-esp32-none-elf/release/libvdiff.a
unset RUSTFLAGS CARGO_PROFILE_RELEASE_OPT_LEVEL CARGO_PROFILE_RELEASE_LTO
export IDF_PATH=/home/flo/work/opentoit-sandbox/third_party/esp-idf
export IDF_TOOLS_PATH=$HOME/.espressif
# shellcheck disable=SC1091
. "$IDF_PATH/export.sh" > /dev/null 2>&1
cd "$ROOT/idf-vdiff"
B=build-$NAME
VDIFF_LIB=$LIB idf.py -B "$B" -D SDKCONFIG="$B/sdkconfig" build >> "$ROOT/build-$NAME.log" 2>&1 \
  || { grep -E "error|undefined|multiple" "$ROOT/build-$NAME.log" | head -20; exit 1; }
(cd "$B" && esptool.py --chip esp32 merge_bin --fill-flash-size 4MB -o flash.bin @flash_args) >> "$ROOT/build-$NAME.log" 2>&1
ls -l "$B/flash.bin" "$B/vdiff.bin"
