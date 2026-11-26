# Rust on the classic ESP32: exposure to the known miscompilations, fixes

2026-11-11, branch `experiment/xtensa-fixes` (`sandbox-integration` 2507b592
plus `experiment/xtensa-rust`). Follows XTENSA-RUST-EVALUATION.md. Data,
scripts, patches and drafts: `/home/flo/work/opentoit-sandbox-artifacts/xtensa-fixes/`
(below `A/`). Nothing was flashed; Xtensa code ran only under Espressif's
QEMU. Nothing was posted upstream: the texts are in `A/upstream-drafts/`.

Toolchain: esp-rs fork 1.99.0.0 (`rustc 1.99.0-nightly 4e103d068`), LLVM
22.1.4 = MabezDev/llvm-project `3eeb0284` (the submodule pin of
`esp-1.99.0.0`), cloned to `A/llvm-project`.

## Summary

- None of the known wrong-code bugs is triggered by our library, in any of
  five configurations (core opt 3, s, z; opt 3 and z with fat LTO). Shown
  statically (recompiling the library's bitcode with fixed compilers
  changes nothing that matters, and the instruction and IR patterns are
  absent) and dynamically (15,000 verifier verdicts under QEMU equal to the
  32-bit x86 host; 9 suite tests run untrusted on the Xtensa core in the
  Toit firmware under QEMU, all passing).
- The core builds for `xtensa-esp32-none-elf` from `sandbox-integration`
  without any source patch.
- Fixes for llvm#139, #140 and #142 (and the LLVM half of rust#278) with
  lit tests, validated with `llc`; patches in `A/patches/`.
- Today's fork is usable for our code with a CI check
  (`verified/vmverify/tests/xtensa_codegen_check.sh`) at no size or speed
  cost. Recommendation at the end.

## 1. Exposure

### Method

`A/scripts/build-devlib.sh` builds `verified/vmverify` exactly as
`verified/CMakeLists.txt` does for a device (profile `device`,
`--no-default-features --features device-runtime`, `-Zbuild-std=core,alloc`)
with `-C save-temps`, so the bitcode that codegen consumed is kept. Five
configurations: `o3` (as the firmware builds it), `os`, `oz` (core
opt-level s/z; `toit_spec` is always z by profile override), `o3-lto`,
`oz-lto` (fat LTO through `cargo rustc --crate-type staticlib`).

Three independent checks per configuration:

1. Differential compilation (`A/scripts/exposure.sh`): the bitcode of every
   object in the static library (our crates, `core`, `alloc`,
   `compiler_builtins`, `vstd`) compiled with the stock `llc` (3eeb0284)
   and with an `llc` per fix branch, disassembly compared. A fix that
   changes no instruction means the library never reaches the code that
   the fix changes. (`llc` with rustc's options reproduces rustc's objects
   to within instruction-scheduling and spill-slot noise: 95-99.8 % of lines identical.)
2. Instruction scan of rustc's own objects (`A/scripts/scan-asm.sh`): any
   write to `a1` other than `entry`/`movsp`, every `movsp` and its offset.
   Validated on the reduced IR of the bug reports (finds all of them).
3. IR scan: alloca alignments, variable-size allocas, `frame-pointer`
   attributes, and the argument words of every function on the language
   boundary (`A/scripts/ffi-signatures.sh`).

### Result per bug

