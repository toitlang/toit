# Phase 4a progress (verified core, format 2 on x86-64)

## The verified loop on registers (branch core/fast-loop-proven, 2026-11-11)

A performance rewrite of the verified run loop keeping every proof
(DESIGN.md section 2a, "Room" in section 3): the hot state in registers
(stack cursors `view::Slot`), the room bound in the loop invariant (no
check per push), lazy finally records, one constant arm per opcode,
preemption merged into the calls' room check. The refinement relation is
unchanged (`m.with(r).refines(p)`); every register handler proves the
machine handler's postcondition; slow paths run the unchanged machine
handlers out of line (`step::bridge`). Nothing was assumed or admitted;
the allowlist grew by 7 groups (the cursor's 6, TRUSTED.md section 1, and
`settle`'s loop without decreases clause).

Progression (callgrind Ir inside `toit_v2_run`, TOIT_VERIFY=1, x86-64;
artifacts fast-loop-proven/ir/results.txt; C++ format 1 -O3: 1,023 M /
650 M / 762 M):

| Step | richards | deltablue | pystone |
|---|---|---|---|
| before (sandbox-integration) | 2,105 M (2.06) | 1,520 M (2.34) | 1,451 M (1.91) |
| locals, constants, branches on registers (rest bridged) | 5,626 M | 3,695 M | 3,056 M |
| + room invariant, calls and returns (rest bridged, room scan per bridge) | 14,290 M | 9,285 M | 6,958 M |
| + fields, type tests, operators | 2,141 M | 2,626 M | 2,977 M |
| + blocks, tail calls, globals, collections, ALLOCATE, PRIMITIVE | 1,678 M | 1,254 M | 1,338 M |
| + one arm per opcode, default arm unreachable (dispatch tail-duplicated: 120 sites); no SLP vectorizer | 1,353 M | 1,059 M | 1,117 M |
| + lazy finally records (no record-top register) | 1,286 M (1.26) | 987 M (1.52) | 1,082 M (1.42) |
| + instruction pointer as a code cursor (bci computed only where stored) | 1,231 M | 951 M | 1,040 M |
| + INVOKE_AT/AT_PUT fallback call on registers (pystone bridged 200 K times) | 1,234 M (1.21) | 952 M (1.46) | 940 M (1.23) |
| prototype (experiment/fast-loop, unproven, same checks) | 1,112 M (1.09) | 936 M (1.44) | 934 M (1.23) |

Per bytecode: 17.2 / 21.0 / 19.1 machine instructions (prototype 15.5 /
20.6 / 19.0, C++ about 14 per format-1 bytecode). What is left between
the verified loop and the prototype (richards; deltablue and pystone are
within 2 percent), from the profile (callgrind lines, richards): the full
field-access check of the machine's helper on LOAD/STORE_FIELD (tag,
task fields, field count: the fields.rs lines are 70 M with the loads; the prototype tested the instance
tag only), the program-heap test of field stores as two compares (31 M),
the store of the top frame's method into the machine at every call and
return (`refines` caches it, 12.5 M), the return's bottom-frame test
(8.3 M), and the `preempt_a_lot` test at POP (10 M; a debug flag the C++
release build compiles away). Each is a small proof change (a cheaper
helper, or the method read from the frame record in `Machine::with`),
not done for lack of time. Deltablue's remaining 1.46 is the format and the glue, as for
the prototype: C++ primitives (`smi_to_string`, 4 percent) and ALLOCATE
through C++ (2.4 percent), no ARRAY_DO/HASH_FIND.

Milestones (gates: verified/check.sh --tests at both widths, ctest -j16
1161/1164 with the known version/reader/udp-reuse-port-test, untrusted
suite 280 identical + the two known differences, prim_diff.sh 10 x
1,000,000 identical, compare_trace.toit --format 2 2,053,625 steps without
divergence, core_fuzz.toit --filter launch on ASan 30 minutes without a
crash, 32-bit host tests/sandbox 95/95):

- M1 (76448f09): the register loop with every family, room invariant,
  lazy finally records, D1/D2. Gates as listed (fuzz: 112,441 mutants,
  15,917 run, 0 crashes).
