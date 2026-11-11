# Format 2 as the default (migration step 3)

Branch `plan/format2-default` (from `sandbox-integration`). The plan agreed
with the project owner: one interpreter (the Rust core, verified/core) and
one bytecode format (format 2). This step makes format 2 the default for
every program on host builds; the next step deletes the C++ interpreter and
format 1. Artifacts and scripts:
/home/flo/work/opentoit-sandbox-artifacts/format2-default.

## The default and how to switch back

| What | Default now | Format 1 |
|---|---|---|
| Compiler (toit.compile, toit.run, `toit compile/run`) | format 2 when the build has the verified core | `-Xbytecode_format=1`, or `TOIT_BYTECODE_FORMAT=1` in the environment |
| Embedded programs (toit CLI, toit.run boot snapshot with the system process, run image) | the build's format | CMake `-DTOIT_BYTECODE_FORMAT=1` |
| The whole build (compiler default and embedded programs) | `TOIT_BYTECODE_FORMAT=2` if `TOIT_VERIFIED_CORE` is on, else 1 | `cmake -DTOIT_BYTECODE_FORMAT=1` |

Precedence in the compiler (src/compiler/program_builder.cc,
`requested_bytecode_format`): an explicit `-Xbytecode_format=N`, then
`TOIT_BYTECODE_FORMAT` from the environment, then the build's default
(`TOIT_DEFAULT_BYTECODE_FORMAT`, from the CMake cache variable
`TOIT_BYTECODE_FORMAT`). The old CMake option `TOIT_SYSTEM_FORMAT2` is gone:
a build configured with `-DTOIT_BYTECODE_FORMAT=1` is the old default
build, one with `-DTOIT_BYTECODE_FORMAT=2` is the old `build/host-f2`.
Running the suite "everything in format 1" is a build with
`-DTOIT_BYTECODE_FORMAT=1` (no environment needed); for one program,
`-Xbytecode_format=1` or `TOIT_BYTECODE_FORMAT=1`.

The VM runs both formats as before: format 1 on the C++ interpreter,
format 2 on the core (`Program::is_format2`, the `TBC2` tag), so programs
of both formats can be compared on one VM.

## Trusted and untrusted compilation

There are two kinds of format-2 code:

- **Trusted (first-party), the default.** The compiler emits the
  trusted-only unchecked twins of the field accesses (format note 20) and
  the built-ins of note 19. No certificate. The program runs on the
  verified loop without verification (the trusted token). It cannot run as
  an untrusted container: the launch and install verifier reject the twins
  ("unchecked opcode ... in a program not in the unchecked mode").
- **Untrusted.** Only checked opcodes (the built-ins are verified and
  stay), and `toit.compile -w` ships the certificate
  (verified/spec/format/18-shipped-certificate.md) that the device checks
  at install.

The user-facing switch is `--untrusted`:

    toit compile --untrusted --snapshot -o prog.snapshot prog.toit   # toit.compile --untrusted -w ...
    toit run --untrusted prog.toit                                    # compiles untrusted, runs sandboxed
    toit.run --untrusted -w prog.snapshot prog.toit                   # writes the snapshot (no certificate)

`--untrusted` implies format 2 (`toit.compile --untrusted
-Xbytecode_format=1` is an error). `-Xuntrusted` is the same flag.
Low-level overrides: `-Xv2_unchecked=false` or `TOIT_V2_UNCHECKED=0`
compile checked code without making the program untrusted; the sandbox
tests use this for their trusted drivers, which start their own image as
an untrusted container.

## -O2 and the type propagator

Decision: **format 1 stays a compiler-internal intermediate**; the
propagator is not ported. `-O2` compiles a first pass in format 1 in
memory, the propagator interprets it (src/compiler/propagation/), the type
oracle maps the results back to IR nodes, and the second pass emits the
requested format. Only the second pass is written. `--propagate` (the
type-propagation tests) compiles in format 1 throughout, since its output
names format-1 bcis.

Cost comparison: type_propagator.cc is a second interpreter over the
format-1 instruction set (1,982 lines plus type_scope/type_stack, 5,651
lines in propagation/ with the primitive tables). Porting it means new
frame, block-reference, finally-record and built-in handling and new gold
files for 52 tests: 12-20 days (EXPERIMENT-trusted.md). The intermediate
was already in place (compiler.cc) and needs no work; it costs one extra
code generation at `-O2` only, and keeps about 200 lines of format-1
emission (emitter.cc, byte_gen.cc, program_builder.cc) plus
`src/bytecodes.h` and the `Method` class alive in the compiler.