| Bug | Trigger (reduced) | Our library |
|---|---|---|
| llvm#139 / rust#283: bytes of an address read from memory | A load of a literal-pool entry narrowed by DAGCombine: only part of a global's, function's or basic block's address is used (`& 0xff`, `& 0xffff`, `>> 8/16/24`, a compare of the top byte, a 16-bit store of the upper half). `& 3`, `trunc` to a returned i8 and an i8 store are not affected. | **Not triggered**, 5/5 configurations. With the fix, the only differences are commuted `add` operands where a select of two float constants indexes its aggregate constant (`compiler_builtins` `floorf` and the like; 5-7 sites), same semantics. |
| llvm#140 / rust#284: realignment without `movsp` | A stack object aligned above 32 bytes (realigned with `add a1`); found here: above 16 bytes (align 32 is silently not realigned), and incoming stack arguments read at a wrong offset in any realigned frame | **Not triggered**: largest alloca alignment 16 (20 sites), 0 writes to `a1` in 679-2,320 functions per configuration, fix changes nothing. |
| llvm#142 / rust#286: SP misaligned at calls | A call with stack arguments in a function with a frame pointer (`-C force-frame-pointers`, `frame-pointer` attribute) or a variable-size alloca | **Not triggered**: the target spec does not force frame pointers, no attribute, no variable-size alloca, 0 `movsp` in all configurations. The fix changes frame layouts everywhere (offsets now from a 16-byte rounding), but no SP move existed before. |
| rust#278: garbage in sub-word stack arguments | A Rust call to a C function with more than six argument words where a stack argument is a `u8`/`u16` (passed byval) or an aggregate whose size is not a multiple of 4 | **Not triggered**: 23 imported C functions, at most 5 words (`toit_v2_call_primitive`, `toit_v2_lookup_primitive`); 2 exported (`toit_v2_run`, `toit_vmverify_verify`, at most 2 words). Rust-to-Rust calls use the same convention on both sides. |
| llvm#144 / esp-hal#6789: `global_asm!` in a lone codegen unit | `global_asm!` plus more than one codegen unit | Not applicable: no `global_asm!`, `codegen-units = 1`. |
| llvm#90: every call is `l32r` + `callx8` | always | Applies: 5,652 `callx8`, 0 `call8` at o3 (2,829 at oz-lto). Size only. |

No experiment patch was needed: `sandbox-integration` builds for
`xtensa-esp32-none-elf` as is (62 s with build-std).

Side finding: Cargo silently drops `lto = true` from the `device` profile,
because `verified/vmverify` has crate types `staticlib` and `rlib`; the
firmware library is not LTO'd (one object per crate in the archive). With
fat LTO our object is 83.6 KB against about 114 KB of per-crate objects (before the linker drops unused functions) at
o3. Same on RISC-V. Worth a separate look (for example building the device
library with `cargo rustc --crate-type staticlib`).

## 2. Dynamic evidence under QEMU

QEMU: Espressif `esp_develop_9.2.2_20261109`, `-machine esp32`.

### 2a. The verifier on real programs

`A/qemu/vdiff/` is a small driver around `toit_vmverify_verify` (the C
entry point the VM calls), built for two 32-bit targets from one source:
`i686-unknown-linux-gnu` and `xtensa-esp32-none-elf`, both with the device
features (no std in the verifier, no inference, shipped certificates
required). Inputs: the `.tables` of five format-2 programs (hello,
lambda-test, exception-test, class-id-test, task-test) written by the
32-bit host VM (`build/host32`, `toit.run --verify --emit-canonical=X.tables`),
and their certificates (`toit_vmverify_certify`). Mutants as in
`toit_vmverify_fuzz --certificates` (tables, certificate or both, 1-4
mutations), deterministic per (seed, program, index). Each side prints
code, method, offset, object count and an FNV hash of the message per
mutant. The x86-64 host cannot read 32-bit tables, so the reference is the
32-bit x86 build of the same code. The Xtensa side is an ESP-IDF app
embedding the inputs (`A/qemu/idf-vdiff/`), 16 QEMU instances in parallel
(`A/scripts/vdiff-qemu.sh`), about 1 s per mutant under QEMU, 2.5 ms on
the host.

| Run | Device library | Mutants | Accepted | Differences |
|---|---|---|---|---|
| seed 7 | core opt 3, no LTO (as shipped) | 5,000 | 516 | 3, all explained (1) |
| seed 11 | opt z, fat LTO | 5,000 | 482 | 0 |
| seed 13 | core opt 3, no LTO | 5,000 | 496 | 2, both explained (2) |

