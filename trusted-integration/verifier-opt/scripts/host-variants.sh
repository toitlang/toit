#!/usr/bin/env bash
# x86-64 cross-check: host VM builds (build/host-vopt-<level>) whose Rust
# library approximates the device profile (release + fat LTO, one codegen
# unit, core at 3) with the verifier+glue packages (toit_spec,
# toit_vmverify) at the given level, from a patched copy of verified/
# (build/vopt-host/<level>/verified). Then callgrind inside
# toit_vmverify_verify on the five snapshots of esp32-build/images (as
# esp32-build/scripts/verify-ir.sh). Measurement only.
# Usage: host-variants.sh <worktree> <level>...
set -uo pipefail
WT=$1
shift
V=/home/flo/work/opentoit-sandbox-artifacts/trusted-integration/verifier-opt
IMG=/home/flo/work/opentoit-sandbox-artifacts/esp32-build/images
# shellcheck disable=SC1091
. "$WT/build/worktree-env.sh"
mkdir -p "$V/host"
build() {
  l=$1
  d="$WT/build/vopt-host/$l"
  mkdir -p "$d"
  rsync -a --exclude target "$WT/verified/" "$d/verified/"
  case $l in z|s) v="\"$l\"" ;; *) v=$l ;; esac
  C="$d/verified/vmverify/staticlib/Cargo.toml"
  perl -0pi -e 's/(\[profile\.release\]\npanic = "unwind"\nopt-level = 3\n)/${1}lto = true\ncodegen-units = 1\n/' "$C"
  printf '\n[profile.release.package.toit_spec]\nopt-level = %s\n\n[profile.release.package.toit_vmverify]\nopt-level = %s\n' "$v" "$v" >> "$C"
  B="$WT/build/host-vopt-$l"
  cmake -S "$WT" -B "$B" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_TOOLCHAIN_FILE="$WT/toolchains/host.cmake" \
    -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
    -DTOIT_VERIFIED_CORE_SOURCE_DIR="$d/verified" > "$V/host/cmake-$l.log" 2>&1 || { echo "$l: cmake failed"; return; }
  ninja -C "$B" toit.run > "$V/host/build-$l.log" 2>&1 || { echo "$l: build failed"; return; }
}
for l in "$@"; do build "$l" & done
wait
for l in "$@"; do
  BIN=$(find "$WT/build/host-vopt-$l" -name toit.run -type f -perm -u+x | head -1)
  for t in fold format map deque list; do
    s="$IMG/$t-test.snapshot"
    TOIT_VERIFY_TIME=1 valgrind --tool=callgrind --toggle-collect=toit_vmverify_verify --callgrind-out-file="$V/host/v.$l.$t" \
      "$BIN" --verify --require-certificate "$s" > "$V/host/run.$l.$t.log" 2>&1 &
  done
done
wait
for l in "$@"; do
  for t in fold format map deque list; do
    echo "$l $t verify_ir=$(awk '/^summary:/ { print $2 }' "$V/host/v.$l.$t") $(grep -c accepted "$V/host/run.$l.$t.log")"
  done
done
