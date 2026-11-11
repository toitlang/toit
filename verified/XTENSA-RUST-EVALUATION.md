# Rust on the classic ESP32 (Xtensa LX6): evaluation of the esp-rs fork

2026-11-11, from `sandbox-integration` 339225be. Data and scripts:
`/home/flo/work/opentoit-sandbox-artifacts/xtensa-rust/`. Nothing was
flashed; Xtensa code ran only under Espressif's QEMU.

## Installation and coexistence

The tree uses ESP-IDF v5.4.2 with GCC `esp-14.2.0_20241119`. `espup` 0.19.0
installed fork 1.99.0.0 in 66 s. The fork is upstream 1.99.0 plus 5 commits
that swap in Espressif's LLVM 22.1.4. It is built as channel nightly, and
with no prebuilt Xtensa `core` every build needs `-Zbuild-std`. The `esp`
toolchain coexists with the default `1.99.1`; `verus --version` is
unchanged.

| Installed | Size | Removal |
|---|---|---|
| `~/.cargo/bin/espup` | 12.8 MB | `rm` |
| `~/.rustup/toolchains/esp` (rustc 760 MB, LLVM 323 MB, GCC 1.1 GB duplicating `~/.espressif`) | 2.23 GB | `espup uninstall` or `rm -rf` |
| `~/.espup/esp-clang` (symlink) | 0 | `rm -rf ~/.espup` |
| `rust-src` on `nightly` (upstream test) | 84 MB | `rustup component remove rust-src --toolchain nightly` |
| `~/.espressif/tools/qemu-xtensa/esp_develop_9.2.2_20261109` | 73 MB | `rm -rf` |

## What built

| Crate / target | Result |
|---|---|
| `verified/spec` no_std, Xtensa s/z/3 | builds, no warnings or ICE; 22/23/72 s incl. build-std (RISC-V upstream: 16/14/23 s) |
| core + vmverify, Xtensa s/z/3, fat LTO, panic=abort | builds with an experiment patch (below), no ICE; 45-51 s (RISC-V 24-47 s) |
| upstream nightly 1.102 (LLVM 23.1.5), Xtensa | fails in `compiler_builtins`: `Cannot select: XtensaISD::PCREL_WRAPPER` |

`phase5/portability` has nothing new, so I patched a copy of the core
(`scripts/prepare-src.sh`). The patch is not Xtensa-specific:

- `#![no_std]`;
- `toit_spec` without default features (nostd_check.sh misses this);
- the std-gated `exec_step`;
- `core::f64::math` rounding;
- `size_of usize == 8`;
- 32/32-bit packing squeezed to 16/16, which is wrong.

The core still needs a real 32-bit port.

## Size

The size is measured in a dummy ELF with `--gc-sections`, in bytes of code,
literals and rodata. The RISC-V control is upstream 1.99.1 for
`riscv32imac`; vstd needs atomics.

| Config | spec | core | vmverify | core+alloc | builtins | strings | verifier only | interpreter only | both |
|---|---|---|---|---|---|---|---|---|---|
| Xtensa s | 42 186 | 81 290 | 10 262 | 7 781 | 14 175 | 11 937 | 74 019 | 96 716 | 168 376 |
| Xtensa z | 37 913 | 80 307 | 10 431 | 8 011 | 14 621 | 11 955 | 69 635 | 96 180 | 163 456 |
| Xtensa 3 | 56 858 | 84 452 | 9 296 | 7 011 | 16 020 | 11 671 | 86 115 | 102 257 | 186 053 |
| RISC-V s | 44 340 | 71 596 | 9 704 | 9 180 | 15 518 | 11 936 | 77 244 | 88 103 | 162 926 |
| RISC-V z | 36 944 | 64 100 | 8 972 | 12 828 | 15 626 | 11 954 | 70 446 | 83 673 | 151 076 |
| RISC-V 3 | 57 134 | 72 834 | 8 878 | 7 972 | 15 518 | 11 656 | 87 428 | 89 595 | 174 644 |

At z, Xtensa compared with RISC-V: the verifier is 1% smaller, the
interpreter 25% larger, both together 8% larger.

## Kernels: GCC vs Rust

