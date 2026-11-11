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
(C3, S2, S3, P4) keep format 1 and record `[1]`; the EC618 records `[1]`
by default and `[2]` with `make ec618 EC618_BYTECODE_FORMAT=2`.

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
| 200 service calls between containers | 27,417 | 27,235 | 0.993 |
| CPU-bound container (20 M iterations) | 5,601,196 | 4,343,752 | 0.776 |

On Xtensa the core executes fewer instructions than the C++ interpreter
on most programs (on x86-64 it executes 5-20 % more, see above): icount
counts instructions, not cycles, and the C++ interpreter runs from IRAM.

**Flash, after the size work** (branch `device/size`; verified/core/
PROGRESS.md "Device size" has the attribution and the per-change table):
newlib's libm instead of compiler_builtins' math functions, the binary
laid out around the DROM extension instead of padding it to 64 KB, images
without unused heap blocks and two debugging aids on hosts only bring the
classic ESP32 with Jaguar to 1,775,744 B (still 71.8 KB over the OTA
partition) and the C6 to 1,871,152 B (29.4 KB to spare). Kconfig
`TOIT_VERIFIED_CORE_VERIFIER=n` leaves the verifier out (-29.6 KB) for
firmware without untrusted installs. The numbers below are from before.

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
change their layout over the air), a smaller core, or no table literal
for bundled containers (their tables in RAM again: 29.6 KB for Jaguar).
The core at opt-level s saves 9.2 KB on the ESP32 (1,671,872 bytes
system only: Jaguar still 99 KB over) and 6.7 KB on the C6 (1,764,768:
Jaguar fits with 4.7 KB to spare; its speed at s is unmeasured, the C6
has no QEMU).

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
are at most 4.4 ms late in all three), an uncaught exception in another container
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
- EC618 (Cortex-M3): builds and runs format 2 on the core (QEMU,
  mps2-an385), not the default yet; see "EC618" below.
- Cross hosts (Raspberry Pi, Windows, macOS): cargo targets for their
  triples; mostly CI work.

Still needs hardware: the core's speed from flash with the data fetches,
install time at 160 and 240 MHz, the free heap of a real system (WiFi
up) when the installer runs, deep sleep.

### EC618

Branch `device/ec618` (from `sandbox-integration` 43e27bd0; scripts, logs,
builds and QEMU runs: /home/flo/work/opentoit-sandbox-artifacts/ec618).
Nothing was flashed. **The EC618 firmware builds in format 2 on the core
without the C++ interpreter, base and slot links included, and the VM
library of that slot runs the device suite under QEMU (mps2-an385, a
generic Cortex-M3) with the same results as the ESP32 under QEMU. Format 1
stays the default.**

    make ec618                                    # format 1, C++ (as before)
    make ec618 EC618_BYTECODE_FORMAT=2 EC618_BUILD_DIR=build/ec618-f2

Makefile variables: `EC618_BYTECODE_FORMAT` (1 or 2), `EC618_BUILD_DIR`
(one per configuration; the base, `EC618_BASE_DIR`, is shared),
`EC618_RUST_OPT_LEVEL` (3, s, z), `EC618_CXX_INTERPRETER` (ON links both
interpreters, the envelope records `[1, 2]`), `EC618_VERIFIER` (OFF: no
untrusted installs). Format 2 compiles the system snapshot in format 2 and
writes `bytecode-formats` `[2]` into the envelope; `container install`
refuses format-1 snapshots for it (checked). The Rust target is the
upstream tier-2 `thumbv7m-none-eabi` (`rustup target add`; no fork),
set in toolchains/ec618.cmake.

**The Rust library on the Cortex-M3.** Builds for thumbv7m at 3, s and z
with LTO; nostd_check.sh builds it, `NOPANIC_ARCH=arm nopanic_check.sh`
finds no panic machinery at 3, s and z, and `thumb_codegen_check.sh`
(new; check.sh runs both when the target and an arm-none-eabi GCC are
installed) checks what the firmware assumes: v7-M Thumb-2 objects whose
wchar_t and stack-alignment attributes match GCC's (the FFI structs hold
no enums, whose size differs: GCC's arm-none-eabi uses small enums), no
FPU instructions, no movw/movt relocations, no atomic helpers. Atomics:
v7-M has LDREX/STREX, Rust's 8/16/32-bit atomics are native
(`target_has_atomic` 8, 16, 32, ptr; no 64-bit ones, which the core does
not use); the linked library contains none. Largest stack frames:
`verify` 684 B, `toit_vmverify_verify` 476 B, `run_loop` 324 B, against
the 8 KB scheduler-thread stacks.

