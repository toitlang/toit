#!/usr/bin/env bash
# Copies verified/{core,spec,vmverify} from a worktree to src/ and applies
# the no_std patch of verified/vmverify/tests/nostd_check.sh (CORE_PATCH) to
# the core. Experiment-only; nothing goes back to the repository.
# Usage: prepare-src.sh <worktree>
set -euo pipefail
WT=$1
WORK=/home/flo/work/opentoit-sandbox-artifacts/xtensa-rust/src
rm -rf "$WORK"
mkdir -p "$WORK"
for c in core spec vmverify; do
  mkdir -p "$WORK/$c"
  cp -r "$WT/verified/$c/src" "$WT/verified/$c/Cargo.toml" "$WORK/$c/"
  [ -f "$WT/verified/$c/Cargo.lock" ] && cp "$WT/verified/$c/Cargo.lock" "$WORK/$c/"
done
sed -i '0,/^#!\[/s//#![no_std]\n#![/' "$WORK/core/src/lib.rs"
sed -i 's/^vstd = "\(=[^"]*\)"$/vstd = { version = "\1", default-features = false, features = ["alloc"] }/' "$WORK/core/Cargo.toml"
sed -i 's/^crate-type = \["staticlib", "rlib"\]$/crate-type = ["rlib"]/' "$WORK/core/Cargo.toml" "$WORK/vmverify/Cargo.toml"
# Not in nostd_check.sh's CORE_PATCH (it predates the core's dependency on
# toit_spec): without this, feature unification turns on toit_spec/std and
# with it vstd/std.
sed -i 's|^toit_spec = { path = "../spec" }$|toit_spec = { path = "../spec", default-features = false }|' "$WORK/core/Cargo.toml"
grep -q '^#!\[no_std\]' "$WORK/core/src/lib.rs"
grep -q 'toit_spec = { path = "../spec", default-features = false }' "$WORK/core/Cargo.toml"

# EXPERIMENT_32BIT_PATCH (compile-only; NOT semantically correct): the core
# assumes 64-bit words. Halve the packed "two 32-bit halves in a word"
# encodings (bci/height, fin count) to 16/16 bits on 32-bit targets, drop
# the Verus usize==8 assumption, give the core the float rounding functions
# from core::f64::math (nightly feature; the esp fork is a nightly build,
# upstream needs RUSTC_BOOTSTRAP=1), and compile the spec's exec_step (the
# core's double helpers) without std.
if [ "${PATCH32:-1}" = 1 ]; then
  C=$WORK/core/src
  sed -i 's/^global size_of usize == 8;/global size_of usize == 4;/' "$C/abs.rs"
  sed -i 's/^pub const STACK_FIN_COUNT_SHIFT: usize = 32;/pub const STACK_FIN_COUNT_SHIFT: usize = (usize::BITS \/ 2) as usize;/' "$C/layout.rs"
  for f in alloc.rs calls.rs machine.rs unwind.rs exec.rs; do
    sed -i 's/>> 32usize/>> (usize::BITS \/ 2)/g; s/>> 32\b/>> (usize::BITS \/ 2)/g; s/<< 32\b/<< (usize::BITS \/ 2)/g; s/0xffff_ffff\([^_]\|$\)/(usize::MAX >> (usize::BITS \/ 2))\1/g; s/0x1_0000_0000\b/(1usize << (usize::BITS \/ 2))/g' "$C/$f"
  done
  # 64-bit constants: the accept marker, a frame-count limit, blob lengths.
  sed -i 's/^pub const V2_ACCEPTED: usize = 0x56455249464945;/pub const V2_ACCEPTED: usize = 0x56455249;/' "$C/layout.rs"
  sed -i 's/0x100_0000_0000\b/(usize::MAX >> 8)/g' "$C/machine.rs"
  sed -i 's/0x4000_0000_0000_0000\b/(usize::MAX >> 2)/g' "$C/prims/blob.rs"
  sed -i '0,/^#!\[no_std\]/s//#![no_std]\n#![feature(core_float_math)]/' "$C/lib.rs"
  sed -i 's/=> a\.sqrt()/=> core::f64::math::sqrt(a)/; s/=> a\.ceil()/=> core::f64::math::ceil(a)/; s/=> a\.floor()/=> core::f64::math::floor(a)/; s/=> a\.trunc()/=> core::f64::math::trunc(a)/' "$C/prims/fp.rs"
  S=$WORK/spec/src/lib.rs
  sed -i '/^#\[cfg(any(feature = "std", verus_keep_ghost))\]$/{N;s/^#\[cfg(any(feature = "std", verus_keep_ghost))\]\npub mod exec_step;/pub mod exec_step;/}' "$S"
  grep -q '^pub mod exec_step;' "$S"
  # exec_step's x_compare_mixed calls interp::exec::compare_mixed (std-only
  # module, but the function itself is pure core): copy Num, compare_ints and
  # compare_mixed verbatim into interp_min.rs.
  E=$WORK/spec/src/interp/exec.rs
  {
    echo '// Copied verbatim from interp/exec.rs by prepare-src.sh (experiment).'
    sed -n '/^pub enum Num {/,/^}/p' "$E" | sed '1i #[derive(Clone, Copy)]'
    sed -n '/^pub fn compare_ints(/,/^}/p' "$E"
    sed -n '/^pub fn compare_mixed(/,/^}/p' "$E"
  } > "$WORK/spec/src/interp_min.rs"
  sed -i 's/^pub mod exec_step;/pub mod exec_step;\npub mod interp_min;/' "$S"
  sed -i 's/crate::interp::exec::/crate::interp_min::/g' "$WORK/spec/src/exec_step.rs"
fi
echo "prepared $WORK"