The kernels are in `kernels/kernels.{c,rs}`, with the same checks in both
languages. The size columns count code plus literal pool, in bytes; "all" is
the whole object. "ADD" is the static instruction count for one ADD bytecode
(fetch, dispatch, handler and back edge). "iter" is instructions per gather
iteration.

| Compiler | dispatch | gather | tagged | all | ADD | iter |
|---|---|---|---|---|---|---|
| Xtensa GCC -Os | 506 | 43 | 46 | 655 | 22 | 8 |
| Xtensa GCC -O2 | 533 | 46 | 46 | 685 | 20 | 8 |
| Xtensa fork s | 637 | 69 | 51 | 840 | 24 | 7 |
| Xtensa fork z | 602 | 55 | 51 | 791 | 29 | 9 |
| Xtensa fork 3 | 620 | 50 | 69 | 803 | 22 | 8 |
| RISC-V GCC -Os | 594 | 42 | 36 | 732 | 26 | 10 |
| RISC-V GCC -O2 | 664 | 48 | 36 | 808 | | |
| RISC-V upstream s | 602 | 42 | 36 | 762 | 23 | 9 |
| RISC-V upstream z | 478 | 40 | 36 | 654 | ~30 | |
| RISC-V upstream 3 | 630 | 40 | 36 | 770 | | |
| RISC-V fork s/z/3 | 598/510/622 | 74/70/40 | 36 | 790/698/762 | | |

The next table counts executed instructions under QEMU `-icount`, as Rust
relative to the ESP-IDF -Os build of the C kernels:

| Fork opt | dispatch (220k bytecodes) | gather (1024) | tagged add (10k calls) |
|---|---|---|---|
| s | −17% | −11% | +28% |
| z | +4% | +11% | +28% |
| 3 | −18% | −11% | +33% |

The instruction counts above are not cycles. QEMU models no flash cache, no
`l32r` latency and no branch penalties.

On Xtensa, LLVM produces 21-28% more code than GCC -Os. On RISC-V it
produces 4-11% less, and 5% less with the fork and build-std. The gap is
therefore the Xtensa backend. Both compilers use the windowed ABI, jump
tables and density instructions. Only LLVM shows the following:

- Every call is `l32r`+`callx8` and carries no `ASM_EXPAND` relocation, so
  ld cannot relax it to `call8`. The library has 2154 such calls, about
  6.5 KB.
- It never emits `loop`, `extui` or `bbsi`. GCC uses `loop` at -O2.
- At z it spills a constant to the stack and reloads a literal in the hot
  loop.

In short, the Xtensa backend costs about 20% more code than GCC. The
dispatch loop is not worse: at s and 3 it runs 17-18% fewer instructions,
and 4% more at z.

## Integration

| Aspect | Finding |
|---|---|
| Linking into ESP-IDF v5.4.2 | `add_prebuilt_library`, no errors; windowed ABI matches; Rust always uses long calls (no `-mlongcalls` needed) |
| Duplicates | no multiple-definition errors; `memcpy`, `__adddf3`, `__divdi3` and the others resolve to the ESP32 ROM, not to `compiler_builtins`; only one Rust staticlib per firmware |
| Hooks | `#[panic_handler]` calls a C hook; `GlobalAlloc` forwards to `malloc`/`memalign` |
| IRAM | `#[link_section = ".iram1.x"]` yields `.iram1.x.literal`, which IDF places in IRAM |
| Firmware delta, verifier only (`idf.py size`, base image 156 686) | s +73 204 (code +59 396, data +13 808); z +69 780; 3 +85 236. The interpreter would add about 96 KB more |
| QEMU run | kernels match C; verifier rejects an empty table set cleanly |
| esp-rs/rust#278 | reproduced: `u16`/`u8` stack arguments (7th and later) are written with `s16i`/`s8i`, leaving garbage in the upper bytes (`0x61b11234`) |
| esp-rs/rust#283 | reproduced at run time: `&STATIC as usize & 0xff` returns the static's first byte (QEMU: expected 0x40, got 0xab) |
| over-aligned local | `align(32)` local placed at `a1+0`, not realigned |

## Maturity (`gh`, 2026-11-11)

