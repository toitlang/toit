#!/usr/bin/env bash
# Builds verified/spec (no_std + alloc: the verifier) for
#   xtensa-esp32-none-elf with the esp-rs fork (build-std core,alloc) and
#   riscv32imac-unknown-none-elf with upstream 1.99.1 (control),
# at opt-level s, z, 3 with LTO-irrelevant rlib output; records wall time
# and the full compiler output.
# Usage: build-spec.sh <worktree>
set -euo pipefail
WT=$1
OUT=/home/flo/work/opentoit-sandbox-artifacts/xtensa-rust/spec-build
mkdir -p "$OUT"
cd "$WT/verified/spec"
for o in s z 3; do
  rm -rf "$OUT/target-xt-$o"
  start=$(date +%s%N)
  CARGO_PROFILE_RELEASE_OPT_LEVEL=$o CARGO_PROFILE_RELEASE_PANIC=abort CARGO_PROFILE_RELEASE_DEBUG=0 \
    cargo +esp build --release --lib --no-default-features -Zbuild-std=core,alloc \
    --target xtensa-esp32-none-elf --target-dir "$OUT/target-xt-$o" > "$OUT/xt-$o.log" 2>&1 || echo "FAILED xt $o"
  end=$(date +%s%N)
  echo "xt-$o: $(( (end - start) / 1000000 )) ms, warnings: $(grep -c '^warning' "$OUT/xt-$o.log" || true)"
  rm -rf "$OUT/target-rv-$o"
  start=$(date +%s%N)
  CARGO_PROFILE_RELEASE_OPT_LEVEL=$o CARGO_PROFILE_RELEASE_PANIC=abort CARGO_PROFILE_RELEASE_DEBUG=0 \
    cargo +1.99.1 build --release --lib --no-default-features \
    --target riscv32imac-unknown-none-elf --target-dir "$OUT/target-rv-$o" > "$OUT/rv-$o.log" 2>&1 || echo "FAILED rv $o"
  end=$(date +%s%N)
  echo "rv-$o: $(( (end - start) / 1000000 )) ms, warnings: $(grep -c '^warning' "$OUT/rv-$o.log" || true)"
done