Three things were needed for the slot link (two-stage link and SRL3
relocation, docs/ec618-design-notes.md):

- movw/movt. The relocator moves 32-bit words (R_ARM_ABS32) and branches
  into the base, and gen-slot-reloc aborts on an in-slot movw/movt pair.
  LLVM loads addresses with movw/movt on v7-M (the core had one pair, a
  switch table; compiler_builtins' math functions have more). The core is
  compiled with `-C target-feature=+no-movt` (literal pools, as GCC's code
  for the C++ side), in a `[target.thumbv7m-none-eabi]` section of
  verified/vmverify/.cargo/config.toml. rustc warns that the feature is
  unknown to it and passes it to LLVM; if a later rustc refuses it, the
  relocator needs movw/movt support (the device relocator,
  src/slot_reloc_ec618.cc, and gen-slot-reloc; 1-2 days).
  compiler_builtins' math stays out: localize-libm.cmake makes it local
  and newlib's (the base's) is linked, so the check sees none.
- Thread-local storage. `Stack::v2_frames_skip_` (objects.h) was
  `thread_local`; the EC618 toolchain emulates TLS (`__emutls_get_address`)
  and calls a weak TLS wrapper, a branch to address 0 that the
  relocation's byte-identity check (slot A relocated against an
  independently linked slot B) caught. The EC618 runs one scheduler thread
  (`OS::num_cores` is 1), so it is a plain static there.
- The Rust archive is linked after the `--whole-archive` group: the
  base's libgcc and newlib (`--just-symbols`) define the memory and
  soft-float helpers, so compiler_builtins' copies are not used (which
  matters: compiler_builtins' soft-float add returns the canonical NaN,
  libgcc's returns the NaN operand).

A bug of the format-1 build too (gen-slot-ld.toit, since #3199): the
slot's `.bss` had no address and followed the RTC-noinit region in the
ASMB (0x8c88): 9.7 KB ending at 0xbaf4, over the CP's AON memory backup
(0xa800) and rrcMem (0xb000), which `toit_start` zeroes. It is now placed
after `.data` in the VM's RAM pool, and the RTC region is checked against
0xa800. Untested on hardware; upstream candidate.

**Program images.** Nothing format-specific was needed in the image
path; this is what differs from the ESP32:

| | ESP32 | EC618 |
|---|---|---|
| bundled images | DROM extension after the app in the OTA partition, mapped through the flash MMU (64 KB pages) | in the VM slot (0xC0000 bytes, two slots) right after the VM body, XIP flash (one mapping for code and data) |
| relocation | relocated once for the extension address | relocated with the VM: the images' pointer words join the slot's SRL3 table (352 for the system image in format 2, 350 in format 1); writing the canonical image to slot B relocates them |
| installed containers | programs partition | flash registry partition (0xA8000 bytes), relocated on write, as on the ESP32 |
| word size, byte order | 4, little-endian | 4, little-endian |
| alignment | | Cortex-M3: unaligned LDR/STR allowed (unless CCR.UNALIGN_TRP), LDRD/LDM not; GCC and LLVM both emit unaligned single loads |

The method-table literal (`TMT1`) holds offsets, no addresses, so it adds
no relocations and is read in place from the slot or the registry. The
system image grows from 90,156 to 118,828 bytes (the literal: 16 B per
method).

**Sizes** (bytes; `make ec618`, slot A, tools: scripts/size-table.sh,
mapsizes.sh on the slot link's map). Budgets: a slot is 786,432 bytes
(VM body, bundled images, `.data` image and the relocation trailer); the
VM's RAM pool is 24,576 (8 KB `.data` and 16 KB `.bss` reserves of the
base); the heap is shared with the platform (354,240 bytes from
`end_ap_data` to `start_up_buffer`).

| | f1 | f2 | f2, opt s | f2, opt z | f2, no verifier | f2 + C++ |
|---|---:|---:|---:|---:|---:|---:|
| VM body (`.vm_a`) | 315,408 | 378,404 | 369,248 | 366,020 | 355,420 | 394,684 |
| of it Rust (core, primitives, verifier) | 0 | 74,511 | 65,349 | 62,131 | 53,246 | 74,511 |
| of it C++ interpreter (interpreter_run, method_entries) | 13,997 | 0 | 0 | 0 | 0 | 13,997 |
| of it format-2 glue (interpreter_v2, verifier_v2, v2_method_table) | 2,258 | 6,778 | 6,778 | 6,778 | 5,065 | 6,678 |
| bundled images (system) | 90,156 | 118,828 | 118,828 | 118,828 | 118,828 | 118,828 |
| populated slot | 411,026 | 502,324 | 493,136 | 489,902 | 479,262 | 519,192 |
| slot margin | 375,406 | 284,108 | 293,296 | 296,530 | 307,170 | 267,240 |
| `.data` + `.bss` (pool 24,576) | 10,420 | 9,908 | 9,908 | 9,908 | 9,908 | 10,420 |

mbedTLS is 123,153 bytes of every body; the rest of the VM about 174 KB.
Unlike the ESP32 there is no flash budget problem: format 2 adds 91 KB to
the slot and leaves 284 KB. The ESP32's saving options mostly do not
apply: newlib's libm is already used (the base's), there is no 64 KB
padding to remove. Opt-level s saves 9.2 KB at no cost in instructions
(below); z saves 3 KB more but costs 50 %; leaving the verifier out saves
21 KB. RAM: `.data` shrinks by 420 bytes (the C++ interpreter's
dispatch table); the method tables of bundled and installed images are
read from flash, so format 2 needs no table RAM (format 1 builds an entry
bitmap per program).