1. The mutation flipped a bit of an absolute address (an image reference
   XOR a power of two), which lands on different objects when the image
   starts at different addresses. Applying on the host the flip the device
   address produced gives the device's verdict with the identical hash, in
   all three cases (`vdiff-host retarget`). The driver now flips bits
   relative to the image (seeds 11 and 13).
2. Two mutants made a method 22-25 KB long; the device ran out of its
   272 KB heap and answered `OUT_OF_MEMORY` (fail closed), the host
   rejected the certificate. Both reject.

No divergence attributable to code generation in 15,000 verdicts (1,494
accepted, the rest rejected for malformed memory, heap, tables or
certificate).

### 2b. The interpreter core in the Toit firmware

The Toit ESP32 firmware builds with the Rust core for Xtensa with three
lines of build glue (this branch: `verified/CMakeLists.txt` takes a cargo
toolchain and extra arguments, `toolchains/idf/components/toit` selects
`xtensa-esp32-none-elf`, `cargo +esp`, `-Zbuild-std=core,alloc` for the
ESP32, and the Kconfig option allows the ESP32). Experiment only.

- `sandbox-integration`'s ESP32 firmware does not link even without the
  Rust core: IRAM overflows by 2,720 bytes. For the experiment the heap and
  ring-buffer functions go to flash (`CONFIG_HEAP_PLACE_FUNCTION_INTO_FLASH`,
  `CONFIG_RINGBUF_PLACE_FUNCTIONS_INTO_FLASH`; not acceptable with PSRAM:
  that build crashed at boot with "cache disabled but cached memory region
  accessed").
- Cost of the core (opt 3, no LTO, no inference, no checked loop): flash
  text +91,388 B, rodata +5,480 B, `toit.bin` +96,864 B (1,462,432 to
  1,559,296); IRAM and DRAM unchanged.
- It boots under QEMU. A trusted boot container (`A/fw-qemu/installer/`)
  installs 32-bit format-2 images of suite tests (with their certificate
  block, `toit tool snapshot-to-image -m32`) through
  `ContainerImageWriter.commit --untrusted`, which verifies them on the
  device with the Rust verifier, starts each as an untrusted container (on
  the verified core) and prints the exit code
  (`A/scripts/fw-untrusted-run.sh`).

| Test | Host 64 / 32 (untrusted) | Xtensa under QEMU |
|---|---|---|
| byte-array, constructor-super, exception, fold, lambda, non-local-branch-types, string-slice, format, map | exit 0 | exit 0 (format and map when installed first, after a fresh boot) |
| list (67 KB image), deque (67 KB) | exit 0 | not installed: verifier `OUT_OF_MEMORY` |
| is-as-many (80 KB) | exit 0 | not installed: `INVALID_SNAPSHOT` (the method-table `calloc` failed) |

The three failures are heap exhaustion on a 520 KB-SRAM part without
PSRAM (largest free block 60 KB with the system running); a PSRAM build
did not fit IRAM, and QEMU's PSRAM is refused on revision 0.0 without the
cache workaround. Not a code-generation finding, but a product one: on the
classic ESP32 without PSRAM, install-time verification of 65-80 KB images
fails.

Two QEMU-specific adjustments, neither committed: the 10 s
"Potential deadlock" check (`PROCESS_MAX_RUN_TIME_US`) killed the system
process during install-time verification under QEMU, so the run used
600 s; and after the last container the system enters deep sleep, which
QEMU does not emulate (`LoadStorePIFAddrError` at an RTC register). The
first one deserves a look on hardware: verification runs inside a
primitive of the system process, and the VM aborts if a primitive runs for
10 s.

## 3. Workarounds available today

| Bug | Workaround | Tested | Cost |
|---|---|---|---|
| #139 | Source: no arithmetic on parts of a static's or function's address. Compiler: `-C llvm-args=-combiner-disabled` removes the narrowing entirely (llc on the reduced IR: all cases correct) | yes (both) | source: none. Flag: +43 % text for our LTO object (83.6 to 119.2 KB), +34-45 % per crate: only as an emergency |
| #140 | No `#[repr(align(N))]` with N > 16 on stack values; no `std` (its channels have `CachePadded` locals) | yes (IR scan) | none |
| #142 | Keep the default (no `-C force-frame-pointers`); no unsized locals | yes (asm scan) | none |
| #278 | At most six argument words across the FFI, or `u32`/`usize` (never `u8`/`u16`/odd-size structs) for arguments in stack positions; we own both sides | yes (signature scan) | none |
| llvm#144 | `codegen-units = 1` (already) | yes | none |
| call0 ABI | Not an option: ESP-IDF code is windowed, and `callx8` into a function without `entry` leaves it reading its arguments from the caller's window (a2-a7 instead of a10-a15). Mixing needs assembly thunks per entry point and per callback. | reasoned, not built | n/a |

**CI check.** `verified/vmverify/tests/xtensa_codegen_check.sh [3|s|z]`
builds the library as the firmware does and fails on: any write to `a1`
other than `entry`, any `movsp`, an alloca aligned above 16, a
variable-size alloca, frame pointers, and a boundary call with more than
six argument words and a sub-word or byval stack argument. With
`XTENSA_LLC_STOCK` and `XTENSA_LLC_FIXED` (two `llc` builds, about 8 min
each, cacheable) it also runs the differential compile for #139, ignoring
commuted `add` operands. Tested both ways: clean on the tree at opt 3 and
z; with three probe functions added temporarily (low byte of a static's
address, an align-64 local, a 9-argument call with `u16`s) it reports
all of them.

**The combination.** Today's fork with our current flags (core opt 3 or z,
`toit_spec` z, panic=abort, `codegen-units = 1`, no frame pointers) plus
the CI check (and, on toolchain changes, the QEMU verifier differential of
2a) gives a library free of the known bugs, at zero size and speed cost.
The constraints it adds to our code (no over-aligned locals, narrow FFI
signatures, no address-bit tricks on statics) are already met.