Effect (o2.sh, compiler of build/host; bytecode bytes / methods / virtual
calls / static calls):

| Program | f1 -O1 | f1 -O2 | f2 -O1 | f2 -O2 |
|---|---|---|---|---|
| richards | 28,745 / 905 / 398 / 891 | 19,864 / 657 / 276 / 641 | 26,231 / 905 / 398 / 891 | 18,104 / 657 / 276 / 641 |
| deltablue | 30,266 / 948 / 446 / 961 | 20,962 / 682 / 312 / 711 | 27,667 / 948 / 446 / 961 | 19,149 / 682 / 312 / 711 |
| pystone | 28,568 / 902 / 398 / 881 | 19,592 / 637 / 273 / 621 | 26,078 / 902 / 398 / 881 | 17,891 / 637 / 273 / 621 |
| toit CLI | 308,109 / 7,184 | 289,148 / 6,800 / 4,076 / 13,552 | 287,212 / 7,184 | 269,075 / 6,800 / 4,076 / 13,552 |
| system (toit.run) | 61,894 / 1,785 | 54,667 / 1,633 / 794 / 2,084 | 56,515 / 1,785 | 49,766 / 1,633 / 794 / 2,084 |

The `-O2` programs have the same methods and the same virtual and static
calls in both formats; the bytecodes shrink by the same fraction (richards
0.691 in format 1, 0.690 in format 2). Instructions (callgrind in
`Interpreter::run`, millions, bench.sh with `OPT=-O2`; `trs` is format 2
trusted, the default):

| | cxx -O1 | cxx -O2 | trs -O1 | trs -O2 | trs/cxx at -O2 |
|---|---:|---:|---:|---:|---:|
| richards | 1,024.3 | 981.0 | 1,075.3 | 1,031.4 | 1.051 |
| deltablue | 652.5 | 621.1 | 758.8 | 735.4 | 1.184 |
| pystone | 767.4 | 755.1 | 811.9 | 799.9 | 1.059 |
| json | 1,117.1 | 1,042.9 | 1,314.5 | 1,244.5 | 1.193 |
| RPC | 343.9 | 329.5 | 412.7 | 401.5 | 1.218 |

`-O2` saves 1.5-6.6% in both formats; the saving is up to 1.7 points
smaller on the core for deltablue and RPC (the same program, executed by a
different interpreter).

## Devices

Branch `device/format2` (from `sandbox-integration`; artifacts, scripts
and logs: /home/flo/work/opentoit-sandbox-artifacts/device-format2).

**The classic ESP32 and the ESP32-C6 firmware can run everything in
format 2 on the core**, with three lines in their sdkconfig:

    CONFIG_TOIT_VERIFIED_CORE=y
    CONFIG_TOIT_BYTECODE_FORMAT_2=y
    # CONFIG_TOIT_CXX_INTERPRETER is not set