- M2 (this commit's parent, 17efcdd4 plus documentation): the instruction
  pointer as a cursor, the INVOKE_AT/AT_PUT fallback on registers. Gates
  as listed (fuzz seed 22: 102,811 mutants, 14,632 run, 0 crashes).

Wall time per iteration (minimum of 5, interleaved, load about 28 on 32
cores): C++ format 1 11.67 / 7.24 / 8.14 ms; before 20.08 / 14.57 / 13.61
ms; M2 11.62 / 8.77 / 8.05 ms, ratio 1.00 / 1.21 / 0.99 (prototype 0.94 /
1.22 / 0.96).

## Shipped certificates on devices, size diet (branch device/certificate-and-size, 2026-11-11)

1. Merge of `spec/shipped-certificate` (56ec778b) into integration
   (a7876e58): **certificate merge complete at 531bc8a0**. Conflicts:
   verified/core/Cargo.toml (the core stays `no_std`: toit_spec without
   `std` and without `infer`), verified/vmverify/Cargo.toml (both the
   `device-runtime` and the `infer` features), src/verifier.cc and
   src/verifier_v2.cc (the entry points take both the install-time program
   size and the shipped certificate; the FreeRTOS `verify_for_policy` runs
   the format-2 verifier with the certificate). Gates at 531bc8a0:
   verified/check.sh --tests (spec 892, core 781 verified at both word
   widths), ctest -j16 1161/1164 (version, reader not run;
   udp-reuse-port-test), 32-bit host tests/sandbox 95/95,
   verified/vmverify/tests/nostd_check.sh. Scripts and logs:
   artifacts device-cert/ (scripts/mk32.sh builds build/host32,
   scripts/fw-all.sh the ESP32-C6 firmware variants).
2. Installer (done, d59886d0): both commit paths verify with the image's
   trailing certificate block before the header is written, then erase the
   block's pages and give them back as a hole (`FlashRegistry.release-tail`).
   Device builds link no inference (CMake `TOIT_VERIFIED_CORE_INFER`, off
   for embedded builds) and reject an untrusted image without a certificate;
   hosts infer as a fallback and behave as devices with
   `TOIT_REQUIRE_CERTIFICATE=1`. Host envelopes carry the block in their
   bundled images. tests/sandbox/install-verdict-test.toit (64- and 32-bit
   hosts): install with the block, verdict recorded, block erased, restart
   without verification, corruption, rejection without a certificate in the
   device configuration, rejection of another program's certificate.
   verified/vmverify/README.md "Where it runs".
3. Size diet (done up to the core-side cfgs): ESP32-C6 toit.bin delta
   +200.8 / +187.6 / +176.7 KB (opt 3 / s / z, after the merge) -> +126.6 /
   +130.0 / +127.4 KB committed -> +94.4 / +89.1 / +87.8 KB with the
   requested cfgs D1 (checked loop) and D2 (layout tables) of
   OBLIGATIONS.md. Steps: inference off, checked-loop feature and the C++
   refusal of unverified format-2 programs, no formatting on devices, id
   table instead of `BTreeMap`, layout tables on hosts only, the verifier at
   opt-level z. Table and next candidates: verified/vmverify/README.md
   "Device size". Install-time RAM with a shipped certificate, 32-bit host:
   Rust peak 11 / 15 / 18 KB for 30 / 54 / 65 KB of bytecodes (was 12.4 /
   16.4 / 19.4; with the inference 46 / 76 / 80), plus the VM's `V2Method`
   table (20 B per method, 19-35 KB), now the largest item (OBLIGATIONS.md
   D3); README "Memory".

Gates at d655dba6: verified/check.sh --tests (spec 892, core 781 verified
at both widths, audit passed), ctest -j16 1161/1164 (version, reader not
run; udp-reuse-port-test), 32-bit host tests/sandbox 95/95,
nostd_check.sh (artifacts device-cert/gate-summary.txt, scripts/gate.sh).
Still needs hardware: install with a certificate on the ESP32-C6 (flash
erase of the block, install time, free heap during verification), the
speed of the core at opt 3 from flash, everything listed under Phase 5.

## Phase 5 (branch phase5/portability, 2026-11-11)

Portability: 32-bit words, no_std, device build, install-time
verification (07-verified-sandbox-plan.md, Phase 5).

1. 32-bit words, with proofs (done). One source for both widths
   (DESIGN.md section 3a); verified/check.sh verifies spec and core for
   the host and for `i686-unknown-linux-gnu` (Verus with vstd built and
   verified for the target by verified/tools/verus_target.sh: vstd 2159
   verified; spec 842, core 781 verified, 0 errors, at both widths).
   Layout changes for both widths: 5-word frame records (handler height
   and bci), 5-word finally records (target bci and height), Stack header
   try-top `rtop | ftop << 16` and a plain bci word, block references
   `frame << 16 | slot`, `TOIT_V2_ACCEPTED` 32 bits. Genuine 32-bit
   findings of the proof: LOAD_SMI_U32/LOAD_METHOD operands need the smi
   check the verifier makes (the handler now takes it from the step not
   being stuck), float_to_raw32 can need a large integer, the raise
   messages (selector, class id, entry) can exceed a smi, the spec's
   primitive contracts had the 64-bit smi range (`prim_core::smi_in`, now
   per target), byte-slice bounds compared through a truncating cast.
   64-bit cost of the uniform layout: Ir inside the interpreters
   (TOIT_VERIFY=1, artifacts phase5/ir.sh) richards 2,105 M (before
   2,097 M), deltablue 1,520 M (1,513 M), pystone 1,451 M (1,446 M): +0.4 %.
2. 32-bit host (done): build/host32 (toolchains/host32.cmake; CMake picks
   the Rust target i686-unknown-linux-gnu, rustup installs it without
   root; lib32 glibc/gcc multilib were already installed). Results
   (artifacts phase5/): tests/sandbox 95/95; untrusted suite 280/282
   identical, the two known differences (program-name-test,
   set-map-remove-first-test, as on 64-bit); prim_diff.sh 10 x 1,000,000
   calls identical; format-2 trace comparison on the debug 32-bit VM
   (`--word-bits 32`) 2,061,523 consecutive steps without divergence
   (sort 1,152,900, control 397,559, maps 467,701, numbers 43,363);
   core_fuzz.toit 20 min on an ASan 32-bit build, launch filter, seed 32:
   41,845 mutants, 5,721 accepted and run, 0 crashes. Found: the 32-bit
   host compiled doubles with x87 code (80-bit intermediates: double
   rounding), so `float_divide` differed by one ulp from the Rust port
   (and from 64-bit hosts and devices); toolchains/host32.cmake now uses
   `-msse2 -mfpmath=sse`. ASan 32-bit builds need
   `-DCMAKE_EXE_LINKER_FLAGS_ASAN=-fsanitize=address,undefined` (mbedtls
   adds UBSan to its ASan flags).
3. no_std (done): verified/core is `#![no_std]` (vstd without `std`; the
   float primitives call the C library's sqrt/ceil/floor/trunc, which the
   C++ ones use too); verified/spec's `exec_step` builds no_std (the
   `compare_mixed` implementation moved out of the std-only interpreter);
   verified/vmverify without `std` and with `device-runtime` supplies the
   global allocator (the VM's malloc/free/realloc) and the panic handler
   (`toit_vmverify_panic`, FATAL) and is built with Cargo profile `device`
   (panic = abort, LTO, codegen-units 1). Hosts keep std and
   `catch_unwind` (a verifier panic rejects the program).
   verified/vmverify/tests/nostd_check.sh builds spec, core and the device
   library for riscv32imac-unknown-none-elf (ESP32-C6, H2) and
   riscv64imac, unpatched. ESP32-C3 (rv32imc) is not possible as is: vstd's
   `alloc` feature uses `alloc::sync::Arc` and atomic swaps, which
   riscv32imc-unknown-none-elf (no A extension) lacks.
4. Device build (done up to flashing): see "Device sizes" below.
5. Install-time verification (done): verified/vmverify/README.md "Where it
   runs"; test tests/sandbox/install-verdict-test.toit (64-bit and 32-bit
   hosts).

