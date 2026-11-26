#!/usr/bin/env bash
# Builds the ESP-IDF test firmware (idf-app) for the esp32 with the Toit
# tree's ESP-IDF (v5.4.2, GCC esp-14.2.0_20241119): baseline (C only) and
# with the Rust static library (fwlib: verifier + core + kernels + probes,
# fork 1.99.0.0, opt-level $1, fat LTO, panic=abort). Build only.
# Usage: idf-build.sh [s|z|3]
set -euo pipefail
OPT=${1:-s}
ROOT=/home/flo/work/opentoit-sandbox-artifacts/xtensa-rust
export IDF_PATH=/home/flo/work/opentoit-sandbox/third_party/esp-idf
export IDF_TOOLS_PATH=$HOME/.espressif
# shellcheck disable=SC1091
. "$IDF_PATH/export.sh" > "$ROOT/idf-app/export.log" 2>&1

(cd "$ROOT/fwlib" && CARGO_PROFILE_RELEASE_OPT_LEVEL=$OPT cargo +esp build --release -Zbuild-std=core,alloc \
    --target xtensa-esp32-none-elf --target-dir "$ROOT/fwlib-target/$OPT") > "$ROOT/idf-app/fwlib-$OPT.log" 2>&1
LIB=$ROOT/fwlib-target/$OPT/xtensa-esp32-none-elf/release/libtoit_fwlib.a

cd "$ROOT/idf-app"
if [ ! -f build-base/xtensa_rust_eval.bin ]; then
  idf.py -B build-base -D SDKCONFIG=build-base/sdkconfig build > build-base.log 2>&1 || { tail -40 build-base.log; exit 1; }
fi
WITH_RUST=$LIB idf.py -B build-rust-$OPT -D SDKCONFIG=build-rust-$OPT/sdkconfig build > build-rust-$OPT.log 2>&1 \
  || { grep -E 'error|multiple definition|undefined' build-rust-$OPT.log | head -40; exit 1; }
idf.py -B build-base -D SDKCONFIG=build-base/sdkconfig size > size-base.txt 2>&1
WITH_RUST=$LIB idf.py -B build-rust-$OPT -D SDKCONFIG=build-rust-$OPT/sdkconfig size > size-rust-$OPT.txt 2>&1
ls -l build-base/xtensa_rust_eval.bin build-rust-$OPT/xtensa_rust_eval.bin
grep -E 'Total image size|Flash Code|Flash Data|IRAM|DRAM' size-base.txt size-rust-$OPT.txt