The system snapshot and the containers bundled in the envelope are then
trusted format 2 (twins, built-ins; the compiler's default), untrusted
containers are installed with the shipped certificate, and the C++
interpreter is not linked. **It is not the default yet**: the Jaguar
firmware (system and Jaguar in the app partition,
tests/esp32/check-partition-sizes.sh) no longer fits, see "Flash" below.
Commit 4f488c84 had the switch (sdkconfigs and the CI step that installs
the Rust targets); 7c716b70 reverted it. The Xtensa toolchain is not a
blocker any more:
verified/XTENSA-RUST-EVALUATION.md and XTENSA-RUST-FIXES.md show that the
esp-rs toolchain (`cargo +esp`, 1.99.0.0) builds the core for the classic
ESP32 and that our code triggers none of its known wrong-code bugs
(verified/vmverify/tests/xtensa_codegen_check.sh, to rerun on every
toolchain update).

The switches (toolchains/idf/components/toit/Kconfig):

| Kconfig | Effect |
|---|---|
| `TOIT_VERIFIED_CORE` | links the core and the verifier (Rust, `libtoit_rust.a`) |
| `TOIT_BYTECODE_FORMAT_2` (needs the core, default y) | the IDF component compiles the system snapshot and the entry program with `TOIT_BYTECODE_FORMAT=2`; CMake `TOIT_BYTECODE_FORMAT=2`; a device build without the core is a CMake error |
| `TOIT_CXX_INTERPRETER` (only deselectable with format 2) | CMake option `TOIT_CXX_INTERPRETER=OFF` (hosts keep it on): interpreter_run.cc and method_entries.cc are not compiled, `Interpreter::run` only hands over to the core (interpreter_v2.cc), `ProcessGroup::create` refuses format-1 programs. printing.cc stays: it is compiled only with `TOIT_DEBUG` (empty on devices). The format-1 verifier was already a stub on FreeRTOS. |
| `TOIT_TRACE_INSTALL` (measurements) | prints time, free heap, table location and peak heap of each install-time verification (`[install-trace]`) |

The envelope records the formats its firmware runs: metadata
`bytecode-formats` (`toit tool firmware create esp32|ec618
--bytecode-formats=1,2`, shown by `show`; the IDF component passes 1 if
the C++ interpreter is linked and 2 if the core is). `container install`
refuses a snapshot in another format; envelopes without the record get
the old warning (format-2 snapshot, format-1 system). The other targets
(C3, S2, S3, P4, EC618) keep format 1 and record `[1]`.

### The method table in flash

A format-2 process group needs the method table (16 bytes per method,
blocks and lambdas included), which `V2MethodTable::compute` built in
RAM: 27.8 KB for the ESP32 system snapshot (1,735 methods) plus 21.5 KB
for a 1,350-method container. Format 1 needs a bitmap of method entries
(1 bit per bytecode byte, 13 KB for the same two programs). On the classic
ESP32 the free heap with the suite container running fell from 117 KB
(format 1) to 80 KB, and untrusted installs failed with MALLOC_FAILED.

The compiler now appends the table as the program's last literal
(`-Xv2_table_literal`, on by default; marker `TMT1`, count, bytecodes
length, the records). In an image the literal is in flash; `compute()`
uses it in place after decoding every header again and comparing it with
its record (so the table is exactly the one it would build, also for
untrusted programs), and builds one in RAM otherwise
(src/v2_method_table.cc). Cost: 16 bytes of flash per method (the system
image grows from 86 to 114 KB). Free heap at boot is now 134 KB, 17 KB
more than format 1.

### Measurements

QEMU (Espressif's esp_develop_9.2.2, `-icount shift=0`: one microsecond
of virtual time is a thousand guest instructions) on the classic ESP32;
the ESP32-C6 has no QEMU machine (Espressif's QEMU emulates the ESP32, S3
and C3), so only its sizes are measured. Three configurations of the same
commit: f1 (format 1, C++ interpreter, no core: today's firmware), f2cxx
(format 2 on the core, C++ interpreter still linked), f2 (format 2,
`TOIT_CXX_INTERPRETER=n`: the new default).

| Bytes | ESP32 f1 | f2cxx | f2 | ESP32-C6 f1 | f2cxx | f2 |
|---|---:|---:|---:|---:|---:|---:|
| toit.bin | 1,462,800 | 1,566,400 | 1,549,952 | 1,574,496 | 1,661,664 | 1,640,400 |
| iram0.text | 129,087 | 129,087 | 116,947 | 156,350 | 156,350 | 139,998 |
| dram0 data + bss | 55,052 | 55,052 | 54,636 | 47,301 | 47,309 | 46,885 |
| Rust library (libtoit_rust.a) | 0 | 116,077 | 116,077 | 0 | 109,557 | 109,557 |
| interpreter_run.cc + method_entries.cc | 14,583 | 14,583 | 0 | 18,255 | 18,255 | 0 |
| system snapshot | 184,212 | 208,552 | 208,552 | 184,212 | 208,552 | 208,552 |
| system image (32-bit) | 88,704 | 114,048 | 114,048 | 88,704 | 114,048 | 114,048 |
| free heap at boot (suite running) | 116,952 | 133,336 | 133,760 | | | |
| free heap after the GC stress | 87,856 | 100,104 | 100,528 | | | |

Instructions (QEMU icount, thousands; the suite's single runs):

| | f1 | f2 | f2/f1 |
|---|---:|---:|---:|
| richards | 178,552 | 128,572 | 0.720 |
| deltablue (50) | 10,419 | 10,093 | 0.969 |
| pystone (2,000 loops) | 24,326 | 20,993 | 0.863 |
| json encode/decode | 26,753 | 28,559 | 1.068 |
| map/set | 19,213 | 18,413 | 0.958 |
| strings | 16,806 | 16,633 | 0.990 |
| GC stress | 88,693 | 90,893 | 1.025 |
| 200 service calls between containers | 28,534 | 28,428 | 0.996 |
| CPU-bound container (20 M iterations) | 5,601,196 | 4,343,752 | 0.776 |

On Xtensa the core executes fewer instructions than the C++ interpreter
on most programs (on x86-64 it executes 5-20 % more, see above): icount
counts instructions, not cycles, and the C++ interpreter runs from IRAM.

**Flash.** The flashed firmware (toit.bin with the system image in its
DROM extension; `extract --format binary`) against the OTA partition
(classic ESP32 0x1a0000 = 1,703,936 bytes, C6 0x1d0000 = 1,900,544):

| | ESP32 f1 | ESP32 f2 | C6 f1 | C6 f2 |
|---|---:|---:|---:|---:|
| system only | 1,593,872 | 1,681,024 | 1,705,568 | 1,771,472 |
| with Jaguar (v1.73.0, -O2) | fits | 1,812,096: 108 KB over | fits | 1,902,544: 2 KB over |

Jaguar's image: 101,376 bytes in format 1, 126,720 in format 2 (97,152
without the table literal). Of the classic ESP32's growth (+87 KB without
Jaguar), the Rust library is 116 KB, the C++ interpreter's removal saves
15 KB, the system's table literal costs 28 KB and format 2's smaller
bytecodes save a few KB. Options, none taken here: a partition layout
with larger OTA partitions for the classic ESP32 (the C6 already has
0x1d0000; the programs partition shrinks, and deployed devices cannot
change their layout over the air), a smaller core (opt-level s: see
below), or no table literal for bundled containers (their tables in RAM
again: 29.6 KB for Jaguar).

**IRAM.** Without the C++ interpreter 13.1 KB of the classic ESP32's IRAM
are free (f1: 957 bytes). The core's loop (`step::run_loop`, everything
inlined at opt-level 3) is 28.2 KB and does not fit, and nothing smaller
can be moved without splitting it inside verified/core. With the numbers
below it does not need to: an instruction-cache simulation of the QEMU
trace (scripts/icache-sim.sh: TB trace, 32 KB 2-way LRU cache of 32-byte
lines, instruction fetches only) gives, for one run of richards,
deltablue and pystone on f2, 160 M instructions from flash and 9,822
line misses (a miss every 16,000 instructions; at roughly 100-200 cycles
a miss, under 1 % of the run). The hot code fits the cache; the data
fetches from flash (bytecodes and program heap of the images, rodata)
share it on the ESP32 and are not simulated, so this is a lower bound
that hardware has to confirm.