Gates (2026-11-11): verified/check.sh --tests (Verus 64-bit and 32-bit,
audit, layout, spec differential, vmverify tests, sandbox ctests);
ctest -j16 on the 64-bit host 1161/1164 (version, reader not run;
udp-reuse-port-test: no multicast); tests/sandbox 95/95 on 64-bit and
32-bit hosts.

Still needs hardware: flashing the ESP32-C6 firmware and running the
device test subset and the heat-pump demo with an untrusted container;
the free heap of a running system and the verifier's peak there; install
time and boot time (CRC of verified images) on the device; the speed of
the core from flash vs IRAM (the IRAM proposal below); the layout check
run on the device (struct offsets of the riscv32 C ABI); the 72-hour soak
with a fuzzing container.

### Device sizes

Rust library alone, riscv32imac, linked into a minimal executable with
--gc-sections (verified/vmverify/tests/device_size.sh, split by
verified/tools/device_size.toit; text by component, rodata is anonymous
in Rust and only totalled; artifacts phase5/device-sizes.txt):

| Component (text, bytes) | opt 3 | opt 3, no tail-dup | s | z |
|---|---|---|---|---|
| core: verified loop and cold paths | 41,420 | 39,500 | 37,978 | 35,054 |
| core: checked loop | 20,788 | 20,336 | 22,738 | 20,588 |
| core: primitives | 15,458 | 15,378 | 13,376 | 12,404 |
| verifier: checker | 19,800 | 19,770 | 20,420 | 19,816 |
| verifier: heap check | 1,888 | 1,792 | 1,894 | 1,530 |
| verifier: inference | 40,138 | 39,984 | 30,502 | 23,422 |
| glue (vmverify, spec other) | 8,222 | 8,164 | 6,308 | 5,976 |
| Rust formatting | 5,776 | 5,766 | 5,756 | 5,732 |
| Rust panics | 190 | 190 | 190 | 190 |
| other core/alloc | 7,440 | 7,396 | 9,542 | 10,888 |
| compiler builtins (soft float, i64) | 3,258 | 3,258 | 3,258 | 3,352 |
| text total (Rust) | 164,378 | 161,534 | 151,962 | 138,952 |
| rodata (all, linked) | 24,370 | 24,370 | 30,362 | 31,722 |

The tail-duplication flag only matters at opt 3 (+2.9 KB). Without std
the 711 KB of std/alloc/core of the host build shrink to about 13 KB
(formatting, panics, other core/alloc). What a device could drop: the
checked loop (about 21 KB; only unverified trusted format-2 programs use
it, and devices run trusted code in format 1), the inference if
certificates were shipped with the image (24-40 KB, plus part of the
rodata), formatting (about 6 KB: only diagnostics use it; messages could
become codes).

ESP32-C6 firmware (ESP-IDF 5.4.2 from the main checkout, toolchain
esp-14.2.0_20241119; `idf.py build` of toolchains/esp32c6 with a copy of
its sdkconfig plus `CONFIG_TOIT_VERIFIED_CORE=y`; never flashed;
artifacts phase5/firmware-sizes.txt). Deltas against the same build
without the option (which also leaves out the C++ format-2 glue):

| Rust opt-level | toit.bin | .flash.text | .flash.rodata | DRAM data+bss | IRAM | run_loop (flash) |
|---|---|---|---|---|---|---|
| 3 | +187,040 B (1,575,904 -> 1,762,944) | +165,318 | +21,704 | +8 B | 0 | 23,244 B |
| s | +179,280 B | +151,580 | +27,696 | +8 B | 0 | 21,458 B |
| z | +172,880 B | +143,900 | +28,968 | +8 B | 0 | 19,670 B |

Static RAM is unchanged (the Rust code has no statics besides the
allocator handle); the verifier and the core allocate from the heap. The
hot loop lands in flash (`step::run_loop` at 0x4212..., executed through
the instruction cache), while the C++ interpreter (`Interpreter::run`,
19 KB) is in IRAM (INTERPRETER_CORE, 0x4080...). Proposal: put
`run_loop` (the dispatch with the inlined verified handlers; cold paths
stay out of line) in IRAM with `#[link_section = ".iram1.toit_run_loop"]`
under a `device-iram` feature (ESP-IDF's linker script maps `.iram1.*`
to IRAM), 19-23 KB of the 512 KB SRAM; not done, as it needs a speed
measurement on hardware to be worth the SRAM. Two fixes were needed to
link: `Stack::v2_frames_skip_` is `thread_local`, which the
initial-exec TLS model reaches through a GOT that ESP-IDF's linker script
discards (now local-exec on FreeRTOS), and a `%ld` format for `word`.
The layout check does not run for embedded builds (it cannot run on the
build host); the object layout constants are those of the 32-bit host
(checked there), and the FFI structs follow the C ABI on both sides.

### Verifier memory (30-60 KB programs)

Rust heap high-water mark of one verification (counting allocator,
`toit_vmverify_mem` on dumps; per-method maps and global part split by
MEM_DEBUG; artifacts phase5/vmem.log), 32-bit build (64-bit in brackets):

| Program | Bytecodes | Methods | Global part (per-method tables) | Largest method's maps | Peak |
|---|---|---|---|---|---|
| heat-pump-test | 23.4 KB | 764 | 23.6 KB (27.1) | 3.0 KB | 31.9 KB (35.4) |
| run-image | 48.3 KB | 1,447 | 46.5 KB (53.0) | 6.9 KB | 56.8 KB (63.4) |
| toit.run | 56.0 KB | 1,597 | 49.3 KB (55.8) | 6.9 KB | 60.4 KB (67.0) |

The phase-2 peak above the global part (maps of the method being checked,
checker state) is 5-9.5 KB. The heap check itself keeps almost nothing
(the dump path counts below 1 KB); in the VM the conversion from VM memory
adds the object work list and id map: the in-VM peak (TOIT_VERIFY_TIME=1,
64-bit) is 45 / 75 / 84 KB for the three programs, so conversion plus
heap-check state is about 10-17 KB. A 30-60 KB program thus needs about
50-80 KB of transient heap at install time on a 32-bit device; the
ESP32-C6 has 512 KB of SRAM, of which a running Toit system typically
leaves a few hundred KB free, so it fits while the system runs, but not
next to a large application (no hardware here to measure the free heap).

