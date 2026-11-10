#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public
# License as published by the Free Software Foundation; version
# 2.1 only.
#
# This library is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# Lesser General Public License for more details.
#
# The license can be found in the file `LICENSE` in the top level
# directory of this repository.

# Builds the verifier for a `no_std` + `alloc` target (Phase 5 devices):
# verified/spec without `std` (the verifier, no reference interpreter) and
# verified/vmverify without `std` (no panic catching, no timing), for
# bare-metal RISC-V targets (`rustup target add riscv32imac-unknown-none-elf
# riscv64imac-unknown-none-elf`).
#
# verified/core is not `no_std` yet (it uses no std API, but its lib.rs
# lacks `#![no_std]`, its vstd dependency uses vstd's default `std`
# feature, and as a dependency its `staticlib` crate type needs a panic
# handler and an allocator). vmverify links the core, so the check builds a
# copy of the three crates in which the core gets those changes
# (CORE_PATCH below); the spec crate is also checked on its own, unpatched.
# The core is also not 32-bit clean yet (machine.rs shifts usize values by
# 32; layout.rs has 64-bit constants), so vmverify is checked on a 64-bit
# no_std target (riscv64imac-unknown-none-elf) and the spec crate on both.
#
# Usage: nostd_check.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFIED="$(cd "$HERE/../.." && pwd)"
TARGET32=riscv32imac-unknown-none-elf
TARGET=riscv64imac-unknown-none-elf
WORK="$VERIFIED/../build/vmverify-nostd"

for t in "$TARGET32" "$TARGET"; do
  echo "== verified/spec, no_std ($t)"
  (cd "$VERIFIED/spec" && cargo build --release --lib --no-default-features --target "$t" --target-dir "$WORK/spec-target")
done

echo "== verified/vmverify, no_std ($TARGET), core patched in a copy"
rm -rf "$WORK/src"
mkdir -p "$WORK/src"
for c in core spec vmverify; do
  mkdir -p "$WORK/src/$c"
  cp -r "$VERIFIED/$c/src" "$VERIFIED/$c/Cargo.toml" "$WORK/src/$c/"
  [ -f "$VERIFIED/$c/Cargo.lock" ] && cp "$VERIFIED/$c/Cargo.lock" "$WORK/src/$c/"
done
# CORE_PATCH: the changes the core needs.
sed -i '0,/^#!\[/s//#![no_std]\n#![/' "$WORK/src/core/src/lib.rs"
sed -i 's/^vstd = "\(=[^"]*\)"$/vstd = { version = "\1", default-features = false, features = ["alloc"] }/' "$WORK/src/core/Cargo.toml"
sed -i 's/^crate-type = \["staticlib", "rlib"\]$/crate-type = ["rlib"]/' "$WORK/src/core/Cargo.toml"
grep -q '^#!\[no_std\]' "$WORK/src/core/src/lib.rs"
(cd "$WORK/src/vmverify" && cargo rustc --release --lib --no-default-features --target "$TARGET" \
    --target-dir "$WORK/vmverify-target" --crate-type rlib)
ls -la "$WORK/vmverify-target/$TARGET/release/"libtoit_vmverify.rlib
echo "no_std build passed: spec for $TARGET32 and $TARGET, vmverify for $TARGET"