**QEMU.** tests/ec618-qemu (CMake option `TOIT_EC618_QEMU_HARNESS` of an
EC618 build directory, target `toit_ec618_qemu`; `run.sh` runs an
envelope). The harness links the objects of the slot (libtoit_vm.a whole,
the Rust library, mbedTLS), the EC618 base's prebuilt FreeRTOS kernel
(PLAT/libs/libfreertos.a, with its SysTick and CMSIS-RTOS2 layer) and the
base's heap (cmpctmalloc, heap_7.c, with the same `--wrap`s) for
QEMU's mps2-an385. It replaces the flash registry (RAM with NOR
semantics) and the peripheral event sources, gives the kernel's trace,
clock and sleep hooks and the TRNG (a fixed sequence) a body, and stubs
the other 125 base functions the VM references (generated from a probe
link and base.elf; reaching one stops the run). extension.toit writes an
envelope's images as the firmware tool bundles them, for an address in
the PSRAM; output and exit go through semihosting. Same heap size as the
base.

QEMU 9.2.2 (built user-locally from the Espressif fork's sources with the
arm-softmmu target). The device suite of the ESP32 work (hello,
richards, deltablue, pystone, JSON, maps, strings, GC stress, the
profiler, services between containers, preemption of a CPU-bound
container, an uncaught exception in another container, six untrusted
installs that run and exit 0, and the five rejections) gives the same
`SUITE` lines as the ESP32 under QEMU, in format 1 and in format 2 (format
1 refuses the untrusted installs: no verifier). The benchmarks' checksums
equal the 64-bit and 32-bit host builds'.