**Untrusted install** (f2 with `TOIT_TRACE_INSTALL`, scripts/installer-run.sh;
verified/core/PROGRESS.md "Device builds on format 2" has the table): the
verification of a 25 KB program (788 methods) with its shipped
certificate takes 404-412 M Xtensa instructions, which is 2-3.5 s at 240
MHz with a CPI of 1.2-2 (unmeasured); the free heap drops by about 23 KB
during it (every allocation of the system counts) from 64 KB, and the
program's table comes from its literal (no RAM). The whole install takes
8-10 s of virtual time in QEMU, dominated by the emulated flash writes,
so it says nothing about hardware. The untrusted images grow by 16 bytes
per method (a-hello: 50,688 -> 63,360 bytes).

### Checked under QEMU (classic ESP32)

scripts/suite-all.sh runs one boot container (qemu/progs/suite.toit) on
all three configurations: hello, the benchmarks above, GC stress, the
profiler (its system message decodes), service calls to a provider
container, preemption of a CPU-bound container (the suite's 20 ms sleeps
are at most 4.4 ms late), an uncaught exception in another container
(the stack trace decodes identically with `toit decode`), untrusted
installs (six accepted programs run and exit 0; deep sleep, no
certificate, another program's certificate and a trusted-compiled image
are rejected with VERIFICATION_FAILED, a format-1 image with
FORMAT_2_REQUIRED), and deep sleep. The suite's output is identical
between f1, f2cxx and f2 except for the untrusted installs, which f1
(no verifier) refuses. Deep sleep reaches `esp_deep_sleep_start` in all
three and then panics in `rtc_sleep_init`: QEMU does not emulate the RTC
sleep registers.

