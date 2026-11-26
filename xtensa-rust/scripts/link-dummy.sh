#!/usr/bin/env bash
# Builds the device static library (devlib: verifier + core, no_std, LTO,
# panic=abort, codegen-units=1) and links it into a dummy ELF with
# --gc-sections, keeping the verifier entry, the interpreter entry or both.
# Reports text (code + literal pools) and rodata by component from the
# linker map.
#
# Usage: link-dummy.sh <xt|rv> <s|z|3> <verify|run|both>
#   xt: xtensa-esp32-none-elf with the esp-rs fork (+esp, build-std),
#       linked with ESP-IDF's xtensa-esp32-elf-gcc esp-14.2.0_20241119;
#   rv: riscv32imac-unknown-none-elf with upstream 1.99.1 (RUSTC_BOOTSTRAP
#       for the core's core_float_math feature), linked with riscv32-esp-elf.
set -euo pipefail
ARCH=$1
OPT=$2
KEEP=$3
ROOT=/home/flo/work/opentoit-sandbox-artifacts/xtensa-rust
OUT=$ROOT/link/out/$ARCH-$OPT
mkdir -p "$OUT"
case $ARCH in
  xt)
    TARGET=xtensa-esp32-none-elf
    TC=+esp
    BUILDSTD=(-Zbuild-std=core,alloc)
    P=$HOME/.espressif/tools/xtensa-esp-elf/esp-14.2.0_20241119/xtensa-esp-elf/bin/xtensa-esp32-elf
    CFLAGS="-Os -mlongcalls -ffunction-sections -fdata-sections"
    ;;
  rv)
    TARGET=riscv32imac-unknown-none-elf
    TC=+1.99.1
    BUILDSTD=()
    export RUSTC_BOOTSTRAP=1
    P=$HOME/.espressif/tools/riscv32-esp-elf/esp-14.2.0_20241119/riscv32-esp-elf/bin/riscv32-esp-elf
    CFLAGS="-Os -march=rv32imac_zicsr_zifencei -mabi=ilp32 -ffunction-sections -fdata-sections"
    ;;
esac

LIB=$ROOT/devlib-target/$ARCH-$OPT/$TARGET/release/libtoit_devlib.a
if [ ! -f "$LIB" ]; then
  start=$(date +%s%N)
  (cd "$ROOT/devlib" && CARGO_PROFILE_RELEASE_OPT_LEVEL=$OPT cargo $TC build --release "${BUILDSTD[@]}" \
      --target $TARGET --target-dir "$ROOT/devlib-target/$ARCH-$OPT") > "$OUT/build.log" 2>&1
  end=$(date +%s%N)
  echo "build $ARCH-$OPT: $(( (end - start) / 1000000 )) ms, $(grep -c '^warning' "$OUT/build.log" || true) warning lines" | tee "$OUT/build-time.txt"
fi

case $KEEP in
  verify) DEFS=-DKEEP_VERIFY ;;
  run) DEFS=-DKEEP_RUN ;;
  both) DEFS="-DKEEP_VERIFY -DKEEP_RUN" ;;
esac
"$P-gcc" $CFLAGS $DEFS -c "$ROOT/link/dummy.c" -o "$OUT/dummy-$KEEP.o"
"$P-gcc" $CFLAGS -c "$ROOT/link/stubs.c" -o "$OUT/stubs.o"
ELF=$OUT/$KEEP.elf
"$P-gcc" $CFLAGS -nostartfiles -e main -Wl,--gc-sections -Wl,-Map="$OUT/$KEEP.map" \
  "$OUT/dummy-$KEEP.o" "$OUT/stubs.o" "$LIB" -lm -lc -lgcc -o "$ELF" 2> "$OUT/$KEEP.link.log" || {
  cat "$OUT/$KEEP.link.log"; exit 1; }

# Input sections from the map (after "Linker script and memory map").
awk '
  /^Linker script and memory map/ { on = 1; next }
  !on { next }
  pending != "" {
    if ($1 ~ /^0x/ && NF >= 3) { print pending "\t" strtonum($2) "\t" $3 }
    pending = ""; next
  }
  /^ \.(text|literal|rodata|srodata|sdata2|iram1|init\.literal)[^ ]*/ {
    if (NF >= 4 && $2 ~ /^0x/) { print $1 "\t" strtonum($3) "\t" $4 }
    else if (NF == 1) { pending = $1 }
  }
' "$OUT/$KEEP.map" | awk -F'\t' '$2 > 0' > "$OUT/$KEEP.sections.tsv"

# Demangle the symbol part of each section name.
cut -f1 "$OUT/$KEEP.sections.tsv" | sed -E 's/^\.(text|literal|rodata|srodata)\.//' \
  | "$P-c++filt" > "$OUT/$KEEP.demangled.txt"
paste "$OUT/$KEEP.sections.tsv" "$OUT/$KEEP.demangled.txt" | awk -F'\t' '
  function crate(d,    best, bp, n, i, p) {
    n = split("toit_vmverify toit_verified_core toit_spec toit_devlib vstd alloc core compiler_builtins", cs, " ")
    best = ""; bp = 1e9
    # v0 demangling prints "crate[hash]::path", legacy "crate::path".
    for (i = 1; i <= n; i++) {
      p = match(d, "(^|[^a-z_])" cs[i] "(\\[|::)")
      if (p > 0 && p < bp) { bp = p; best = cs[i] }
    }
    # Generic std code instantiated for our types counts as ours.
    for (i = 1; i <= 4; i++) if (match(d, cs[i] "(\\[|::)") > 0 && (best == "core" || best == "alloc")) best = cs[i]
    # Exported C entry points.
    if (best == "" && d ~ /^toit_vmverify_/) best = "toit_vmverify"
    if (best == "" && d ~ /^toit_(v2_|vcore_)/) best = "toit_verified_core"
    if (best == "" && d ~ /^str1\.|^\.L/) best = "rust strings/anon"
    return best
  }
  {
    sec = $1; size = $2; file = $3; dem = $4
    kind = (sec ~ /^\.(rodata|srodata|sdata2)/) ? "rodata" : "text"
    if (file ~ /dummy|stubs/) comp = "C dummy+stubs"
    else if (file ~ /libtoit_devlib\.a/) {
      if (file ~ /compiler_builtins/) comp = "compiler_builtins"
      else { c = crate(dem); comp = (c == "") ? "rust (unnamed/anon)" : c }
    }
    else if (file ~ /libm\.a/) comp = "libm (C)"
    else if (file ~ /libc\.a/) comp = "libc (C)"
    else if (file ~ /libgcc\.a/) comp = "libgcc (C)"
    else comp = "other"
    t[comp, kind] += size; comps[comp] = 1; tot[kind] += size
  }
  END {
    printf "%-22s %9s %9s %9s\n", "component", "text", "rodata", "sum"
    for (c in comps) printf "%-22s %9d %9d %9d\n", c, t[c, "text"], t[c, "rodata"], t[c, "text"] + t[c, "rodata"] | "sort -k4 -n -r"
    close("sort -k4 -n -r")
    printf "%-22s %9d %9d %9d\n", "TOTAL", tot["text"], tot["rodata"], tot["text"] + tot["rodata"]
  }
' | tee "$OUT/$KEEP.components.txt"
"$P-size" "$ELF" | tee "$OUT/$KEEP.size.txt"