The primitive differential (tests/fuzz/primitive-diff.toit) on the
Cortex-M3, format 1 (GCC's C++ primitives) against format 2 (the Rust
ports): PRIMDIFF_RESULT. Against the 32-bit x86 host the traces differ
from call 22 on: a float subtraction with a NaN operand gives the
canonical NaN with soft float (libgcc) and the operand's NaN on x86, and
the pools diverge from there. With compiler_builtins' soft float, which
the harness linked at first, the two formats differed too (call 118:
libgcc's add keeps the operand's NaN, compiler_builtins' does not); the
firmware links libgcc's for both, and so does the harness now.

Instructions: QEMU's virtual clock is not one instruction per nanosecond
here (`-icount shift=0` gives 3.3 instructions per virtual nanosecond on
this machine model, calibrated with the libinsn plugin), so the counts
come from the plugin: whole runs of one program per benchmark, minus the
run of an empty program (millions):

INSN_TABLE

The core executes 5-23 % more instructions than the C++ interpreter on
the Cortex-M3 (as on x86-64, unlike Xtensa where it executes fewer), and
fewer on the GC stress. Instructions are not cycles: the EC618 runs from
XIP flash through a cache, the core's loop (`run_loop`, 19 KB here) is
larger than the C++ interpreter's.

Untrusted installs (shipped certificate): INSTALL_RESULT

Not covered under QEMU: the peripherals, cellular and networking, deep
sleep and the RTC memory, the watchdogs, OTA (relocate-on-write into slot
B, the anchor), real flash timing, the base's own heap use.

Requests to the core owner: none. For core/compact-methods: the EC618
needs nothing as long as the table literal stays free of absolute
addresses (images are only relocated at the words their relocation bits
mark, and the EC618 relocates them again on OTA) and its records are read
with at most 32-bit loads (Cortex-M3 faults on unaligned LDRD/LDM; LLVM
does not emit those for unaligned data).

Hardware-only unknowns: the core's speed from XIP flash (cache misses,
CPI) at 204 MHz (`CLK_CC_SEL_204M`); install time (the estimate below);
the free heap at boot with the modem stack up (EC618's
`system-free` statistic is not implemented: it reports 2^30-1);
whether the platform sets `CCR.UNALIGN_TRP` (the SDK sources do not; the
C++ VM would fault too); OTA from a format-1 to a format-2 slot (the slot
carries VM and images together, so they always agree; containers
installed in the flash registry in format 1 stop starting:
FORMAT_2_REQUIRED, as on the ESP32); deep sleep, peripherals, cellular.

Remaining before the EC618 can default to format 2:

1. A hardware run of the format-2 firmware: tests/hw/ec618 (136 files;
   its programs must be compiled in the firmware's format), the heap
   report, an untrusted install, OTA between an f1 and an f2 slot; 1-2
   days with the rig.
2. The `.bss` fix on hardware and upstream (0.5 day).
3. The default flip (`EC618_BYTECODE_FORMAT ?= 2`, probably at opt-level
   s) and CI: `rustup target add thumbv7m-none-eabi`, and the QEMU
   harness as a job (qemu-system-arm from the distribution has
   mps2-an385); 0.5-1 day.
4. Jaguar and Artemis: compile for the envelope's `bytecode-formats`, and
   the migration of format-1 containers installed in the field (shared
   with the ESP32).

### Before the C++ interpreter can be deleted

1. A flash budget for the classic ESP32 with Jaguar: still 72 KB over
   after `device/size` (a partition layout with 0x1c0000 OTA partitions,
   a smaller method record in the core plus the table literals in RAM,
   see verified/core/PROGRESS.md "Device size"), then the default flip
   (4f488c84) and the CI step for the Rust targets. The C6 fits now (29
   KB to spare) and could flip on its own.
2. The other device targets on the core (C3, S2, S3, P4; 4-6 days plus
   hardware; the EC618 needs a hardware run and the default flip, see
   "EC618") or dropping them; the cross hosts' cargo targets.
3. Hardware runs of the format-2 firmware (the hw test suite, `make
   test-hw-esp32`, compiles its programs with the host default, now
   format 2).
4. Jaguar and Artemis: compile format 2 for devices and read the
   envelope's `bytecode-formats` instead of assuming format 1 (outside
   this repository).
5. The host side as listed under "What still depends on format 1" (6-8
   days): the FORMAT-1-ONLY tests, `-Xbytecode_format=1`, toit.run's
   format-1 `--verify`/`--fuzz`, the `TOIT_CHECK_PROPAGATED_TYPES` job;
   format 1 stays inside the compiler for the propagator.

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
| Devices | the classic ESP32, the C6 and the EC618 build without the C++ interpreter (`TOIT_CXX_INTERPRETER=n`, `EC618_BYTECODE_FORMAT=2`); C3, S2, S3 and P4 still link it (format 1) | | see Devices, "Other targets" |

The VM side is about 5,950 lines. Deleting them on hosts is 6-8
engineer-days with the test and CI updates. On devices the classic ESP32
and the C6 already build without it (CMake `TOIT_CXX_INTERPRETER`, see
Devices); deleting it everywhere waits for the other targets' bring-up
(C3, S2, S3, P4: 4-6 days, see "Other targets"; the EC618 builds without
it, see "EC618") or for dropping
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
