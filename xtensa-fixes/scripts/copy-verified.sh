#!/usr/bin/env bash
# Copies verified/{core,spec,vmverify} of a worktree for the QEMU
# differential driver, changing only vmverify's crate types to `rlib`
# (its `staticlib` type needs an allocator and a panic handler at its own
# link step, which a no_std build for a std host does not have). The Rust
# code is otherwise the worktree's, unchanged.
# Usage: copy-verified.sh <worktree> <dest>
set -euo pipefail
WT=$1
DST=$2
rm -rf "$DST"
mkdir -p "$DST"
for c in core spec vmverify; do
  mkdir -p "$DST/$c"
  cp -r "$WT/verified/$c/src" "$WT/verified/$c/Cargo.toml" "$DST/$c/"
  [ -f "$WT/verified/$c/Cargo.lock" ] && cp "$WT/verified/$c/Cargo.lock" "$DST/$c/"
done
sed -i 's/^crate-type = \["staticlib", "rlib"\]$/crate-type = ["rlib"]/' "$DST/vmverify/Cargo.toml"
grep -n '^crate-type' "$DST/vmverify/Cargo.toml"
git -C "$WT" rev-parse HEAD > "$DST/SOURCE-COMMIT"
