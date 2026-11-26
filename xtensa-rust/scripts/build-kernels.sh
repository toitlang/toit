#!/usr/bin/env bash
# Builds the three kernels (kernels/kernels.c, kernels/kernels.rs) with
#   Xtensa: ESP-IDF GCC esp-14.2.0_20241119 (-Os, -O2) vs the esp-rs fork
#           1.99.0.0 (opt-level s, z, 3), target xtensa-esp32-none-elf;
#   RISC-V: ESP-IDF GCC riscv32-esp-elf esp-14.2.0_20241119 vs upstream
#           rustc 1.99.1, riscv32imc-unknown-none-elf (the control).
# Writes objects, disassembly and a size table to kernels/out/.
set -euo pipefail
ROOT=/home/flo/work/opentoit-sandbox-artifacts/xtensa-rust
K=$ROOT/kernels
OUT=$K/out
mkdir -p "$OUT"
XT=$HOME/.espressif/tools/xtensa-esp-elf/esp-14.2.0_20241119/xtensa-esp-elf/bin
RV=$HOME/.espressif/tools/riscv32-esp-elf/esp-14.2.0_20241119/riscv32-esp-elf/bin

# GCC flags as ESP-IDF passes them for the esp32 (minus warnings/defines).
XT_CFLAGS="-mlongcalls -ffunction-sections -fdata-sections -fstrict-volatile-bitfields"
RV_CFLAGS="-march=rv32imc_zicsr_zifencei -mabi=ilp32 -ffunction-sections -fdata-sections"

for o in Os O2; do
  "$XT/xtensa-esp32-elf-gcc" -c -$o $XT_CFLAGS "$K/kernels.c" -o "$OUT/xt-gcc-$o.o"
  "$RV/riscv32-esp-elf-gcc" -c -$o $RV_CFLAGS "$K/kernels.c" -o "$OUT/rv-gcc-$o.o"
done

cd "$K/rust"
for o in s z 3; do
  CARGO_PROFILE_RELEASE_OPT_LEVEL=$o cargo +esp rustc --release -Zbuild-std=core \
    --target xtensa-esp32-none-elf --target-dir "$OUT/target-xt-$o" -- --emit=obj 2>&1 | tail -1
  cp "$(ls "$OUT"/target-xt-$o/xtensa-esp32-none-elf/release/{deps,build/kernels/*/out}/kernels-*.o 2>/dev/null | head -1)" "$OUT/xt-rust-$o.o"
  CARGO_PROFILE_RELEASE_OPT_LEVEL=$o cargo +1.99.1 rustc --release \
    --target riscv32imc-unknown-none-elf --target-dir "$OUT/target-rv-$o" -- --emit=obj 2>&1 | tail -1
  cp "$(ls "$OUT"/target-rv-$o/riscv32imc-unknown-none-elf/release/{deps,build/kernels/*/out}/kernels-*.o 2>/dev/null | head -1)" "$OUT/rv-rust-$o.o"
  # Control 2: the esp fork's rustc (LLVM 22.1.4) for RISC-V with build-std,
  # to separate "fork/LLVM version/build-std" from "Xtensa backend".
  CARGO_PROFILE_RELEASE_OPT_LEVEL=$o cargo +esp rustc --release -Zbuild-std=core \
    --target riscv32imc-unknown-none-elf --target-dir "$OUT/target-rvesp-$o" -- --emit=obj 2>&1 | tail -1
  cp "$(ls "$OUT"/target-rvesp-$o/riscv32imc-unknown-none-elf/release/{deps,build/kernels/*/out}/kernels-*.o 2>/dev/null | head -1)" "$OUT/rv-esprust-$o.o"
done

cd "$OUT"
{
  printf "%-16s %8s %8s %8s %8s %8s\n" object dispatch gather tagged total undef-panic
  for f in xt-gcc-Os xt-gcc-O2 xt-rust-s xt-rust-z xt-rust-3 rv-gcc-Os rv-gcc-O2 rv-rust-s rv-rust-z rv-rust-3 rv-esprust-s rv-esprust-z rv-esprust-3; do
    case $f in xt-*) P=$XT/xtensa-esp32-elf ;; *) P=$RV/riscv32-esp-elf ;; esac
    "$P-objdump" -d -r "$f.o" > "$f.dis"
    "$P-size" -A "$f.o" > "$f.size"
    # Function size = symbol size plus its literal-pool section (Xtensa).
    sz() {
      local s
      s=$("$P-nm" -S "$f.o" | awk -v n="$1" '$4 ~ n {print strtonum("0x"$2)}' | head -1)
      local lit
      lit=$(awk -v n="$1" '$1 ~ "^.literal.*"n {print $2}' "$f.size" | head -1)
      echo $(( ${s:-0} + ${lit:-0} ))
    }
    panics=$("$P-nm" -u "$f.o" | grep -c -i panic || true)
    # Total: all code, literal and read-only data sections (incl. jump tables).
    total=$(awk '$1 ~ /^\.(text|literal|rodata|srodata)/ {s += $2} END {print s}' "$f.size")
    printf "%-16s %8s %8s %8s %8s %8s\n" "$f" "$(sz dispatch)" "$(sz gather_sum)" "$(sz tagged_add)" "$total" "$panics"
  done
} | tee "$OUT/sizes.txt"