### Other targets

They keep format 1 and build as before (checked: C3, S2, S3 firmware;
the EC618 VM library, without the base and slot links, which need xmake).

- ESP32-C3 (rv32imc, no atomics): vstd's `alloc` uses `Arc`, which needs
  compare-and-swap. A custom target (riscv32imc with `+forced-atomics`,
  atomic CAS lowered to the `__atomic_*` calls ESP-IDF provides for the
  C3) and `-Zbuild-std`; 1-2 days, testable under Espressif's QEMU
  (esp32c3 machine).
- ESP32-S2 and S3 (Xtensa LX7): the esp-rs targets xtensa-esp32s2/s3-none-elf
  exist; the IDF mapping, the codegen check for LX7 (the S2 has no FPU)
  and the IRAM budget: 0.5-1 day each; the S3 runs under QEMU.
- ESP32-P4 (rv32imafc): the upstream target riscv32imafc-unknown-none-elf;
  0.5 day plus hardware.
- EC618 (Cortex-M3): the upstream target thumbv7m-none-eabi (atomics
  present); the CMake mapping and the two-stage slot link with the Rust
  archive (the SRL3 relocation of the slot must cover it); 2-3 days plus
  hardware.
- Cross hosts (Raspberry Pi, Windows, macOS): cargo targets for their
  triples; mostly CI work.

Still needs hardware: the core's speed from flash with the data fetches,
install time at 160 and 240 MHz, the free heap of a real system (WiFi
up) when the installer runs, deep sleep.

## Converted tools and tests

Every tool that reads bytecodes already decoded format 2 (tools/snapshot.toit
since phase 2); the default flip exposed the places that assumed format-1
method ids or header sizes:

| Item | Change |
|---|---|
| tools/snapshot.toit | `method-from-absolute-bci` finds a method by its id (format-2 headers have no fixed size); `dispatch-table-method-ids` maps format-2 dispatch entries (method indices) to method ids |
| tools/toitp.toit (`toit tool toitp`) | the dispatch table printed with method ids |
| tests/toitp (dispatch-snap, method-snap, bytecodes-snap, bytecodes-toitp) | method ids instead of `MethodInfo.absolute-entry-bci`; the wide non-local return is format 1 only |
| tests/optimizations/utils.toit | static call targets through `method-id-for-target` |
| tools/toit.toit | `toit compile --untrusted` |
| tools/firmware.toit | the format warning above |
| tests/sandbox (CMake, run-untrusted.cmake, sandbox-util, install-verdict) | images without twins; untrusted snapshots with `--untrusted` |
| verified/tools/untrusted_suite.toit | the reference side is `-Xbytecode_format=1` explicitly |
| lib/system/services.toit | the uninstall bug below |

