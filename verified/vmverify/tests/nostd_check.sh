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

# Builds the Rust side of the VM for `no_std` + `alloc` targets (Phase 5
# devices), from the sources as they are (no patching):
#
# - verified/spec without `std` (the verifier, no reference interpreter),
# - verified/core (always `no_std`), with and without `split-loop`,
# - verified/vmverify without `std`, with `device-runtime` (the allocator
#   and panic handler the VM supplies, src/device.rs), as the static library
#   device firmware links (Cargo profile `device`: panic = abort, LTO),
#
# for riscv32imac-unknown-none-elf (ESP32-C6, ESP32-H2: rv32imac, ilp32),
# riscv64imac-unknown-none-elf and thumbv7m-none-eabi (EC618: Cortex-M3,
# LDREX/STREX, so `alloc::sync` has native compare-and-swap). ESP32-C3
# (rv32imc, no atomics) is not built: vstd's `alloc` feature needs `alloc::sync` (atomic compare and
# swap), which riscv32imc-unknown-none-elf lacks (verified/core/PROGRESS.md,
# "Phase 5"). Install the targets with
# `rustup target add riscv32imac-unknown-none-elf riscv64imac-unknown-none-elf
# thumbv7m-none-eabi`.
#
# Usage: nostd_check.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFIED="$(cd "$HERE/../.." && pwd)"
TARGETS=(riscv32imac-unknown-none-elf riscv64imac-unknown-none-elf thumbv7m-none-eabi)
WORK="$VERIFIED/../build/vmverify-nostd"

for t in "${TARGETS[@]}"; do
  echo "== verified/spec, no_std ($t)"
  (cd "$VERIFIED/spec" && cargo build --release --lib --no-default-features --target "$t" --target-dir "$WORK/spec-target")
  echo "== verified/core, no_std ($t)"
  (cd "$VERIFIED/core" && cargo build --release --lib --target "$t" --target-dir "$WORK/core-target")
  echo "== verified/core, no_std, split loop ($t)"
  (cd "$VERIFIED/core" && cargo build --release --lib --features split-loop --target "$t" --target-dir "$WORK/core-target")
  echo "== verified/vmverify, no_std, device runtime ($t)"
  (cd "$VERIFIED/vmverify/staticlib" && cargo build --profile device --lib --no-default-features --features device-runtime \
      --target "$t" --target-dir "$WORK/vmverify-target")
  ls -la "$WORK/vmverify-target/$t/device/libtoit_rust.a"
  echo "== verified/vmverify, no_std, device runtime, split loop ($t)"
  (cd "$VERIFIED/vmverify/staticlib" && cargo build --profile device --lib --no-default-features --features device-runtime,split-loop \
      --target "$t" --target-dir "$WORK/vmverify-target")
  ls -la "$WORK/vmverify-target/$t/device/libtoit_rust.a"
done
echo "no_std build passed: spec, core and vmverify (device static library), whole and split loop, for ${TARGETS[*]}"