## Performance pass (branch core/prims-integration, 2026-11-11)

Part 2. Three kept steps (DESIGN.md section 8, "Performance pass"):
dispatch through one jump table without a range check, `Env` owning the
`Program`, tail-duplicated dispatch. Instructions inside the interpreters
(format 2 / format 1): richards 2.36 -> 2.05, deltablue 2.69 -> 2.33,
pystone 2.26 -> 1.90. One new trusted item, `view::proven_unreachable`
(`requires false`).

| Benchmark | f1 Ir | f2 Ir part 1 | f2 Ir now | Ir ratio part 1 -> now | f1 wall ms | f2 wall part 1 | f2 wall now | wall ratio part 1 -> now |
|---|---|---|---|---|---|---|---|---|
| richards | 1,024 M | 2,420 M | 2,097 M | 2.36 -> 2.05 | 10.99 | 21.02 | 18.58 | 1.91 -> 1.69 |
| deltablue | 650 M | 1,751 M | 1,513 M | 2.69 -> 2.33 | 7.11 | 15.25 | 13.70 | 2.14 -> 1.93 |
| pystone | 762 M | 1,724 M | 1,446 M | 2.26 -> 1.90 | 7.69 | 13.52 | 12.93 | 1.76 -> 1.68 |

Ir: callgrind inside the interpreters (format 2 with TOIT_VERIFY=1, the
verified loop untrusted programs get). Wall: time per iteration, minimum
of 10 runs, both format-2 binaries in the same session (load 13 on 32
cores, so about +-5 %); artifacts prims-integration/wall1.txt, bins/.
Gates after part 2 (merged sandbox-integration f31fdca2): `verified/check.sh --tests` passes (spec 842, core 781 verified);
ctest -j16 1160/1163 (version, reader, udp-reuse-port-test); untrusted suite
(verified/tools/untrusted_suite.toit) 280 identical, the two known
differences; prim_diff.sh 10 x 1,000,000 calls identical; fuzz
(core_fuzz.toit, ASan build of 983886e2, launch filter, seed 13, 20 min):
75,925 mutants, 10,925 accepted and run, no crash (prims-integration/fuzz2);
compare_trace.toit --format 2 on the four trace programs: 2,053,625
consecutive steps, each stopping at the environment-dependent primitive.

Superinstruction candidates (most frequent opcode pairs, reference
interpreter traces of the benchmarks with a harness without
`process_stats`; artifacts prims-integration/pairs):

| Pair (opcode numbers) | Count (all three) | Share of 166.3 M steps | Fusion |
|---|---|---|---|
| BRANCH_IF_FALSE -> LOAD_FIELD_THIS (83, 98) | 5.19 M | 3.1 % | (control flow; not a fusion) |
| LOAD_FIELD_THIS -> LOAD_SMI_U8 (98, 26) | 4.57 M | 2.7 % | with the next two: field == small constant, branch |
| LOAD_SMI_U8 -> INVOKE_EQ (26, 62) | 3.68 M | 2.2 % | compare with an immediate |
| INVOKE_EQ -> BRANCH_IF_FALSE (62, 83) | 3.57 M | 2.1 % | fused compare-and-branch |
| POP_1 -> LOAD_FIELD_THIS (41, 98) | 3.15 M | 1.9 % | |
| STORE_FIELD_THIS -> POP_1 (94, 41) | 3.08 M | 1.9 % | STORE_FIELD_THIS_POP |
| LOAD_SMI_1 -> INVOKE_ADD (25, 73) | 2.47 M | 1.5 % | increment |
| INVOKE_VIRTUAL -> LOAD_FIELD_THIS (58, 98), and back (98, 58) | 2.27 M, 2.25 M | 2.7 % | |
| LOAD_LOCAL_0 -> BRANCH_IF_TRUE (14, 82) | 1.95 M | 1.2 % | test-local-and-branch |
| INVOKE_LT -> BRANCH_IF_FALSE (63, 83) | 1.92 M | 1.2 % | fused compare-and-branch |
| AS_CLASS -> STORE_FIELD_THIS / RETURN (48, 94 / 48, 91) | 1.90 M, 1.80 M | 2.2 % | typed field store / typed return |

Per benchmark (steps: richards 71.6 M, deltablue 45.4 M, pystone 49.3 M),
richards is dominated by the field-test pattern (LOAD_FIELD_THIS,
LOAD_SMI_U8, INVOKE_EQ, BRANCH_IF_FALSE), deltablue by AS_CLASS -> RETURN
and the same compare-and-branch, pystone by INVOKE_EQ/INVOKE_ADD with
small constants. A fused compare-and-branch (INVOKE_EQ/LT/... followed by
BRANCH_IF_FALSE/TRUE, 5.5 M) and STORE_FIELD_THIS_POP (3.1 M) are the
clearest candidates; each removes one dispatch (about 6 instructions
after the tail duplication) per occurrence, together about 1 % of the
instructions; the larger part of a step is the handler, not the
dispatch.

REPEAT and HASH_FIND (not implemented; note 16). Costs on the verified
loop now (callgrind, artifacts prims-integration/loops, `loops.sh`,
`steps.sh`): an `int.repeat` iteration with a one-line body is 19 spec
steps in format 2 (12 in `SmallInteger_.repeat`, 7 in the block) against
8 dispatches in format 1, and costs 457 instructions (format 1: 171); a
REPEAT instruction (one dispatch per iteration that calls the block)
removes 11 steps, about 265 instructions at the loop's 24 per step:
about 230 per iteration (-50 %). A string-key map lookup (1,000 keys) is
193 steps (145 in `find-body_`) and 5,683 instructions (format 1:
2,647); a non-re-entrant HASH_PROBE that walks the index and returns to
Toit at each hash match leaves about 20 of the 145 steps: about 2,200
instructions (-60 %). Over the suite (note 16's step counts:
SMI_REPEAT +49.9 M steps, HASH_FIND +3.9 M of 317 M format-2 steps)
REPEAT would save about 15 % of all format-2 instructions, almost all of
it in loop-heavy programs (list-test: 38 M of its 38.6 M extra steps),
and HASH_FIND about 1 % of the suite but about 25 % of the map-heavy
tests (map-test, set-map-middle-gap-test, rebuild-hash-index-test: 3.1 M
of 12.5 M steps). None of the three benchmarks uses maps; pystone's main loop is one
`repeat` (its body dominates), deltablue iterates lists with `do`.