Checked and unchanged (pass in format 2): stack traces and their
decoding in the system process, the profiler tests (the `repeat` built-in
keeps `repeat` out of profiles, as format 1's intrinsic did), the LSP
tests (bci to source), the envelope and firmware tests, snapshot-to-image
and the image tests, the vessels, the negative tests, the type-propagation
tests. tools/stacktrace.toit decodes native ESP-IDF backtraces, not
bytecodes. The intrinsics named in lib/core (`#primitive.intrinsics.*`:
smi-repeat, array-do, hash-find, hash-do) stay: in format 2 the compiler
lowers them to the built-ins of note 19 or to their Toit fallback.

## Format-1-only leftovers (to delete in the next step)

Marked `FORMAT-1-ONLY` in the source:

- tests/sandbox/field-access-test.toit, runtime-hardening-test.toit
  (C++ interpreter hardening), verify-reject-test.toit (C++ verifier);
- the format-1 half of tests/sandbox/invalid-utf-8-literal-test.toit;
- tests/sandbox/cli/format1-{refused,allowed}-snapshot
  (tests/sandbox/CMakeLists.txt);
- tests-toitp-bytecode-match-test (tests/toitp/bytecode_lister.cc against
  the `BYTE-CODES` table of tools/snapshot.toit).

Kept on purpose (compiler-internal format 1, as long as the propagator
interprets it): tests/type_propagation (52 golds, `-Xpropagate`),
tools/dump_types.toit, `BYTE-CODES` in tools/snapshot.toit,
tests/ctest/bytecode-test.cc (src/bytecodes.h ordering). Lost with the
C++ interpreter unless reimplemented on the core: the
`TOIT_CHECK_PROPAGATED_TYPES` CI job (.github/workflows/ci-host-build.yml).

## What still depends on format 1

From an inventory of the tree (line counts from `wc -l`, "est" where
format-1 code is mixed with shared code):

| Area | Files | Lines | Effort |
|---|---|---|---|
| C++ interpreter | src/interpreter_run.cc (all but `run_v2` hand-off, 2,329), interpreter_core.cc (`hash_do`, `fast_size`: ~145 of 439; `fast_at`, `compare_numbers` stay for primitives), interpreter.cc (~250 of 328), interpreter.h (~150; FRAME_SIZE, LINK_*_SLOT, UNWIND_REASON move to the compiler), method_entries.cc/.h (313, users process_group.cc, primitive_core.cc), objects.cc/objects_runtime.cc/objects.h Stack helpers (~115 est), primitive_core.cc spawn/task branches (~32), printing.cc (~215, only for `Interpreter::trace`) | ~3,560 | 3-4 d (replace `Method` handles by method indices in Process/Program/scheduler) |
| C++ verifier and hardening | src/verifier.cc (~2,100 of 2,234), verifier.h (~60), toit_run.cc `--verify` format-1 paths, `--fuzz`, `--dump` (~150), `FORMAT_2_REQUIRED`/`untrusted_format1` gating (~45 in primitive_programs_registry.cc, primitive_snapshot.cc, verifier_v2.cc, interpreter_v2.cc/.h), `TOIT_CHECKED_FIELD_ACCESS` | ~2,360 | 1-2 d |
| Snapshot and program | program.h `frame_marker`, entry `Method` accessors (~25); snapshot/image code is format-neutral; bump the envelope version | ~25 | 0.5 d |
| Compiler | emitter.cc (15 format checks), program_builder.cc (8), byte_gen.cc (6), compiler.cc, toitc.cc: ~200 lines of format-1 emission kept as the propagator's IR; only the user-facing selection goes (`-Xbytecode_format=1`, `TOIT_BYTECODE_FORMAT=1`, the CMake variable: ~35) | keep ~200 | 0.5 d |
| Tools | tools/snapshot.toit format-1 header and `BYTE-CODES` (~140), needed by dump_types and the propagation tests while `--propagate` writes format 1 | keep | 0 |
| Tests | the FORMAT-1-ONLY list above (~560 lines) | ~560 | 0.5 d |
| Flags | `untrusted_format1`/`TOIT_UNTRUSTED_FORMAT1`, `TOIT_VERIFY_VERBOSE`; `bytecode_format` becomes internal | | with the above |
| Devices | the classic ESP32 and the C6 build without the C++ interpreter (`TOIT_CXX_INTERPRETER=n`); C3, S2, S3, P4 and EC618 still link it (format 1) | | see Devices, "Other targets" |

The VM side is about 5,950 lines. Deleting them on hosts is 6-8
engineer-days with the test and CI updates. On devices the classic ESP32
and the C6 already build without it (CMake `TOIT_CXX_INTERPRETER`, see
Devices); deleting it everywhere waits for the other targets' bring-up
(C3, S2, S3, P4, EC618: 5-9 days, see "Other targets") or for dropping
them, and for the cross hosts' cargo targets.

## services-network-test: a real library bug

`ServiceProvider.uninstall` iterated over `_clients_` while
`ServiceManager_.close` removed each client from it (`_close_`). After
enough removals `Set.remove` shrinks and compacts the backing
(`shrink-if-needed_`). Format 1's HASH_DO intrinsic re-reads the backing
on every step and stops at its end ("We don't support this, but we also
don't want to crash", interpreter_core.cc), so it silently skipped the
clients that moved; format 2 has no HASH_DO and runs `Set.do`'s Toit loop,
whose bound was read before the iteration: OUT_OF_BOUNDS. Not a race; the
timing only decided how many clients were open at uninstall.

Reproduction (tests/services-uninstall-many-clients-test.toit, added):
open 5 or more clients to one provider, then `uninstall`. On upstream
master (format 1) `on-closed` runs for 3 of 5 clients ("Expected <5>, but
was <3>"): clients are left open, an upstream bug for a separate PR (the
fix is the one line in lib/system/services.toit: iterate over
`_clients_.to-list`). In format 2 the same test threw OUT_OF_BOUNDS in
`Set.do`. Both pass with the fix.

Related behavior difference, not changed: a program that removes from a
set or map inside its own `do` silently loses elements in format 1 and can
throw OUT_OF_BOUNDS in format 2 (Toit documents such modification as
unsupported).

## Requests to the core

None needed for this step. A nicety for the next one (not filed): the
launch verifier's message for a trusted-compiled program run untrusted
("unchecked opcode 106 in a program not in the unchecked mode") could say
"compile with --untrusted"; the C++ side can add that hint without the
core.

## Milestones

- M1 (bf521db9): the compiler's default is format 2 on builds with the
  core; the CMake cache variable `TOIT_BYTECODE_FORMAT` replaces
  `TOIT_SYSTEM_FORMAT2`; `--untrusted` for toit.compile (no twins,
  certificate); trusted compilation (twins) is the default and ships no
  certificate; devices and cross builds keep format 1; the sandbox tests
  compile their images without twins and the CLI tests write their
  snapshots with `toit.run --untrusted -w`.
- M2 (19150d80, and a follow-up keeping the line numbers): the
  services uninstall bug.
- M3 (71b2f071, and the optimization tests): toitp and the snapshot tools
  format-2 aware.
- M4: the untrusted suite against format 1, the firmware warning, the
  FORMAT-1-ONLY markers, -O2 and benchmark measurements, this document.

- M5 (1aba38f2, 85be00dc): `sandbox-integration` merged again (the
  contract table and grow_stack.render fixes); the verifier hints at
  `--untrusted` when a trusted-compiled program is launched untrusted.

## Gates (85be00dc)

Scripts in the artifacts directory (final.sh, suite.sh, bench.sh, o2.sh,
host32.sh); logs under suite/, bench/, o2/.

- ctest -j16, the new default (build/host, format 2 everywhere):
  1199/1202; failing only version and reader (not built) and
  udp-reuse-port-test (no multicast). services-network-test passes
  (tls-ubuntu-test, flaky, passed this run; it timed out in an earlier run).
- The same suite with `-DTOIT_BYTECODE_FORMAT=1` (build/host-f1, format 1
  everywhere): 1199/1202, the same three.
- The slow-configuration groups that inspect bytecodes or snapshots
  (optimizations, type_propagation, envelope, image, negative, pkg, cmake,
  ctest): 692/692 in both builds.
- verified/check.sh --tests: passed (spec 940, core 878 at both widths,
  audit, contracts, VeriFast, sandbox ctests 123/123). Before the M5 merge
  the contract table and grow_stack.render drifted (fixed on
  sandbox-integration by eb247dd9; not from this branch).
- Untrusted suite: 280 identical, the two known differences
  (program-name-test, set-map-remove-first-test).
- 32-bit host (build/host32, format 2 default): sandbox ctests 123/123.
- Classic ESP32 firmware builds (toit.bin 1,462,512 B, iram0.text 129,087
  B) with a format-1 system snapshot; installing a default-compiled
  snapshot into its envelope prints the warning.
- Benchmarks (callgrind in `Interpreter::run`, millions; `trs` the new
  default, `chk` the code untrusted programs run; recorded values from
  trusted-integration in parentheses): richards 1,075.3 (1,075.4),
  deltablue 758.8 (758.8), pystone 811.9 (812.0), json 1,314.5 (1,314.6),
  yaml 4,172.7 (4,173.1), strings 3,337.3 (3,337.3), RPC 412.7 (412.7),
  map-set 2,523.4 (2,523.4); checked richards 1,163.3 (1,163.3), RPC 425.4
  (425.4). C++ f1: richards 1,024.3, json 1,117.1. Not slower.
