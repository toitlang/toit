#!/usr/bin/env bash
# Builds the device static library (verified/vmverify, profile `device`,
# no_std, device-runtime) for xtensa-esp32-none-elf with the esp fork,
# straight from a worktree, with no source patch. Writes the library, the
# disassembly of every member and the bitcode that codegen consumed
# (-C save-temps: *.rcgu.opt.bc per crate, or the fat-LTO module).
#
# Usage: build-devlib.sh <worktree> <name> [extra RUSTFLAGS...]
#   env OPT=3|s|z   core opt-level (default 3; toit_spec stays z per profile)
#   env LTO=1       fat LTO (`cargo rustc --crate-type staticlib`): the
#                   profile's `lto = true` is dropped by Cargo because the
#                   crate types are staticlib + rlib.
#   env FEATURES    (default device-runtime)
#   env RUSTC_WRAPPER_TC  toolchain (default esp)
set -euo pipefail
WT=$1
NAME=$2
shift 2
ROOT=/home/flo/work/opentoit-sandbox-artifacts/xtensa-fixes
OUT=$ROOT/devlib/$NAME
TD=$ROOT/devlib/target-$NAME
rm -rf "$OUT"
mkdir -p "$OUT"
export PATH="$HOME/.rustup/toolchains/esp/xtensa-esp-elf/esp-14.2.0_20241119/xtensa-esp-elf/bin:$PATH"
OPT=${OPT:-3}
FEATURES=${FEATURES:-device-runtime}
TC=${TC:-esp}
export CARGO_PROFILE_DEVICE_OPT_LEVEL=$OPT
export RUSTFLAGS="-C save-temps ${*:-}"
cd "$WT/verified/vmverify"
COMMON=(--profile device --no-default-features --features "$FEATURES"
  -Zbuild-std=core,alloc --target xtensa-esp32-none-elf --target-dir "$TD")
start=$(date +%s)
if [ "${LTO:-0}" = 1 ]; then
  cargo +$TC rustc "${COMMON[@]}" --lib --crate-type staticlib -- -C lto=fat > "$OUT/build.log" 2>&1 \
    || { tail -30 "$OUT/build.log"; exit 1; }
else
  cargo +$TC build "${COMMON[@]}" > "$OUT/build.log" 2>&1 || { tail -30 "$OUT/build.log"; exit 1; }
fi
end=$(date +%s)
echo "build $NAME (OPT=$OPT LTO=${LTO:-0} RUSTFLAGS=$RUSTFLAGS): $((end - start)) s" | tee "$OUT/build-time.txt"
LIB=$TD/xtensa-esp32-none-elf/device/libtoit_vmverify.a
cp "$LIB" "$OUT/"
P=xtensa-esp32-elf
mkdir -p "$OUT/obj" "$OUT/bc"
(cd "$OUT/obj" && "$P-ar" x "$OUT/libtoit_vmverify.a")
# The bitcode codegen consumed (the newest of each kind).
find "$TD/xtensa-esp32-none-elf" \( -name "*.rcgu.bc" -o -name "*lto*.bc" \) -newermt "@$start" -exec cp {} "$OUT/bc/" \;
for o in "$OUT"/obj/*.o; do
  "$P-objdump" -d --no-show-raw-insn "$o"
done > "$OUT/all.dis"
"$P-size" "$OUT"/obj/*.o | tee "$OUT/size.txt" | awk 'NR > 1 { t += $1 } END { print "total text", t }'