## 4. Fixing the compiler

Built: LLVM at 3eeb0284, Xtensa only, Release with assertions, ninja with
30 jobs: `llc opt llvm-mc llvm-objdump FileCheck ...` in 7 min 47 s
(`A/llvm-build`, 696 MB; a second tree for the stock compiler,
`A/llvm-build-stock`, 556 MB). Baseline: CodeGen/Xtensa + MC/Xtensa
127/127. Branches in `A/llvm-project`: `fix-139`, `fix-140`, `fix-142`,
`fix-278-byval`, and `all-fixes` (merged: 132/132, the 5 new tests
included). Each new test fails with the stock `llc` (`A/scripts/test-on-stock.sh`).

### llvm#139 / rust#283: bytes of an address

Root cause. Since upstream 4154ada1d485 (LLVM 21) `LowerGlobalAddress`
(and the block-address, jump-table, callee and TLS lowerings) return a
generic load of `XtensaISD::PCREL_WRAPPER`, so the wrapper is the
*address* of a literal; but `LowerConstantPool` still returned a bare
wrapper for aggregate constants (placed in a new global) that consumers
use as the address of the data, i.e. as the literal's *value*. The fork's
39a59933 made that work with a low-priority pattern selecting a bare
wrapper as `L32R` (the literal's value). When DAGCombine narrows a load of
a literal (`ReduceLoadWidth`), the wrapper becomes the address operand of
an `L8UI`/`L16UI`/`L16SI` and that pattern selects it as the literal's
value: the load reads memory at the global. Upstream has no such pattern,
so the same narrowing is a selection error there (llvm/llvm-project#227826).

Patch (`A/patches/llvm-139/`, 151 lines): `shouldReduceLoadWidth` refuses
to narrow a load whose base is a `PCREL_WRAPPER`; `LowerConstantPool`
returns the load of the literal holding an aggregate's address; the
bare-wrapper pattern and the two `load (add s, wrapper)` patterns are
removed (any other use of a literal is now a selection error, not wrong
code). Test: `constantpool-narrow-load.ll` (10 functions; two RUN lines,
esp32 at -O2 and esp32s3 at -O1). Confidence: high for the narrowing
class; medium that no other path needed the removed patterns (such a path
would now fail to compile, visibly); `constantpool_aggregate.ll` and the
whole Xtensa suite pass. The `shouldReduceLoadWidth` part applies upstream
as is.

### llvm#140 / rust#284: windowed-ABI realignment

Root cause. `emitPrologue` realigned SP with a plain `ADD` after `ENTRY`.
In the windowed ABI the caller's a0-a3 are spilled below SP, and only
`MOVSP` moves them along (the Alloca exception) if the spill already
happened, so an interrupt between `ENTRY` and the `ADD` corrupts the
caller. In the same block: the misalignment was computed from a7 (an
incoming argument until it becomes the frame pointer), the guard `> 32`
left align-32 objects unaligned (SP is 16-aligned), and, found here,
incoming stack arguments were addressed from the realigned SP, so a
realigned function read its seventh and later argument words from the
wrong place.

Patch (`A/patches/llvm-140/`, 191 lines): realign when the maximum
alignment exceeds 16 with `SP' = (SP + A - 1) & -A` in a scratch register
and `MOVSP`; a realigned frame always has a frame pointer holding the
incoming SP (set before the realignment) through which fixed objects
(incoming arguments) are addressed, everything else from SP
(`eliminateFrameIndex`); its call frame is reserved; realignment together
with a variable-size alloca is a fatal error instead of wrong code. Tests:
`stack-realign-windowed.ll` (6 functions) and `stack-realign-windowed-vla.ll`.
Confidence: medium-high. The spill race cannot be shown in a lit test or
deterministically under QEMU; the call0 ABI (no realignment at all) and
the debug-info frame references of realigned frames are not handled.

### llvm#142 / rust#286: SP misaligned at calls

Root cause. `XtensaFrameLowering` declared a stack alignment of 4 while
the ABI and the prologue use 16; without a reserved call frame (frame
pointer or variable-size alloca) `LowerCall` moved SP by the argument size
rounded to 4. Found while fixing: `CALLSEQ_END` released the unrounded
size while `CALLSEQ_START` reserved the rounded one (harmless only while
both rounded to 4; the machine verifier catches it).

Patch (`A/patches/llvm-142/`): stack and transient alignment 16, and
`CALLSEQ_END` with the rounded size. call0 frames become multiples of 16
(as GCC's), which changes 17 tests (13 regenerated with
update_llc_test_checks.py, 4 by hand). Test: `call-frame-align.ll`.
Confidence: high (it is what the ABI and GCC do); the cost is up to 12
bytes of stack per call0 frame and per variable-size alloca.

### rust#278: sub-word stack arguments

Two halves. LLVM: a byval object of 5-7 bytes did not occupy whole words.
`A/patches/llvm-278-byval/` applies the reporter's
llvm/llvm-project#228365 (approved 2026-11-02, not merged) to the fork,
with a test (the stock compiler fails the machine verifier on it). rustc:
`compiler/rustc_target/src/callconv/xtensa.rs` passes any argument that
does not fit in a2-a7 `byval`, so a `u16` is stored with `s16i` and the
upper half of its stack word keeps garbage. `A/patches/rustc-278.patch`
passes scalars as direct arguments extended to 32 bits instead (the fork's
LLVM already stores clang's `i16 zeroext` stack arguments as extended
words: checked with `llc`). Not built: no rustc build was done (below).

### Not done

A rustc build against the patched LLVM (esp-rs/rust with
`download-ci-llvm = false`): skipped for time; expected 1-2 h on 32
threads and 30-40 GB. Without it the fixes are validated at the `llc`
level only: on the reduced IR of the reports and on our library's bitcode
(the `all-fixes` llc compiles all five configurations; 0 SP writes,
0 `movsp`).

### Upstream texts

`A/upstream-drafts/`: PR descriptions and issue comments for
espressif/llvm-project (#139, #140, #142), and for esp-rs/rust#278 (LLVM
and rustc halves). Not sent.

## 5. Assessment

### (a) Shipping on the classic ESP32 with today's fork

Possible. Our library does not hit any of the four open wrong-code bugs,
statically in five configurations and dynamically in 15,000 verifier
verdicts and nine suite programs on the Xtensa core. The workarounds cost
nothing because our code already avoids the patterns. Residual risk:

- Unknown bugs. Four wrong-code reports in six months (rust#278 May,
  #283 September, #284 October, #286 November), each found by a user in
  production. The CI check covers only what is known.
- New exposure. A change to our code or a new fork release can start
  triggering a known bug (for example, an over-aligned local, or a pointer
  low-bit trick on a static). The CI check catches these, if it runs on
  every build and toolchain change.
- The fork itself: one maintainer per layer, nightly with `-Zbuild-std`,
  prerelease builds.
- Not compiler-related, but blocking for product use on this part: the
  `sandbox-integration` ESP32 firmware overflows IRAM; install-time
  verification of 65-80 KB images runs out of heap without PSRAM; the 10 s
  primitive watchdog versus install-time verification needs a measurement
  on hardware.

### (b) Our own patched toolchain versus upstreaming

Carrying a patched toolchain: build rustc against our LLVM (1-2 h on this
machine, 30-40 GB; CI needs a cached toolchain artifact per release, about
1.1 GB like the esp toolchain), rebase four small patches every six weeks
(Xtensa-only files; conflicts are likely only in the regenerated tests of
the #142 patch), rerun the lit tests, our check and the QEMU differential.
Roughly a day per fork release once automated, plus distribution of a
custom rustup toolchain to every developer and CI runner, and ownership
of any regression our patches cause.

Upstreaming: Espressif integrates GitHub PRs into its internal tree and
closes them (no "merged" state; MabezDev's #122 reached the release
branches within weeks); its Jira tags show #139/#140/#142 as triaged
(LLVM-596/597/600), but none has a maintainer comment after 5-6 weeks,
while #144 got three answers from gerekon within a day. On esp-rs/rust,
#278 (6 months), #283, #284 and #286 have no maintainer response at all.
Upstream LLVM reviews Xtensa slowly: the reporter's byval PR waited a
month for an approval and is still not merged. The fork picks up upstream
LLVM fixes only with its yearly major-version rebase.

### (c) Waiting for upstream

Upstream LLVM: Xtensa is still in `LLVM_ALL_EXPERIMENTAL_TARGETS`; main
has the same #140 and #142 code and the #139 narrowing as a selection
error (llvm/llvm-project#227826, open). Upstream Rust: tier-3 Xtensa
targets need the fork's LLVM; nightly 1.102 cannot compile
`compiler_builtins` for Xtensa (`Cannot select: XtensaISD::PCREL_WRAPPER`,
likely the same narrowing), rust#162828 is open. Missing before upstream
is usable: the backend fixes above, direct calls (llvm#90), leaving
experimental status, and Rust targets built against upstream LLVM.
Realistically more than a year away.

### (d) Recommendation

1. Use today's fork for the classic ESP32, pinned to one release, with
   `xtensa_codegen_check.sh` (including the #139 differential with a
   cached pair of `llc` builds) on every build and the QEMU verifier
   differential on every toolchain bump. Keep the FFI at most six words
   and avoid over-aligned locals (document both in TRUSTED.md).
2. Do not carry a patched compiler now: our code does not need the fixes.
   Keep the patches ready (`A/patches/`) in case a future change of ours
   needs one, or a new bug appears that only a fix can avoid.
3. Send the fixes upstream (drafts in `A/upstream-drafts/`), in this
   order: #139 to espressif/llvm-project (and its `shouldReduceLoadWidth`
   half to llvm/llvm-project#227826), #142, #140; comment on rust#278 with
   the rustc patch after a rustc build has tested it.
4. Before shipping on this part, independent of the compiler: fix the
   IRAM overflow of the ESP32 firmware, measure install-time verification
   (time and heap) on hardware, and decide whether the classic ESP32
   without PSRAM is a target for untrusted containers.

## Follow-up: the product findings fixed (branch device/esp32-build-fixes)

2026-11-11; details and numbers in verified/core/PROGRESS.md, "Device
builds"; artifacts `/home/flo/work/opentoit-sandbox-artifacts/esp32-build/`.

- LTO now applies (the side finding of section 1): the VM's library is the
  staticlib-only package verified/vmverify/staticlib (`libtoit_rust.a`).
  One object for all Rust code; at opt 3 the Xtensa library is 79,129
  instead of 81,304 bytes (with the glue at opt z). The CI check
  (`xtensa_codegen_check.sh`, now on the LTO'd module) passes at opt 3 and
  z, including the #139 differential against the cached `llc` builds
  (`A/llvm-build-stock`, `A/llc-bin/fix-139`): no known wrong-code
  pattern. `device_size.sh` measures Xtensa too (`DEVICE_SIZE_ARCH=xtensa`).
- IRAM: the firmware links without moving heap or ring-buffer functions to
  flash (`Interpreter::run`'s slow paths are shared, the untrusted
  processes' field checks out of line): 957 bytes of iram0_0_seg left, with
  or without the Rust core.
- The 10 s dead-lock check: install-time verification reports progress
  before each method (proven wrapper of `verify_shipped`), and the check
  measures the time since the last report. Under QEMU with the real limit
  and `-icount shift=6` (verification of 16-37 s of virtual time) the
  installs succeed; a control build without the reports stops with
  "Potential dead-lock". Measured on the Xtensa core: 250-580 M
  instructions per verification of 25-38 KB of bytecodes, so seconds on
  hardware.
- Heap without PSRAM: an out-of-memory verification now retries once after
  a cross-process GC (117 KB free instead of 47-63 KB). All twelve suite
  tests install and pass under QEMU, alone and in one boot (8 alone before;
  in one traced run 11 of 12 in one boot: is-as-many-test needs 103 KB, a
  28.7 KB method table and 75 KB for the maps of its largest method).

## Disk use (to delete when done)

| Path | Size |
|---|---|
| `A/` (`/home/flo/work/opentoit-sandbox-artifacts/xtensa-fixes`) | 12 GB |
| of which `A/llvm-project` (clone, 5 branches) + `A/llvm-project-stock` (worktree) | 5.1 GB |
| of which `A/llvm-build` + `A/llvm-build-stock` + `A/llc-bin` | 1.6 GB |
| of which `A/devlib`, `A/ci-check`, `A/qemu`, `A/fw-qemu` (cargo targets, flash images) | 5.3 GB |
| this worktree's `build/` (host, host32, three esp32 firmware builds) | 1.8 GB |

Keep `A/patches`, `A/upstream-drafts`, `A/scripts` and the run logs
(`A/qemu/runs/*/{host,device}.txt`, `A/fw-qemu/run-*/serial.txt`, a few MB);
the rest can be regenerated by the scripts.

## Follow-up: our own toolchain (2026-11-26)

The owner decided to carry the fixes after all: the four LLVM patches and
the rustc half of rust#278 are in the Toit forks toitlang/rust and
toitlang/llvm-project (tag `toit-esp-1.99.0.0-1`), which the firmware
builds with (`cargo +toit-esp`). Build, pins and validation (lit tests, the
bugs reproduced under QEMU and fixed, the library compared with this
round's toolchain, the verifier differential): docs/xtensa-rust-toolchain.md.
