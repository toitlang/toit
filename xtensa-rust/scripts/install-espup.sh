#!/usr/bin/env bash
# Installs the Espressif Xtensa Rust fork (esp-rs/rust-build v1.99.0.0) for
# the classic ESP32 only, with the GCC version the Toit tree uses
# (esp-14.2.0_20241119) for linking. Records time and output.
set -euo pipefail
OUT=/home/flo/work/opentoit-sandbox-artifacts/xtensa-rust
start=$(date +%s)
~/.cargo/bin/espup install --targets esp32 --toolchain-version 1.99.0.0 \
  -c 14.2.0_20241119 --export-file "$OUT/export-esp.sh" > "$OUT/espup-install.log" 2>&1
end=$(date +%s)
echo "espup install took $((end - start)) s" | tee -a "$OUT/espup-install.log"
