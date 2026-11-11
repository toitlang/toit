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

# Builds a Verus installation for another Rust target, so that crates can be
# verified with that target's `usize`.
#
# Verus fixes the width of `usize` from the crate's `global size_of usize`
# declaration and checks that declaration with a compile-time assertion
# against the target it compiles for; the installed Verus ships its support
# libraries (verus_builtin, vstd) for the host only and loads them from the
# directory of its executable. Verifying the core for 32-bit words
# (verified/check.sh --word32) therefore runs a copy of Verus (OUT/verus,
# next to verus_builtin and vstd built here for the target, from the vstd
# sources of the version the core's Cargo.toml pins, crates.io) with
# `--target TARGET`.
#
# vstd itself is verified for the target here (its lemmas about `usize` are
# then checked with that width too) unless --no-verify is given.
#
# Usage: verified/tools/verus_target.sh [--no-verify] TARGET OUT-DIR
# Prints the path of the Verus executable to run on success. The result is
# cached in OUT-DIR (keyed by the Verus version, vstd version and target).

set -euo pipefail

VERIFY=1
if [ "${1:-}" = "--no-verify" ]; then
  VERIFY=0
  shift
fi
TARGET="${1:?target}"
OUT="${2:?out dir}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

VSTD_VERSION="0.0.0-2026-11-01-0251"
VERUS_BIN="$(readlink -f "$(command -v verus)")"
VERUS_DIR="$(dirname "$VERUS_BIN")"
VERUS_VERSION="$(verus --version 2>/dev/null | sed -n 's/^ *Version: //p')"
TOOLCHAIN="$(sed -n 's/.*"toolchain": "\([^ "]*\).*/\1/p' "$VERUS_DIR/version.json")"
STAMP="$VERUS_VERSION $VSTD_VERSION $TARGET verify=$VERIFY"

log() { echo "$*" >&2; }

if [ -f "$OUT/stamp" ] && [ "$(cat "$OUT/stamp")" = "$STAMP" ] && [ -x "$OUT/verus" ]; then
  echo "$OUT/verus"
  exit 0
fi

find_registry() {
  for d in "${CARGO_HOME:-$HOME/.cargo}"/registry/src/*/; do
    if [ -d "$d/vstd-$VSTD_VERSION" ] && [ -d "$d/verus_builtin-$VSTD_VERSION" ]; then
      echo "$d"
      return
    fi
  done
}
REGISTRY="$(find_registry)"
if [ -z "$REGISTRY" ]; then
  # Fetch the pinned sources through cargo (the core's lock file pins them).
  (cd "$(dirname "${BASH_SOURCE[0]}")/../core" && cargo fetch > /dev/null 2>&1) || true
  REGISTRY="$(find_registry)"
fi
if [ -z "$REGISTRY" ]; then
  log "vstd-$VSTD_VERSION sources not found in the cargo registry"
  exit 1
fi
if ! rustup "+$TOOLCHAIN" target list --installed 2>/dev/null | grep -qx "$TARGET"; then
  log "Rust target $TARGET is not installed for $TOOLCHAIN: rustup +$TOOLCHAIN target add $TARGET"
  exit 1
fi

log "Building a Verus installation for $TARGET in $OUT"
rm -f "$OUT/stamp"
# The executables are copied (they locate their libraries through their own
# path), the proc macros and the solver are host code and are linked.
cp "$VERUS_DIR/verus" "$VERUS_DIR/rust_verify" "$VERUS_DIR/version.json" "$OUT/"
for f in z3 libverus_builtin_macros.so libverus_state_machines_macros.so; do
  ln -sf "$VERUS_DIR/$f" "$OUT/$f"
done
[ -e "$VERUS_DIR/cvc5" ] && ln -sf "$VERUS_DIR/cvc5" "$OUT/cvc5"

# verus_builtin: as Verus' own build compiles it (ghost items kept).
RUSTC_BOOTSTRAP=1 rustc "+$TOOLCHAIN" --edition 2018 --crate-type rlib --crate-name verus_builtin \
  --cfg verus_keep_ghost --target "$TARGET" -O \
  "$REGISTRY/verus_builtin-$VSTD_VERSION/src/lib.rs" -o "$OUT/libverus_builtin.rlib" >&2

VERIFY_ARGS=()
if [ "$VERIFY" = 0 ]; then VERIFY_ARGS+=(--no-verify); fi
# vstd with its default features (std, alloc), as the host vstd.
(cd "$REGISTRY/vstd-$VSTD_VERSION" && \
  RUST_MIN_STACK=$((10 * 1024 * 1024)) verus --is-vstd --crate-type=lib --crate-name vstd \
    --edition=2018 --target "$TARGET" -L "$OUT" \
    --extern verus_builtin="$OUT/libverus_builtin.rlib" \
    --extern verus_builtin_macros="$VERUS_DIR/libverus_builtin_macros.so" \
    --extern verus_state_machines_macros="$VERUS_DIR/libverus_state_machines_macros.so" \
    --cfg 'feature="std"' --cfg 'feature="alloc"' \
    "${VERIFY_ARGS[@]}" --export "$OUT/vstd.vir" --compile -o "$OUT/libvstd.rlib" \
    vstd.rs) > "$OUT/vstd.log" 2>&1 || {
  tail -40 "$OUT/vstd.log" >&2
  log "building vstd for $TARGET failed (log: $OUT/vstd.log)"
  exit 1
}
grep -E '^verification results' "$OUT/vstd.log" >&2 || true
echo "$STAMP" > "$OUT/stamp"
echo "$OUT/verus"
