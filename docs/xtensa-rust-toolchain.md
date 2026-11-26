<!-- Copyright (C) 2026 Toit contributors. -->

# The Xtensa Rust toolchain

The verified core and the format-2 verifier (`verified/`) are Rust. On the
Xtensa chips (classic ESP32, ESP32-S3) the firmware builds them with the
Toit fork of Espressif's Rust toolchain, installed as the rustup toolchain
`toit-esp`. This document says what the fork is, why we carry it, how to
build and install it, and how to move it to a newer upstream release.

## What and why

Upstream Rust has no usable Xtensa support: the Xtensa targets need
Espressif's LLVM fork. The esp-rs project publishes a Rust fork built on it
([esp-rs/rust](https://github.com/esp-rs/rust), installed with `espup` as
`+esp`). verified/XTENSA-RUST-EVALUATION.md and verified/XTENSA-RUST-FIXES.md
evaluated release 1.99.0.0: it builds our crates and links into ESP-IDF,
but it has open wrong-code bugs, without maintainer response for weeks to
months. We fixed four of them (with LLVM lit tests and a Rust ABI test) and
carry the fixes in our own forks until upstream takes them:

| Repository | Branch | Tag |
|---|---|---|
| [toitlang/rust](https://github.com/toitlang/rust) (fork of esp-rs/rust) | `toit/esp-1.99.0.0` | `toit-esp-1.99.0.0-1` |
| [toitlang/llvm-project](https://github.com/toitlang/llvm-project) (fork of espressif/llvm-project) | `toit/esp-1.99.0.0` | `toit-esp-1.99.0.0-1` |

Pinned commits:

| | Base (upstream) | Head (tag) |
|---|---|---|
| Rust | `4e103d068fa7229264752a009230d09b570ffa6d` = esp-rs/rust `esp-1.99.0.0` (upstream 1.99.0 plus five esp-rs commits) | `ba718ce8fcec49b9ae8efc45685da90e47fed044` |
| LLVM (`src/llvm-project`) | `3eeb0284bff29f39a73d54271098101e4ffd7a9f` = the submodule pin of `esp-1.99.0.0`: espressif/llvm-project tag `esp-22.1.4_20260825` (`3f19539fb25d`) plus two commits of MabezDev/llvm-project `esp-22.1.4_20260825-xtensa-r32` | `3a914c7e8dad809cd066eaa231342e338fbf6f24` |

`rustc +toit-esp -V` prints
`rustc 1.99.0-nightly (ba718ce8f 2026-11-26) (toit-esp-1.99.0.0-1)`; LLVM is
22.1.4. The build checks the release in parentheses (below).

## The patches

| Commit | Upstream issue | Bug | Test |
|---|---|---|---|
| LLVM `7c1e0670` [Xtensa] Do not read memory at a literal's value for narrowed literal loads | [espressif/llvm-project#139](https://github.com/espressif/llvm-project/issues/139), [esp-rs/rust#283](https://github.com/esp-rs/rust/issues/283) | part of a global's address (`& 0xff`, `>> 16`, ...) loads memory at the global | `constantpool-narrow-load.ll` |
| LLVM `450eac2e` [Xtensa] Keep the stack pointer 16-byte aligned at calls | [espressif/llvm-project#142](https://github.com/espressif/llvm-project/issues/142), [esp-rs/rust#286](https://github.com/esp-rs/rust/issues/286) | with a frame pointer or a variable-size alloca, SP is 4/8/12 mod 16 in the callee | `call-frame-align.ll` |
| LLVM `ffd977c2` [Xtensa] Realign the windowed-ABI stack with MOVSP | [espressif/llvm-project#140](https://github.com/espressif/llvm-project/issues/140), [esp-rs/rust#284](https://github.com/esp-rs/rust/issues/284) | realignment with `add a1` (window spills corrupt the caller), align 32 not realigned, incoming stack arguments read at a wrong offset | `stack-realign-windowed.ll`, `stack-realign-windowed-vla.ll` |
| LLVM `3a914c7e` [Xtensa] Round byval argument sizes up to a multiple of 4 | LLVM half of [esp-rs/rust#278](https://github.com/esp-rs/rust/issues/278) (= llvm/llvm-project#228365) | a 5-7 byte byval argument misaligns the next stack argument | `calling-conv-byval-odd-size.ll` |
| Rust `44c26a58` Xtensa: pass narrow integers on the stack as extended words | [esp-rs/rust#278](https://github.com/esp-rs/rust/issues/278) | `u8`/`u16`/`i8`/`i16` arguments in stack positions of `extern "C"` calls are stored with `s8i`/`s16i`, the rest of the word is garbage | `tests/codegen-llvm/xtensa-abi/xtensa-stack-args.rs` |
| Rust `550b1885` | | the LLVM submodule points at toitlang/llvm-project | |
| Rust `ba718ce8` | | `toit/build.sh`, `toit/README.md` (the build recipe) | |

The commit messages have a minimal reproduction each. The LLVM commits are
the patches of the fix round (`opentoit-sandbox-artifacts/xtensa-fixes/patches`,
upstream PR drafts, not sent, in `.../upstream-drafts`). The Rust commit is
narrower than that round's untested `rustc-278.patch`: only integers below
32 bits become direct extended arguments; wider scalars stay byval as
before, because how LLVM would place a direct `i64`/`f64` on the stack was
not checked against GCC.

## Building and installing

On a Linux x86-64 host with git, Python 3, CMake >= 3.20, Ninja, a C++17
compiler (`cc`/`c++`), curl and rustup (optional: `ld.lld`), no root needed:

    git clone --branch toit-esp-1.99.0.0-1 --depth 1 https://github.com/toitlang/rust
    cd rust
    toit/build.sh            # installs into ~/.local/share/toit-rust/toit-esp-1.99.0.0-1

The script fetches the pinned LLVM, builds LLVM (X86, RISCV and Xtensa),
rustc (stage 2), the host `std`, `cargo` and `rust-src`, installs them into
the prefix (an optional argument) and runs
`rustup toolchain link toit-esp <prefix>`. Details and options:
`toit/README.md` in the fork. There is no prebuilt `core` for Xtensa; the
firmware build compiles `core` and `alloc` with `-Zbuild-std=core,alloc`.
ESP-IDF's GCC links the firmware; the toolchain contains no GCC.

Measured on this project's 32-core development machine (12 jobs, 2 LLVM
link jobs, shared with other work): 51 minutes for a full build (LLVM and LLD
33 of them; a rebuild after a Rust-only change took 25 minutes), at most
8.5 GB of memory for all build processes together (sampled every 15 s),
a 14 GB build directory plus 3 GB of sources, 592 MB installed (121 MB as
a tar.xz).

No prebuilt binaries are published yet: every developer and CI runner
builds the toolchain once per release with `toit/build.sh`. A CI job that
publishes it (for example as a release asset of toitlang/rust, installed
with `rustup toolchain link`) would need: a Linux x86-64 runner with about
20 GB of free disk and 16 GB of memory, 1-3 hours depending on the cores
(51 minutes with 12 jobs here), network access to github.com,
static.rust-lang.org and crates.io, and it would upload one 121 MB tar.xz
of the installed prefix (592 MB unpacked; 115 MB without `rust-src`, which
the build needs, though).

## Use in the build

`toolchains/idf/components/toit/CMakeLists.txt` selects, for the classic
ESP32 and the S3 with `CONFIG_TOIT_VERIFIED_CORE`,
`cargo +${TOIT_XTENSA_RUST_TOOLCHAIN}` (default `toit-esp`) with
`-Zbuild-std=core,alloc` and the targets `xtensa-esp32-none-elf` /
`xtensa-esp32s3-none-elf`. At configure time it runs
`rustup run toit-esp rustc -V` and stops with an error that points here if
the toolchain is missing or does not report the pinned release
(`TOIT_XTENSA_RUST_RELEASE`, default `toit-esp-1.99.0.0-1`; an empty value
accepts any release, for trying another build):

    The verified core for esp32s3 needs the rustup toolchain 'toit-esp', which
    is not installed (error: toolchain 'toit-esp' is not installed). Build and
    install it with toit/build.sh of https://github.com/toitlang/rust, tag
    toit-esp-1.99.0.0-1 (docs/xtensa-rust-toolchain.md).

`-DTOIT_XTENSA_RUST_TOOLCHAIN=esp -DTOIT_XTENSA_RUST_RELEASE=` builds with
the esp-rs release instead. `verified/vmverify/tests/xtensa_codegen_check.sh`
(`XTENSA_RUST_TOOLCHAIN`) and `device_size.sh` use `toit-esp` too.

## Validation of toit-esp-1.99.0.0-1

2026-11-26, against the esp-rs release it replaces (`+esp`, 1.99.0.0).
No hardware; Xtensa code ran under Espressif's QEMU
(`esp_develop_9.2.2_20261109`). Scripts, logs and results:
`opentoit-sandbox-artifacts/xtensa-toolchain/`.

**LLVM lit tests** (the bootstrap's LLVM build: Release, no assertions):
CodeGen/Xtensa 77/77, MC/Xtensa 55/55, MC/Disassembler/Xtensa 29/29,
Transforms/AtomicExpand/Xtensa 1/1, the five new tests included. (The fix
round ran the same suites with assertions, 132/132, and showed that each
new test fails with the unpatched `llc`.)

**Rust tests** (`x.py test --stage 1`): the new
`tests/codegen-llvm/xtensa-abi/xtensa-stack-args.rs` and the existing
`tests/assembly-llvm/asm/xtensa-types.rs` pass.
`tests/assembly-llvm/c-variadic/xtensa.rs` fails, and fails the same way
with the unpatched esp-1.99.0.0: it expects `l32i` where the ESP32 targets
(density option) emit `l32i.n`. Not ours to fix.

**The bugs at run time.** A probe app (a Rust library built with
`-C force-frame-pointers=yes` and `-Zbuild-std=core`, linked into an
ESP-IDF app whose C side is compiled by ESP-IDF's GCC) checks each bug on
the classic ESP32 under QEMU:

| Probe | `+esp` s | `+esp` 3 | `+esp` z | `+toit-esp` s/3/z |
|---|---|---|---|---|
| #139: low byte, byte 1, upper half of a static's address | 3 wrong (reads the static's bytes: `0xab` for `0x2c`) | 3 wrong | 3 wrong | OK |
| #278: `u16`/`i16`/`u8`/`i8` in stack positions of a Rust-to-C call, as the C side sees the words | 4 wrong (`0x6161beef` for `0x0000beef`) | 4 wrong | 4 wrong | OK |
| #278: GCC caller, Rust callee | OK | OK | OK | OK |
| #278 (LLVM): 6-byte `repr(C)` struct by value, then a word | OK | OK | OK | OK |
| #142: SP mod 16 in a C callee of a frame-pointer function | 4 | 4 | 4 | 0 |
| #140: align-64 local with stack arguments | wrong arguments | crash (double exception) | wrong arguments | OK |
| #140: align-32 local with stack arguments | OK (SP happened to be 32-aligned) | not reached | OK | OK |

The 6-byte struct passes with both toolchains because the argument after
it is a `u32`, whose own alignment puts it at offset 8; the unpatched LLVM
puts an argument of smaller alignment at offset 6 (the LLVM test has the
case).

**The firmware's static library** (`libtoit_rust.a`, measure-3's f2
configuration: core opt s; verifier opt s on the classic ESP32, z (the
Cargo.toml default) on the S3), built by the firmware build with each toolchain, compared function by
function with symbol hashes and build paths normalized
(`scripts/cmp-lib.sh`, `cmp-norm.sh`):

| | ESP32 `+esp` | ESP32 `+toit-esp` | S3 `+esp` | S3 `+toit-esp` |
|---|---:|---:|---:|---:|
| text | 222,195 | 222,547 (+352) | 218,940 | 219,207 (+267) |
| literals | 24,284 | 24,284 | 24,652 | 24,652 |
| rodata | 10,306 | 10,306 | 10,306 | 10,306 |
| functions | 1,718 | 1,718 | 1,759 | 1,759 |
| identical | | 1,571 | | 1,609 |
| differing in the frame layout and its consequences | | 142 | | 145 |
| differing in the order of `add` operands only | | 5 | | 5 |

Nothing else differs. The frame-layout differences are the #142 fix:
with a 16-byte stack alignment the reserved outgoing-argument area is
rounded to 16, so spill slots move up by 4 or 8 bytes; 7 functions (8 on
the S3) get a 16 bytes larger frame (`entry`), and where an offset leaves
an instruction's immediate range the code gets a `movi`+`add`, a
non-narrow form or a relaxed branch (and in one function, the verifier's
`x_post_into`, the register allocator picks another register for two
branches), which is the whole size growth. The
commuted `add`s are the #139 fix in five `compiler_builtins` float
functions (`floorf`, `atanf`, `expm1f`, `acosf`, `erfcf`), with the same
semantics. No function of ours uses an over-aligned local, an address
part of a static, a frame pointer or a narrow stack argument, so the
other fixes change nothing, as the fix round predicted.

**Firmware builds** (hardware-free, measure-3's recipe, `+toit-esp` vs
`+esp`, same sources):

| | ESP32 f2 `+esp` | ESP32 f2 `+toit-esp` | S3 f2 `+esp` | S3 f2 `+toit-esp` |
|---|---:|---:|---:|---:|
| toit.bin | 1,463,792 | 1,464,112 (+320) | 1,451,168 | 1,451,408 (+240) |
| iram0.text | 128,323 | 128,363 (+40) | 151,647 | 151,751 (+104) |
| flash.text (+ toit_hot) | 1,163,645 | 1,163,925 (+280) | 1,123,180 | 1,123,316 (+136) |
| flash.rodata, dram0.data | | unchanged | | unchanged |

**Under QEMU.** The classic ESP32 f2 firmware with a trusted installer
container installs, verifies on the device (Rust verifier) and runs the
untrusted images of measure-3 (a-hello ... g-big, r1-r5): with both
toolchains the seven programs exit 0 and r1-r4 are rejected with
`VERIFICATION_FAILED`, r5 with `FORMAT_2_REQUIRED`; the console output of
the two runs is identical apart from code addresses in the final crash
dump (deep sleep, which QEMU does not emulate). The S3 firmware does not
boot in this QEMU with either toolchain (with PSRAM: "PSRAM chip not
found"; without PSRAM: no output after the bootloader), so the S3 is
checked by the library comparison above only.

**Verifier differential** (XTENSA-RUST-FIXES.md 2a, its harness and
inputs unchanged: the verifier source of 2026-11-11, five programs, 1,000
mutants each per seed; the reference is the same code built for 32-bit
x86):

| Seed | Device library | Mutants | Accepted | Differences |
|---|---|---|---|---|
| 7 | core opt 3, no LTO | 5,000 | 516 | 0 |
| 11 | opt z, fat LTO | 5,000 | 482 | 0 |
| 13 | core opt 3, no LTO | 5,000 | 496 | 2: the device answers `OUT_OF_MEMORY` (its 272 KB heap) for two mutants with a 22-25 KB method, the host rejects the certificate; both reject |

The device verdicts of seeds 11 and 13 are byte-identical to those of
the esp-rs toolchain in the fix round (seed 7 used an older mutation
driver there).

## Known issues that remain

Open upstream reports that our patches do not address, and our exposure:

| Issue | What | Our exposure |
|---|---|---|
| [esp-rs/rust#289](https://github.com/esp-rs/rust/issues/289) (2026-11-25) | a ~450 KB function fails to link at opt s (`l32r` literal out of range), LLVM error at opt 3 | build failure, not wrong code; our largest function (the core's `run_loop`) is 19 KB |
| [espressif/llvm-project#90](https://github.com/espressif/llvm-project/issues/90) | every call is `l32r` + `callx8` | size only (about 6.5 KB) |
| [espressif/llvm-project#102](https://github.com/espressif/llvm-project/issues/102) (2024) | a C function returning `i8` seen zero-extended by Rust | not a compiler bug of ours: ESP-IDF's GCC sign-/zero-extends narrow return values (checked); none of the 16 C functions the library imports returns anything narrower than 32 bits (IR of the firmware library) |
| [esp-rs/rust#270](https://github.com/esp-rs/rust/issues/270), #275, [espressif/llvm-project#134](https://github.com/espressif/llvm-project/issues/134), #128 | compiler crashes ("Cannot select", register scavenger, `-Cforce-frame-pointers`) | would fail the build visibly; none occurs |
| [espressif/llvm-project#136](https://github.com/espressif/llvm-project/issues/136), #98 | wrong return-address register / DWARF in debug info | debug info only |
| [esp-rs/rust#287](https://github.com/esp-rs/rust/issues/287) | 1.100.0.0 firmware does not boot | not in 1.99.0.0 |

Espressif closed #141, #143 and #144 (crashes, global_asm parsing) in
November 2026 and #142 on 2026-11-25; no fix is in a public release yet.
Our patch for #142 stays until one is. Unknown bugs remain the main risk
of a single-maintainer backend; `xtensa_codegen_check.sh` (passes at opt
s and 3 with `+toit-esp`) and the QEMU checks above guard against new
exposure to the known ones.

## Updating to a newer upstream release

esp-rs releases follow every upstream Rust minor release within days
(as prereleases), and move to a new Espressif LLVM about once a year.

1. LLVM: in toitlang/llvm-project, branch `toit/esp-<new>` from the commit
   that esp-rs/rust `esp-<new>` pins in `src/llvm-project` (its
   `.gitmodules` names the repository: currently MabezDev/llvm-project, a
   few commits on top of an Espressif tag). Cherry-pick the `[Xtensa]`
   commits of the previous branch that upstream has not taken (check the
   issues above; Espressif closes issues when its internal tree has a fix,
   e.g. #142 was closed on 2026-11-25 without a public commit yet). The
   stack-alignment commit regenerates 17 call0 tests: on conflicts rerun
   `llvm/utils/update_llc_test_checks.py` on them.
2. Rust: in toitlang/rust, branch `toit/esp-<new>` from esp-rs/rust
   `esp-<new>`, cherry-pick the Rust commits (ABI fix, submodule pointer,
   recipe), point `src/llvm-project` at the new LLVM head, and set
   `RELEASE` in `toit/build.sh`.
3. Build, then validate as above: the Xtensa lit suites, the Rust ABI
   test, the probe app under QEMU (every probe OK), the static library
   compared with the previous toolchain, the firmware builds, the
   untrusted-install suite and the verifier differential under QEMU.
4. Tag both repositories `toit-esp-<new>-1` (later fixes on the same
   upstream release: `-2`, ...), update `TOIT_XTENSA_RUST_RELEASE` in
   `toolchains/idf/components/toit/CMakeLists.txt` and this document.

Upstream esp-rs/rust `esp-1.100.0.0` exists (the forks' default branch);
an issue reports that its ESP32 firmware does not boot
([esp-rs/rust#287](https://github.com/esp-rs/rust/issues/287)), so we stay
on 1.99.0.0 for now.