## Rust primitives wired in (branch core/prims-integration, 2026-11-11)

Part 1: merge core/primitives (b1d51876) into sandbox-integration
(b375e252) and run the Rust primitives from the verified loop.

1. Heap model: integration's V5. A byte-array object is `Body::Bytes`
   only when internal or raw external at a non-null address; mapped files
   and resource proxies are opaque. The primitives decode byte arrays with
   `bytes_len` (`prims::blob::ByteArg`: Bytes / Not / Opaque) and return
   `NotPorted` for opaque ones (C++ handles them); `byte_array_content`
   requires a model byte array and always returns a view. The trusted
   `Heap::lemma_body_tag` is gone (the tag facts follow from
   `abs::obj_model_ok`); one `double_bits`, one `large_int` (the
   primitives' `large_integer_value` and duplicate `double_bits` removed;
   identical contracts); `byte_array_is_raw` replaced by `bytes_len`.
   `prims::tags_ok` carries the obj_model_ok tag facts through the
   primitives' heap lemmas. `NeedsGc` now leaves the heap unchanged.
2. Wiring: `primitive::op_primitive` looks the core primitive up in the
   policy's core arities (`PrimitivePolicy::core_arities`, a table in
   `toit_v2_context`; arity + 1 where the policy resolves the VM's own
   entry) and runs `prims::call` (`op_rust_primitive`) without save and
   reload; `NotPorted`/`NeedsGc` fall back to the C++ lookup and call,
   which collects and retries. Proven: `lemma_rust_args` (heap_inv and
   args_ok from `Machine::inv`, block references as their smis),
   `lemma_refines_heap` (a primitive's heap keeps `refines`),
   `lemma_completion` (the outcome is a `prim_returns` completion).
   Removed: `TOIT_V2_RUST_PRIMITIVES`, prims/bridge.rs, the lookup's `rust`
   flag, `toit_v2_primitive_gc`/`toit_v2_leave_primitive`. The checked
   loop calls only C++ primitives.
3. Spec (verified/spec/format/SPEC-CHANGELOG.md, 2026-11-11):
   `array_at_put_spec` in the C++ decoding order (the `at_put_gap` is gone),
   `prim_core::core_contract` is the else branch of `prim_refined`,
   `prim_spec` refines only arguments without block references
   (`plain_args`: `int_parse` takes a block; without this the precise
   contracts were unsatisfiable for such calls, also for C++),
   `byte_array_at_contract` allows mapped files (opaque under V5).
4. vmverify: `from_vm.rs` models an external byte array without raw bytes
   at an address as an opaque object (V5); unit test
   `models_external_byte_arrays_as_the_core`.
5. prim_diff.sh compares trusted format 2 (checked loop, C++ primitives)
   with untrusted (verified loop, Rust ports).

Instructions per primitive call (callgrind inside `toit_v2_run`, 100,000
calls of a primitive method minus the same loop calling a plain method;
artifacts prims-integration/primcall): before (C++ through the verified
handler: lookup call, save, call, reload) smi_add 288, string_length 316,
array_at 293, float_add 360, blob_equals 306; after (Rust, table lookup,
no save/reload) 122, 114, 117, 213, 148.

Gates: `verified/check.sh --tests` passes (spec 842, core 780 verified, 0
errors); ctest -j16 1160/1163 (version, reader, udp-reuse-port-test);
untrusted suite 280 identical, the two known differences; prim_diff.sh 10
seeds x 1,000,000 calls identical; fuzz (ASan build of 2c901d48, launch
filter, seed 11, 20 min, 11 seed programs): 76,625 mutants, 10,718
accepted and run (8,772 exit 0, 1,354 exit 1, 562 exit 255, 30 timeouts),
no crash (artifacts prims-integration/fuzz1).

**Part 1 complete: commit 87cf044b** (merge 46fad52c, wiring 2c901d48,
documentation 87cf044b); it can be merged without the performance pass.

Trusted items of the core (TRUSTED.toml occurrences): integration 143
(external_body 55, unsafe 48, plain_rust_item 26, uninterp 7, assume_new
4, other 3), core/primitives 198, now 198 (external_body 84, unsafe 63,
plain_rust_item 34, uninterp 10, assume_new 4, other 3): the primitives'
accessors, `Content`, `Allocator`, fp.rs and the index table; minus
`lemma_body_tag`, `large_integer_value`, the duplicate `double_bits`,
`byte_array_is_raw`, the bridge (plain_rust_file, assume_new),
`PrimitiveRef::rust`, the primitive GC calls.

## Second proof pass (branch core/refinement-2, 2026-11-10)

Goal: shrink the assumed `step_unverified` (and `grow_bridge`) to leaf
contracts. Done: both are gone; every format-2 opcode has a verified
handler.

1. Operator slow paths (ops.rs, numbers.rs): doubles, large integers,
   `compare_numbers` (mixed: the spec crate's trusted `x_compare_mixed`),
   double arithmetic (a GC point, `gc_allocate_double`), IDENTICAL of
   doubles/large integers/strings, the virtual-call fallback.
   `smi_arith_word` made exact (it missed `0 << 63`). Heap model: doubles,
   large integers, strings, byte arrays (TRUSTED.md V5).
2. Collections (arrays.rs): `fast_at` (fuel 8) and `fast_size` on arrays,
   lists, byte arrays, slices, copy-on-write byte arrays, large arrays.
3. Tail calls (tail.rs): `replace_frame`; the lambda's method id, kind and
   captures and the initializer id are checked as the spec checks them.
4. Merged spec/raise-and-resources: `advances` is now `theorem::outcome`
   (completed outcomes); `step::source` for paths that are spec
   alternatives. The core's own `resource_throw`/`exception_like` are gone.
5. Raise (raise.rs): `Outcome2::Raise` completed by `prim::raised`
   (`gc_allocate_exception` leaf; the verified unwinding; out of memory
   throws roots[4]); every raise site uses it with format 1's message.
6. Resources: ALLOCATE and double out of memory, stack growth
   (`gc_grow_stack` leaf) with stack overflow (raise of roots[28]) and out
   of memory: `prim::resource_throw`.
7. PRIMITIVE (primitive.rs): lookup, arity, `gc_call_primitive` leaf (its
   result is a `theorem::completion`), completion by status.
8. `ffi::Accepted`: the verified loop is entered only for a table the
   launch-time verifier accepted (C++ marks the `V2MethodTable`).
9. Trusted review (TRUSTED.md section 7); `StackMem::header/set_header`
   tightened.

Gate: core 389 verified, 0 errors; spec 766 (after merging
sandbox-integration e9a6c08a). Tests: tests/sandbox 94/94 (incl. layout);
untrusted suite 280 identical, the two known differences
(program-name-test, set-map-remove-first-test).

Trusted items of the core (TRUSTED.toml, occurrences): before 127
(external_body 46, unsafe 41, plain_rust_item 26, uninterp 7, assume_new
4, other 3), after 143 (external_body 55, unsafe 48, plain_rust_item 26,
uninterp 7, assume_new 4, other 3): +7 heap accessors (+7 unsafe), +5
leaf contracts (allocate double, allocate exception, grow stack, call
primitive), -2 assumed bridges (`step_unverified`, `grow_bridge`), which
stood for the whole checked interpreter's refinement.

Instruction counts inside the interpreter (callgrind, TOIT_VERIFY=1, as
in DESIGN.md section 8): richards 2,420 M (f1 1,024 M, 2.36x; was 2.44x),
deltablue 1,782 M (650 M, 2.74x; was 2.92x), pystone 1,772 M (762 M,
2.33x; was 2.87x).

Wall time (bench.sh, TOIT_VERIFY=1, minimum of 5, after the fuzz run on
a shared machine): richards 10.12 / 18.69 ms (1.85x), deltablue 6.54 /
13.30 ms (2.03x), pystone 7.03 / 12.62 ms (1.80x).

Fuzz (ASan build, launch filter, seed 7, 23 min, 11 seed programs):
80,154 mutants, 11,309 accepted and run (9,176 exit 0, 1,477 exit 1, 633
exit 255, 23 timeouts), no crash. Results:
/home/flo/work/opentoit-sandbox-artifacts/refinement2/fuzz1.

Open: wiring the Rust primitives of core/primitives (heap-model conflict,
OBLIGATIONS.md R-prims); the performance pass (DESIGN.md section 8).

## Proof half (branch core/refinement, 2026-11-10)

Milestones (newest last):

1. Spec import: the core crate depends on `toit_spec` (Cargo) and Verus
   imports the spec's exported metadata (`verified/check.sh` verifies the
   spec first with `--export`, then the core with `--import`).
   Abstraction (`src/abs.rs`): value encoding `enc`, frame records
   `frames_rel`, program tables `prog_rel`; ghost state `Machine::g`
   (`State2`) with `Machine::refines`. Run loop in Verus (`src/step.rs`):
   invariant `refines && wf && accepts`, each step calls the spec's
   `lemma_step`. Proven refinement (handler result == `spec::step`):
   locals, constants, LOAD_METHOD, static globals, POP, branches. Checks
   removed: instruction in method (the `mfast`/`mend` cache is gone),
   slot existence, literal/global index, LOAD_METHOD range, branch target
   and direction. Other opcodes go through `step_unverified` (contract
   ASSUMED, allowlisted). Gate: core 174 verified, 0 errors.
2. Calls (INVOKE_STATIC, INVOKE_VIRTUAL(_WIDE)), RETURN(_NULL) with the
   caller's finally entry; heap model accessors (class id, tag, fields).
3. Fields (all field opcodes and the accessor fast paths), type checks,
   blocks (LOAD_BLOCK, LOAD/STORE_OUTER, LOAD_OUTER_BLOCK, INVOKE_BLOCK),
   operator smi fast paths and IDENTICAL (types, blocks and operators by
   sub-agents on their own branches, merged).
4. Accepted programs only: `toit_v2_context.accepted` (untrusted or
   -Xverify); others run on the checked handlers (runtime-hardening-test
   crashed the core with a patched unverified program before).
5. Spec changes merged (R5 task fields: the core's handlers implement
   `field_readable`/`field_writable` exactly; R1 finally records: RETURN
   follows `fins_popped`; the core's own records are on branch
   core/refinement-r1, in progress).
6. End-to-end theorem `src/theorem.rs` (replaces the stub
   obligations.rs): `theorem_first_run`, `theorem_next_run`.
7. HALT, dynamic and lazy globals, ALLOCATE (a GC point with a trusted
   contract over the abstraction, reload proven), plain-array
   INVOKE_AT/AT_PUT/SIZE (sub-agent). Slow paths call the checked
   dispatch out of line (inlining a copy at each cost 14% on richards).
8. Merged sandbox-integration with verified/vmverify: the theorem's
   loader hypotheses are established by the VM at untrusted launch.
   Gate: core 282 verified, 0 errors.

10. Merged core/refinement-r1 (finally records); the alloc reload
    decodes the new header (record top, bci word with the record count).

Final status (2026-11-10, after merging sandbox-integration 7a69e0b4):

- Gate: `verified/check.sh --tests` passes; core 328 verified, 0 errors
  (Verus about 9-15 s wall), spec 690. No assume/admit.
- Proven refinement: every opcode except INVOKE_STATIC_TAIL,
  INVOKE_LAMBDA_TAIL, INVOKE_INITIALIZER_TAIL and PRIMITIVE; within the
  verified opcodes the raising paths and the slow operator/collection
  paths are assumed (OBLIGATIONS.md section 2).
- End-to-end theorem proven (`src/theorem.rs`), given TRUSTED.md
  section 6.
- Tests: tests/sandbox 93/93 (field-access-test green since the
  integration merge); untrusted suite 279/281 identical (the two known
  differences program-name-test and set-map-remove-first-test; before:
  276/279); channel-retention-test and
  services-resource-close-pressure-test pass in format 2.
- Fuzz (ASan, verified/core/fuzz): 15 min spec filter (11,852 mutants,
  1,650 run), 16 min launch filter (49,687 mutants, 7,070 run), final
  16 min launch filter on the final code (59,910 mutants, 8,627 run): no
  crash, no stuck state.
- Benchmarks: DESIGN.md section 8, "After the proof half".

Next: verified `raise` (needs spec R7) and `replace_frame` (tail calls);
PRIMITIVE's completion contract and ported primitives (S1); double fast
paths (pystone); the checked loop's speed for unverified trusted
programs; the 6% the verified unwinding costs in the loop head.

9. Finally records (spec change R1, format note 17, branch
   core/refinement-r1): entering finally code with an unwinding writes a
   4-word record after the frame records instead of allocating a heap
   token (DESIGN.md section 3); C++ copies, shrinks and reports the
   records with the frame records. The abstraction relates `State2.fins`
   to the records (`fins_rel`). Proven: RETURN/RETURN_NULL and calls with
   the records (`do_return` drops the popped frame's records,
   `fins_popped`; `push_call` moves them), and (src/unwind.rs) THROW, TRY,
   UNWIND, NON_LOCAL_RETURN and NON_LOCAL_BRANCH against `spec::step`,
   including the unwinding loop over frames, `enter_finally` with a
   record, `pop_frame`; raising stays unverified. Gate: core 298 verified,
   0 errors. Cost: the verified unwinding in the run loop adds about 6
   percent instructions to richards and 4.5 percent to deltablue on the
   verified loop (callgrind, `TOIT_VERIFY=1`, against routing these
   opcodes to the checked handlers; richards throws nothing, the cost is
   in the loop head's `Ctl` handling, independent of inlining): open for
   the performance pass.

Updated 2026-11-10. Branch `worktree-agent-a8fb4ad99a9c8d319` (merged with
`sandbox-integration` at f95b9a1d). Design: DESIGN.md. Proofs:
OBLIGATIONS.md. Trusted base: TRUSTED.md.

## Done

- Format-2 snapshots load (method table decoded and checked per process
  group) and run on the Rust core; format 1 unchanged on the C++
  interpreter.
- Run loop owned by the core (`toit_v2_run`): preemption, yield, halt,
  task switch, stack growth, GC points, C++ primitives through the FFI.
- Raised failures carry the format-1 messages (negative tests match).
- Untrusted containers require format 2 by default
  (`-Xuntrusted_format1` / `TOIT_UNTRUSTED_FORMAT1=1` to allow format 1).
- tests/sandbox runs in format 2 and passes; untrusted suite (B2) passes
  for all comparable programs; format-1 suite green except the known
  environmental failures.
- GC bug fixed: the old stack is remembered before a growth replaces it.
- Performance pass 1 (obvious wins): inlined fast paths, one-comparison
  dispatch prologue, `cold!` trampolines keeping the machine in registers.
- Verus: the stack, local, constant, global and branch handlers have
  functional contracts (128 verified, 0 errors); `verified/check.sh`
  passes; the end-to-end obligation is stated (unproven).
- Layout check covers every constant the core assumes (237 + behavioral).
- Fuzz harness (verified/core/fuzz) with `toit_spec_verify` as filter and
  an ASan build (build/asan).

## In progress / next

1. Performance: the core executes 3.5-4.1x the instructions of the C++
   interpreter on the benchmarks and is 2.1-3.0x slower in wall time
   (DESIGN.md section 8). Next: keep `top`
   and `bci` in locals of the run loop (handlers take them by value and
   return them), cache `code`/`methods` table pointers in registers,
   specialize LOAD_FIELD_THIS (receiver checked at call time), and measure
   tail-call threading if the toolchain allows it. Decide whether trusted
   code moves to the core only after this.
2. Proofs: the refinement to `spec::step` (abstraction function, R1-R4),
   then the call, try/unwind and field families (OBLIGATIONS.md).
3. Done (branch vm/verifier-link): `check::verify` runs in the VM at every
   untrusted format-2 launch (verified/vmverify); the C++ loader only
   decodes the method headers.
4. Port the allowed primitives to Rust with `prim_heap_ok`.
5. Spec change request R1 (unwinding without a heap token): done
   (milestone 2 above).

## Known failures with the whole suite in format 2

(`TOIT_BYTECODE_FORMAT=2 ctest`, not an exit criterion any more)

- (fixed) channel-retention-test, services-resource-close-pressure-test
  failed because of the unwinding token of note 4 (R1); with the finally
  records both pass in format 2.
- profiler/basic-test, profiler/lambda-test: format 1's
  `SmallInteger.repeat` intrinsic makes `repeat` invisible in profiles;
  in format 2 it is ordinary bytecode and shows up.
- version, reader, udp-reuse-port-test: environmental, as in format 1.
- services-network-test fails intermittently (1 in 3 to 1 in 10 runs):
  `ServiceProvider.uninstall` iterates `_clients_` with `Set.do` while
  the close callbacks remove clients (OUT_OF_BOUNDS in `List_.[]`); a
  task interleaving format 1 does not hit with its preemption timing. A
  library race, not a core bug (not investigated further).

## Timing-sensitive sandbox test

tests/sandbox/flood-system-test expects the untrusted container to hit
the mailbox quota while flooding the system process with 200 KB messages.
On the core the sender is slower than the system process drains the
mailbox when the machine is idle, so no quota is hit and the test reports
"ATTACK SUCCEEDED" (it passed in the loaded B1 runs, fails 6 of 6 on an
idle machine at the end of the session). Not a safety problem (the quota
works when it is reached); the test needs a pacing-independent attack.

## Primitives (branch core/primitives, 2026-11-10)

The allowed primitives ported to verified Rust (src/prims; contract and
trusted base: TRUSTED.md section 8). Entry point `prims::call(module,
index, mem, at, n, heap, p, allocator, vs)` returns `PrimOutcome::
{Success, Failure, NeedsGc, NotPorted}`; its contract is the spec's
protocol: `prim_default` (`prim_heap_ok`, good encodable results, heap
invariant kept, no object moved), the per-primitive `core_contract`
(verified/spec/src/v2/prim_core.rs, definitions only) and `prim_refined`
(the spec's three examples), except one case of `array_at_put_spec`
where the spec's example decodes the arguments in another order than
C++ (`at_put_gap`: a program-heap array with a non-`int` index; the spec
example should be fixed). `NeedsGc` = an allocation did not fit (no GC
inside primitives); the caller collects and retries, and after the C++
protocol's retries completes with `PrimRet::OutOfMemory(ALLOCATION_FAILED)`.
`NotPorted` (heap unchanged) falls back to C++.

| Family | Ported (proven against prim_default) | With per-primitive functional contract |
|---|---|---|
| ints (prims/ints.rs) | 39: smi_* (16), large_integer_* (18), count_leading_zeros, popcount, object_class_id | all 39 (division/modulo and clz up to the result value) |
| arrays (prims/array.rs) | 8: array_length/at/at_put/new/expand/replace, list_add (small backing; large backing -> C++), rebuild_hash_index | array_length, array_at, array_at_put |
| blobs (prims/blob.rs) | 33: byte_array_is_raw_bytes/length/at/at_put/new/replace, string_length/at/raw_at/hash_code/compare/slice/add/rune_count/write_to_byte_array/from_rune, concat_strings, blob_equals/hash_code/index_of, 4 JSON helpers, 8 byte-order read/put, int_vector_equals | byte_array_at, byte_array_at_put, string_length |
| floats (prims/float.rs) | 26: arithmetic, comparisons, sign/is_nan/is_finite, sqrt/ceil/floor/trunc, raw conversions, number_to_float/integer, compare_to, min_special_compare_to | none (float ops are trusted scalars, prims/fp.rs) |
| total | 106 of the 154 allowed (152 core + 2 bitmap) | 45 |

Stays in C++ (48, contracts written down in TRUSTED.md section 8): task
and message plumbing, process_send, time/clock/random, finalizers,
encode_object/error, main/spawn arguments, SDK info, the formatting and
parsing primitives (int_parse, float_parse, *_to_string, float_round,
UTF-16, UTF-8 validation, crc), external byte arrays, bitmap blit/byte_zap.

Wiring (superseded by branch core/prims-integration, above): a temporary
opt-in hook (`TOIT_V2_RUST_PRIMITIVES=1`, prims/bridge.rs) at the checked
PRIMITIVE handler; the measurements below are of that bridge.

Results (final build):

- Gate: `verified/check.sh --tests` passes (core 713 verified, spec 793;
  audit passed). Full `ctest -j16`: only version, reader,
  udp-reuse-port-test fail.
- Differential test (verified/core/tests/prim_diff.sh with
  tests/fuzz/primitive-diff.toit: random and typed arguments, checksums of
  results, errors and mutated arguments): 10 seeds x 1,000,000 calls of
  the 106 ported primitives, identical with C++ and Rust. It found two
  C++ issues, fixed on this branch: `smi_subtract` overflow (upstream PR
  toitlang/toit#3375) and `string_write_to_byte_array`'s overlapping
  `memcpy` (toitlang/toit#3376); and one compiler-dependent NaN payload
  (gcc commutes `+`/`*`), matched in prims/fp.rs.
- With the Rust primitives: tests/sandbox 93/93; untrusted suite 280/282
  identical (the two known differences, program-name-test and
  set-map-remove-first-test, as without).
- Benchmarks (verified/core/tests/prim_bench.sh; callgrind instructions
  inside `toit_v2_run`, C++ bridge vs Rust; raw numbers in
  /home/flo/work/opentoit-sandbox-artifacts/core-primitives/bench-2.txt):
  map-string-keys 1.005, string-concat-slice 0.960, list-add 1.080
  (large-array lists fall back after a Rust attempt), byte-array 1.000,
  large-int 1.011, float 1.013, string-compare-hash 1.005, direct calls
  (100k each) smi_add 1.009, string_length 0.977, array_at 0.999,
  float_add 1.024, blob_equals 1.014; richards/pystone/deltablue 1.000.
  Wall time (best of 5, loaded machine) within noise. Per call the Rust
  primitive (about 150-200 instructions with the bridge) costs about the
  same as `toit_v2_call_primitive` plus the C++ primitive (about 210);
  both pay the C++ lookup (about 45) and the checked handler's
  save/move/reload (about 250). A direct call from the verified handler,
  with the policy check as a table lookup instead of
  `toit_v2_lookup_primitive` and no reload on the Rust path (no GC
  point), would save about 300 instructions per call.

## Fuzz findings (verified/core/fuzz)

Filter: `toit_spec_verify` (verified `check::verify`, untrusted rules).
Runs on the ASan build, 11 seed programs, single-byte opcode and operand
mutations.

| Run | Seed | Mutants | Accepted and run | Crash | Stuck | Refused by loader |
|---|---|---|---|---|---|---|
| 1 (10 min) | 1 | 14,537 | 2,042 | 0 | 1 | 14 |
| 2 (10 min) | 1 | 6,266 | 867 | 0 | 0 | 8 |
| 4 (8 min, after the task-field fix) | 2 | 8,787 | 1,220 | 1 | 1 | 8 |

- Stuck (run 1 index 6388, run 4 index 1728): the mutant overwrites field
  0 of a task (the task's Stack, owned by the VM). Before the fix the
  scheduler could use an arbitrary value as a stack (a real hole); now the
  core refuses the access (stuck state 8, process terminated). Spec change
  request R5.
- Crash (run 4 index 786): a NULL dereference in the C++ primitive
  `task_receive_message` when called without a pending message (the
  library never does that, a program can). Fixed in src/primitive_core.cc
  (returns null); the bug exists in format 1 too and should go upstream.
- Refused: accepted mutants the VM's loader refuses (branch targets of
  unreachable instructions; the verifier checks reachable code only).
  Harmless; the loader and the verifier should agree once
  `check::verify` runs in the VM.
- Run 3 (index range 6266.. of seed 1) aborted when build/host was
  rebuilt under it.