| Topic | Facts |
|---|---|
| Cadence | every upstream minor release in 12 months matched within −2..+5 days (1.92.0.0 to 1.100.0.0); point releases skipped (1.93.1, 1.94.1, 1.96.1, 1.97.1, 1.99.1); every release since 1.98.0.0 marked prerelease; 1.100.0.0 has no x86_64-linux asset yet. LLVM one major version behind (22 vs 23). [releases](https://github.com/esp-rs/rust-build/releases) |
| Open bugs | esp-rs/rust 17 (10 of 14 from the last year); espressif/llvm-project 27 (14 of 21) |
| Wrong code (open) | [rust#283](https://github.com/esp-rs/rust/issues/283)/[llvm#139](https://github.com/espressif/llvm-project/issues/139); [rust#284](https://github.com/esp-rs/rust/issues/284)/[llvm#140](https://github.com/espressif/llvm-project/issues/140) realign without `movsp` corrupts window spills at s/z; [rust#286](https://github.com/esp-rs/rust/issues/286)/[llvm#142](https://github.com/espressif/llvm-project/issues/142) misaligned SP; [rust#278](https://github.com/esp-rs/rust/issues/278) ABI |
| ICEs (open) | "Cannot select": rust#275, #277 (regression since 1.94), #281, #282, llvm#141; register scavenger: llvm#134, #143 |
| codegen-units | [esp-hal#6789](https://github.com/esp-rs/esp-hal/issues/6789) tracks removing the workaround [esp-hal#6738](https://github.com/esp-rs/esp-hal/pull/6738) for [llvm#144](https://github.com/espressif/llvm-project/issues/144): a lone `global_asm!` unit is assembled for the generic CPU (fixed in LLVM 23) |
| Upstream | Rust: Xtensa targets at tier 3 (maintainers MabezDev, SergioGasquez); `asm!` merged ([rust#147302](https://github.com/rust-lang/rust/pull/147302), 2026-06-08); [rust#162828](https://github.com/rust-lang/rust/issues/162828) open. LLVM: Xtensa still in `LLVM_ALL_EXPERIMENTAL_TARGETS`; 24 PRs merged in 12 months (S2 June, S3 September, Clang ABI October 2026); [llvm#4](https://github.com/espressif/llvm-project/issues/4) "merge upstream" open since 2019. Missing: backend fixes (constant pools, scavenging, realignment), direct calls ([llvm#90](https://github.com/espressif/llvm-project/issues/90)), leaving experimental |
| Bus factor | about 1 per layer: rust-build has 35 of 38 commits in 12 months by Scott Mabin, who also wrote all 5 fork commits; the Xtensa backend has 62 of 74 by Andrei Safronov (both Espressif) |
| QEMU | espressif/qemu 9.2.2-20261109 installs without root and runs IDF firmware (`-machine esp32`) |
| Alternatives | `rustc_codegen_gcc`: no Xtensa support ([cg_gcc#49](https://github.com/rust-lang/rustc_codegen_gcc/issues/49) focuses on m68k). Rust to C: `rustc_codegen_clr` experimental and idle since 2025-10; `mrustc` reaches libstd 1.90 without borrow checking. Neither suits vstd/Verus code |

## Verdict

Not satisfactory for production firmware on the classic ESP32 today. It
works mechanically: no ICEs, a clean ESP-IDF link, correct QEMU runs, code
about 20% larger than GCC's (8% over RISC-V LLVM, 25% for the interpreter),
and a dispatch loop that runs as few instructions as GCC's. The blocking
reasons are about trust:

1. The release we would use has open wrong-code bugs: #283 (reproduced),
   #284/#140 (stack corruption at s/z) and #286/#142. New reports arrive
   faster than fixes.
2. Each layer has one maintainer. Every recent release is a prerelease, the
   LLVM is a major version behind, and builds need nightly `-Zbuild-std`.
3. There is no upstream fallback.

A verified sandbox built with a compiler that has known open miscompilations
loses most of its guarantee. The fork becomes "satisfactory with caveats"
once three things hold:

- a fork release fixes #283, #284 and #286;
- Toit pins that release;
- CI runs the core and verifier tests for Xtensa under Espressif QEMU on
  every toolchain change.

The caveats would then be +20% flash, the single maintainer, and no `u8`/`u16`
stack arguments across FFI.
