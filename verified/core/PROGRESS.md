# Phase 4a progress (verified core, format 2 on x86-64)

## Format 3, step 3: TRY as a flagged block call (branch format3/try, 2026-11-26)

TRY calls the try block with the handler flag in its frame record (the
fourth word: 1 for a try block, 0 otherwise); a try block's return, and
an unwinding that pops it, continue in the caller's finally code with
four slots: the value, two token words, the reason. The tokens hold the
pending unwinding (normal, throw, return to a frame, branch to a frame,
bci and height); UNWIND resumes it. No finally records, no record moves,
no gate for them (verified/spec/format/23-format3-try.md). Image tag
`TBC3`; images with another `TBC` digit are refused where programs start.

Resource failures at TRY (requirement after the quota livelock): a TRY
whose try block cannot get its stack room now enters the try block first
and raises the stack-overflow or out-of-memory error there, so the TRY's
finally code runs, as in format 1 (spec `prim::resource_state`, lemma
`sound_resource::lemma_try_resource_finally`; core `unwind::try_grow`,
checked loop `try_grow_cold`). The machine path's room check of TRY now
counts the block reference (it did not, so near the stack's limit a TRY
could enter a try block without its room and the next room scan ended
the process with `LIMIT`). tests/sandbox/try-finally-resource-test.toit
runs the naive `flag = true; try: ... finally: flag = false` at every
depth and word offset around the overflow and with the heap at the
quota, on host and host32; it fails on the base (the flag leaks) and on
the first version of this step (`LIMIT`).

Proofs: spec 1081, core 1063, core-split 1065 (32-bit 1081, 1065, 1067)
verified, 0 errors (base ceadf1bdf: 1096, 1103, 1105; 32-bit 1096, 1105,
1107). Theorem statements unchanged in text or stronger (THEOREMS.txt:
`lemma_replace_frame_slots` lost `!has_handler(s)`, `x_throw_null` lost
the finally-record bound; new: `lemma_try_resource_finally`); the
theorem's set of resource throws changed at TRY only (they start in the
try block). Deleted finally-record machinery: rfins.rs
(367 lines), `fins_rel`, `cut_records`, `pop_records`, the record moves
in view.rs and calls.rs, the spec's `fin_ok`, `try_ok`, `fins_ok`,
`cut_fins`, `fins_popped`, `fin_matches`; diff of verified/spec/src
+848 / -1,447 lines, verified/core/src +1,246 / -3,028. No new trusted
item, no new external_body; trusted texts changed: `StackMem::from_stack`
(frame-top header word), `Runtime::grow_stack` (frame records copied),
the checked loop's exception for the provenance of block references and
tokens (TRUSTED.md section 4).

Against the base (memory and device library: ceadf1bdf, where this branch
starts; host instructions and firmware: 746bf39b0, wip/collector-proofs
after the merge into this branch, which measures the same as ceadf1bdf on
the host; artifacts format3-try):

| | base | step 3 | |
|---|---:|---:|---:|
| words needed at the deepest call: short / latch / longest task (H 18) | 121 / 130 / 133 | 116 / 126 / 129 | -4 |
| `V2_INITIAL_LENGTH_ABOVE_HEIGHT` | 118 | 114 | |
| bytes allocated: empty / sum / string task | 1,320 / 1,352 / 1,488 | 1,288 / 1,320 / 1,456 | -2.4 % |
| soak worker: tasks part / whole iteration | 4,496 / 9,951 | 4,400 / 9,698 | -2.1 % / -2.5 % |
| host Ir per try/finally, normal completion (net of the loop) | 299 | 293 | -2 % |
| host Ir per `return` through a finally (net) | 412 | 341 | -17 % |
| host Ir per throw and catch (net) | 15,115 | 13,288 | -12 % |
| host Ir per two nested try/finally (net) | 573 | 559 | -2 % |
| host Ir per `break` out of a block through a finally (net) | 626 | 553 | -12 % |
| host Ir: richards / deltablue / pystone / json | 105.21 M / 7.264 M / 17.30 M / 21.11 M | 106.89 M / 7.422 M / 17.62 M / 21.41 M | +1.6 / +2.2 / +1.8 / +1.4 % |
| host Ir: calls / tasks / yield / RPC | 64.61 M / 25,980 / 946 / 79,978 | 65.80 M / 26,239 / 965 / 79,322 | +1.9 / +1.0 / +2.0 / -0.8 % |
| classic ESP32: run loop / `.iram0.text` / IRAM free | 20,211 / 129,351 / 694 | 19,967 / 128,375 / 1,670 | -244 / -976 / +976 B |
| classic ESP32 toit.bin | 1,423,424 | 1,421,728 | -1,696 B |
| ESP32-C6: run loop / `.iram0.text` / toit.bin | 19,284 / 173,956 / 1,559,776 | 19,024 / 172,102 / 1,557,680 | -260 / -1,854 / -2,096 B |
| device library (opt s): riscv32 / thumbv7m | 73,684 / 65,730 | 72,144 / 63,980 | -1,540 / -1,750 B |
| bytecodes (seven programs) | | | +12 to +14 B each |

Try paths (progs/trybench.toit, 10,000 operations per iteration, minus
the same loop calling an empty method): the mechanism is cheaper as
designed where an unwinding runs (non-local return, break, throw: no
finally record written, checked and moved), about even for a normal
completion (TRY was a block call before too; the finally code now gets
four slots instead of three). A first build was slower on every try path
(normal +39 Ir): `enter_fin_r` had been made out of line for size, which
made the return into finally code a call with the registers in memory
(40 Ir instead of 13); inlining it again (as before) gave the numbers
above and recovered tasks (+2.5 % -> +1.0 %) and RPC.

Programs without try/finally: +1.4 to +2.2 % host instructions, a
register-allocation effect of LLVM on x86-64, not new work. The LLVM IR
of the run loop has the same loop-carried values in both (5 pointer phis
at the dispatch: sp, fp, frame-record top, end, ip), the same frame size
(0x228, six callee-saved registers) and a near-identical number of blocks
and calls; the call and return fast paths are the same in the source.
The difference is which register holds the object-stack top: the base
keeps it in rbp, step 3 in r8, which the handlers also use for
temporaries, so INVOKE_STATIC's fast path ends with five register moves
instead of one and ADD with one more (instruction-level callgrind of
`calls`: +6 moves, +2 stack accesses, -2 other instructions per
iteration; the `base` loop of trybench +6 Ir). Remedies tried, none
recovers the base: the try helpers `#[cold]` (no change), padding the
`Machine` struct to its old size (no change), the base's read order in
RETURN (no change), UNWIND out of line (+65 %: the registers go to
memory), TRY and the return into finally code inlined into the loop
(+20 %), codegen-units = 1 (+2.7 % on calls). On the devices the run
loop got smaller on both targets with the same dispatch sequence (Xtensa:
l32ui, addx4, l32i.n, jx; RISC-V: lbu, slli, add, lw, jr; 171 and 152
dispatch sites), the same frames (Xtensa `entry a1, 0x170`, RISC-V 336
bytes) and equal or fewer stack accesses (Xtensa 1,124 / 213 loads /
stores vs 1,125 / 234; RISC-V 680 / 150 vs 685 / 146); on Xtensa 35 of
the dispatch sites are preceded by a register move (base 18).
Instruction counts there need the hardware.

## Format 3, step 2: four-word frame records (branch format3/branches-frames, 2026-11-26)

Frame records are method, return bci, base and the handler word (0, or
the TRY's height): the handler's bci, the fifth word, is gone; it is the
return bci of the try block's record above (`calls::callees_ok`, from
`sound::try_ok`), which a return from the try block and the unwinding
loops (the return bci of the frame popped last) supply
(verified/spec/format/22-format3-branches-frames.md). The spec is
unchanged. `shape_ok` is now `shape0` (with `callees_ok`) plus "the top
frame has no handler"; the unwinding loops keep `shape0`. Finally records
keep five words; the trusted stack reload had assumed the two sizes equal
(fixed). A task's initial stack is H + 118 words (was H + 132), re-derived
with memory-pressure's exact-growth measurement: the short tasks need 121,
130 and 133 words at H 18 (were 135, 144, 147).

Against the merge with wip/collector-proofs (b454ec452; the Xtensa
toolchain switch and the SDK's yield change came with it, so step 2 is
compared with that, not with the base of step 1):

| | step 1 (b454ec452) | step 2 | |
|---|---:|---:|---:|
| bytes allocated: empty / sum / string / latch task | 1,438 / 1,464 / 1,600 / 1,512 | 1,320 / 1,352 / 1,488 / 1,400 | -8 % |
| soak worker: tasks part / whole iteration | 4,832 / 10,336 | 4,496 / 10,022 | -7 % / -3.0 % |
| RPC echo / add part | 2,547 / 360 | 2,418 / 336 | -5 % / -7 % |
| host Ir: richards / deltablue / pystone / json | 105.13 M / 7.268 M / 17.23 M / 21.13 M | 105.13 M / 7.272 M / 17.24 M / 21.14 M | 0.0 / +0.05 / +0.03 / +0.08 % |
| host Ir: calls / tasks / yield / RPC | 64.61 M / 25,955 / 945 / 95,281 | 64.61 M / 25,948 / 950 / 95,660 | 0.0 / 0.0 / +0.5 / +0.4 % |
| classic ESP32: run loop / `.iram0.text` / IRAM free | 20,221 / 129,327 / 718 | 20,218 / 129,251 / 794 | -3 / -76 / +76 B |
| classic ESP32 toit.bin | 1,461,056 | 1,460,896 | -160 B |
| device library (opt s): riscv32 / thumbv7m | 73,926 / 64,930 | 73,750 / 64,792 | -176 / -138 B |
| bytecodes | unchanged | unchanged | |

No run-time gain: a call already wrote four words (the handler bci only by
TRY), so step 2 saves a store per TRY and a load per return into finally
code, below the noise of the host counts. The gain is memory: a word per
frame, 14 words for a short task at its deepest call.

Proofs: spec 1096, core 1093, core-split 1095 (32-bit 1096, 1095, 1097)
verified, 0 errors; no new trusted item, THEOREMS.txt unchanged.
C++ matrix: the fast tier passes (after fixing v2_frame_walk, which wrote a
record at the literal offset `5 * record + 1`, and v2_table_install, which
stated the verdict rule from before the policy binding of
wip/collector-proofs); byte-array-initialization/LP64 timed out at 600 s in
every run on the loaded machine (also before step 2). The slow-tier task
jobs pass (task-all-fields, task-retry-fields, allocate-task, task-transfer,
gc-current-task).

## Format 3, step 1: short branches (branch format3/branches-frames, 2026-11-26)

Five two-byte branch opcodes, BRANCH_S .. BRANCH_IF_NOT_NULL_S (114..117)
and BRANCH_BACK_S (118), chosen by the compiler's branch relaxation
(verified/spec/format/22-format3-branches-frames.md). Merged with
wip/collector-proofs 25a01a7de, which contains verifier/single-pass (the single-pass checker `v2::walk` learned the short
forms: its branch obligations, the forward distance check and the scan for
backward targets). Measurements: /home/flo/work/opentoit-sandbox-artifacts/format3-impl.

Bytecodes (host compiler, `bytecodes` of the program dump):

| program | base | step 1 | |
|---|---:|---:|---:|
| esp32-system (classic ESP32 system image) | 69,020 | 66,932 | -3.0 % |
| a-hello / c-map / g-big (untrusted) | 26,949 / 32,622 / 38,223 | 26,075 / 31,686 / 36,955 | -3.2 / -2.9 / -3.3 % |
| opbench / taskbench / cgbench (trusted) | 42,049 / 32,524 / 40,829 | 40,698 / 31,490 / 39,470 | -3.2 / -3.2 / -3.3 % |

Host instructions (callgrind, trusted, per iteration): richards -1.7 %,
deltablue -1.2 %, pystone -0.9 %, json -0.9 %, calls 0.0 %, tasks -1.4 %,
yield -1.3 %, RPC -1.0 % (one byte fewer to fetch per taken branch and a
smaller code footprint; logs/cgrun-base.txt, cgrun-stepA.txt).

Classic ESP32 firmware (f2, hardware-free build): the run loop 19,446 ->
19,658 bytes (+212 for the five handlers, all in the hot part of both
loop configurations), `.iram0.text` 128,323 -> 128,535, IRAM free 1,722 ->
1,510 bytes; toit.bin 1,463,792 -> 1,464,352. Device library (Rust, opt
s, LTO): riscv32 76,328 -> 74,984 bytes, thumbv7m 67,906 -> 68,136 (the
per-component split moves with LTO's inlining; the totals are the
comparable number).

Proofs (after the merge with wip/collector-proofs 25a01a7de): spec 1096, core 1093, core-split 1095
(32-bit: 1096, 1095, 1097) verified, 0 errors; before the merge 1087, 1092, 1094; no new trusted item, no
theorem statement changed.

## Primitive trust round (branch prims/trust-round, 2026-11-26)

Base 25a01a7de (wip/collector-proofs). Roadmap items 4, 5, 6 of
docs/sandbox-guarantee.md.

- Item 4, read-only objects: `sound::prim_heap_ok` keeps every read-only
  object (`h[i].ro ==> h2[i] == h[i]`) and every `ro` flag. The 106 Rust
  ports are proved against it: the heap-update lemmas of `prims`
  (`lemma_post_update`, `lemma_post_content`, `array::lemma_post_set_*`)
  require a mutable object, and `view::content_ok` says a writable
  content view is of a mutable object (every caller already knew it). For
  the C++ primitives it is part of the assumed contract
  (`gc_call_primitive`, TRUSTED.toml's justification names it); the
  evidence per primitive is docs/sandbox-guarantee.md section 2.4. The
  VeriFast renderings model program-heap membership (`in_program_heap`;
  the writers' destinations come from the proved `mutable_byte_content`,
  `byte_array_at_put` asserts it at the write) but abstract byte contents
  (`uchars(.., _)`) and own program-heap objects like any other, so no C++
  proof can state the clause as a postcondition without a model change.
  Hardening tests: tests/sandbox/cli/program-heap-write-main.toit (every
  writer aimed at program-heap bytes, a copy-on-write wrapper claiming to
  be mutable over them, string literals: refused, unchanged; the C++
  copy-on-write path writes a fresh copy). Spec and core counts unchanged
  (spec 1090, core 1092/1094, core-split 1094/1096 at 64/32 bits);
  THEOREMS.txt unchanged; new epoch (spec crate and view.rs).
- Item 5, how a run stops: `step::run_loop` returns a ghost third result
  `RunEnd` (`Exit`: an exit of a step; `Stuck(reason)`: the reason of the
  run's one stuck report, all made by `leave_stuck`), and `run_post` now
  says that a stuck report is `stuck::LIMIT` or, before the first
  instruction, `stuck::FATAL` for a program-heap range that wraps
  (`stop_ok`), with the result `(RESULT_TERMINATED, 1)`. The states part
  is `run_states`, which `theorem_next_run` and `process::scheduled` use
  (unchanged in meaning). `machine::run` drops the ghost result. What
  remains: the wrap check itself (a run stops with FATAL if the program
  heap's range wraps the address space, which the C++ allocation of an
  image never gives). No new trusted item; theorem.rs is an epoch input.
- Item 6, fallbacks: `prims::never_falls_back` 35 -> 40 ports. list_add
  handles a large-array backing in Rust (`array::large_slot`: the arraylet
  of element n through at most 8 nested vectors, as the C++
  `Interpreter::fast_at` but bounded; else INVALID_ARGUMENT, which the
  Toit code handles by growing the list). The C++ recursed once per large
  array of a chain of decreasing sizes: a program's own core library can
  make a chain of 10^6 (final fields are assignable in bytecode), and
  list_add on it crashed the VM (native stack overflow; reproduced on the
  host, segmentation fault; regression test
  tests/sandbox/cli/large-array-chain-main.toit, compiled against a
  patched copy of the library by run-patched-lib.cmake). The C++
  `fast_at` keeps the unbounded recursion for format-1 programs and the
  C++ interpreter (trusted only). byte_array_is_raw_bytes,
  byte_array_length, byte_array_at and byte_array_at_put read an opaque
  byte array through its tag and length words (`Heap::opaque_tag_len`, a
  verified accessor of view.rs) as the C++ does: a neutered array (raw,
  null address, length 0) and a resource proxy give the C++ results
  (tests/sandbox/cli/opaque-byte-array-main.toit, identical output with
  the binary before); where the C++ would read bytes the model does not
  have (a mapped file, which nothing makes, or a raw array with a null
  address and a non-zero length) the port fails with WRONG_OBJECT_TYPE.
  The blob decoding of the ports (`blob::blob_arg`) fails for an opaque
  byte array that is not raw bytes, as the C++ decoders do, so the blob
  primitives fall back for opaque arguments only on a neutered array.
  contract_check: the C++ behind the 106 ports 62 VeriFast-proved, 37
  unreachable, 7 contract-only (was 62/34/10). Retry rules unchanged
  (77 proved, 62 textual, 9 tested, 2 reviewed). Core 1092 -> 1098
  (64-bit).
- Item 6, second step: `never_falls_back` 40 -> 45. A byte array a
  transferring send neutered (raw bytes of length 0 at a null address)
  and the empty slices of one decode to `BlobArg::Empty`, the empty blob
  the C++ decoders give (non-mutable modes; a raw one with a null address
  and a non-zero length, which nothing makes, fails); blob_equals,
  blob_index_of, compare_simple_json_string, size_of_json_number and
  string_rune_count handle it (`blob_or_empty`) and fail with
  OUT_OF_RANGE for a count above MAX_SMI (no blob is that long; the C++
  made it a smi unchecked). Same results as the C++ for the neutered array
  and a proxy (tests/sandbox/cli/opaque-byte-array-main.toit, output
  identical with the binary before this branch). contract_check: 62
  VeriFast-proved, 42 unreachable, 2 contract-only (number_to_integer,
  smi_multiply: after an allocation that did not fit, the C++ primitive
  runs; VeriFast floating point and `__builtin_mul_overflow` block their
  proofs).

## Memory pressure on the classic ESP32 (branch device/memory-pressure, 2026-11-25)

Base 67e28c2d (wip/collector-proofs). Artifacts:
/home/flo/work/opentoit-sandbox-artifacts/memory-pressure (README.md).

- Task stacks: a format-2 task starts with the program's maximal height
  plus 132 words (at most 256; format 1 keeps 64), measured from the
  libraries' short tasks (they need 104-147 words at a maximal height of
  18; with 64 words every task grew twice, 64 -> 96 -> 144). Classic
  ESP32, soak worker: 9.6-10.0 KB allocated per iteration -> 6.8-7.2 KB
  (format 1: 6.9 KB), minor GCs per iteration 3.3-3.5 -> 2.5-2.65 (f1
  2.50). Speed within the layout noise (richards, deltablue, pystone,
  tasks-1k, yield 1.00; json-decode +6 %, strings -4 %). No core or spec
  constant changed (the core checks room after every task switch).
- Verifier memory: the per-method maps in chunks of at most 1 KB
  (`toit_spec::cvec::CVec`, built by the decoder in a `CBuild`; verified
  on the `xvec` accessors, no new trusted code); largest request of c-map
  7,424 -> 3,960 B, no request of 4 KB or more for a-hello and c-map
  (g-big: its method-table literal's copy, 4,216 B); x86-64 instructions
  per verification within 3 % of the base, fewer allocations. Before an
  install-time verification on a device with under 48 KB free or a 16 KB
  largest block, the commit primitive collects every process's garbage
  first; the system's image writer retries a commit that ran out of
  memory three times. In the traced soak every remaining failure was a
  request of at most 1 KB with under 1 KB free: exhaustion by the other
  containers' heaps during the verification, not fragmentation.
  Verus: spec 1,066 -> 1,081 (the new module), core and core-split
  unchanged, both widths; audit and THEOREMS.txt unchanged.
- Device verification wall time: bisected on the device (time-only
  builds, three layouts each) to the chunked maps (34896a5a: a-hello
  0.82 -> 1.15 s; the garbage collection first, the retry and the trace
  add nothing). Not more work (x86-64 instructions +3 %, device
  allocations +2.5 %) but flash-cache conflicts: the verifier calls the
  allocator about 8 times per method, a malloc costs 28-33 us (its
  functions miss in the cache), and the new code moved the verifier's hot
  functions onto the allocator's cache sets (the same commit with the
  verifier group shifted by 8 KB: 0.84 s). Fix: the verifier's 44 hottest
  functions (9 KB) first in the pinned group B, right after the
  allocator's functions at the end of group A (hot_flash_functions.txt).
  a-hello / c-map / g-big: 0.84 / 1.08 / 1.17 s (base 0.86 / 1.04 /
  1.24); unpinned code shifted by 2400 / 6272 B: 0.77 / 0.86 / 1.00 and
  0.70 / 0.89 / 1.00 (base 0.83 / 1.14 / 1.27, 0.81 / 1.05 / 1.16). The
  layout still dominates: with all pinned code shifted by 1536 / 6272 B
  the base takes 0.53-0.57 s and the fix 0.88-0.89 s (a second layout
  factor, not the allocator overlap, which is the same as at the
  default; open).
- Soaks: f2 one worker 2 h: no reset, crash or stuck worker, installs
  42/16 (all out of memory); f2 two workers (does not fit with WiFi,
  free down to 3 KB): installs 23/37, one worker stuck (the RPC liveness
  item of esp32-final), one restart by the scheduler's dead-lock check
  (system process stalled 10 s in a WiFi connect); f1 1 h: one
  system-process OOM restart.
- The slow-tier ESBMC job `task-all-fields` failed (invalid-pointer
  sentinel write) once the stack length depended on the program: the bit
  mask of `_align` in `Stack::allocation_size` hid from ESBMC that the
  address stays in its chunk (reproduced in a 50-line model with ESBMC
  8.6.0: in-bounds assertion passes, invalid-pointer check fails; both
  pass without the mask or with a constant length). The rounding was the
  identity (HEADER_SIZE is whole words, now asserted) and is gone; the job
  passes on both widths, and mutants (format 1's length for a format-2
  task, one slot not cleared) still fail.

## Service calls and task switching, third round (branch core/rpc-task-speed-3, 2026-11-25)

Base 5496da57 (wip/collector-proofs). Artifacts:
/home/flo/work/opentoit-sandbox-artifacts/rpc-task-speed-3 (README.md).

C6, f2/f1 over three sessions (code head ae2058ba): rpc-200 1.04,
rpc-echo-50 1.06, yield-2k 1.27 -> 1.17, tasks-1k 1.01 -> 0.95;
richards 0.90, deltablue 1.00, pystone 0.95, json 1.09-1.10. Two
layout-shifted builds: rpc 1.01 / 1.02, yield 1.17 / 1.17, tasks 0.95 /
0.95.

- `toit_v2_primitive` completes a plain failure inline (C++, the
  rendering for VeriFast updated, `run.sh --quick ffi` passes, contracts
  unchanged): yield -2 %.
- The C++ primitive call inline in the run loop with the registers
  derived again from the Stack header afterwards (`cxx_call`,
  `regs_reloaded`, `complete_r` shared with the Rust ports;
  `cxx_primitive_v` gone): yield-2k 26.1 -> 24.0 ms with the previous
  change, tasks-1k -1.7 %, run loop -324 B on RISC-V; richards +1.4 %
  (the null word spilled). Variants that kept the registers across the
  call cost +1-2 % on calls and returns (README).
- The room after a task switch in constant time from a per-run arity
  bound (`room::Abound`, `compute_abound`, `room_by_bound`,
  `room_after_switch`): tasks-1k 273.2 -> 261.4 ms. The save-side
  alternative needs the suspended stack's length, which the GC changes:
  not without a trusted word.
- SDK finding (not on the branch, sdk-yield-self.patch): `yield` without
  the transfer to the running task (a no-op primitive): yield-2k f1 20.4
  -> 15.4, f2 24.0 -> 17.3 ms (1.12).

Verus: core 1,089 / 1,091 verified (64 / 32 bit), core-split 1,091 /
1,093, 0 errors; spec unchanged (1,066); audit passed; THEOREMS.txt:
`Program::arity_of` no longer an unused entry point; nostd, nopanic
(riscv32, thumbv7m), thumb codegen ok; no epoch input changed; sandbox
ctests 135/135; host ctest 1234/1236 (udp-reuse-port; tls2-test timed
out once and passed on rerun).

## Ports that never fall back (branch core/ports-never-fall-back, 2026-11-24)

Base d52be39e (sandbox-integration). The wave-9 audit's list of ports
that never return NotPorted or NeedsGc (verified/cxx/annotated/README.md,
"When the C++ behind a port runs") checked against the code: right as it
was, 35 (16 integer, 5 array, 4 blob, 10 float); no port off the list
cannot fall back on both word widths (`float_to_raw32` cannot on 64-bit
only). Now proved: `prims::never_falls_back` (the list, prims/mod.rs),
`prims::call` and the family dispatches ensure `completes` for it,
`rarrays::rust_primitive_r` (now holding the policy gate) returns Some
for it, and its `arity` is the verifier's `cert.prim_arity` entry (spec:
`lemma_prim_facts` states the PRIMITIVE's arity check). What the arity
rests on, and what dropping the C++ from format-2-only firmware needs:
OBLIGATIONS.md, "Ports that never fall back". CONTRACTS.toml
`[unreachable]` repeats the list for the C++ bookkeeping; contract_check
checks it against the Verus list and counts the C++ behind the 106 ports:
17 VeriFast-proved, 34 unreachable (smi_mod is both), 55 contract-only.
No port extended, no device code changed but the gate's move into the
inlined `rust_primitive_r`.
## Flash layout on the classic ESP32 (branch device/esp32-layout, 2026-11-24)

Base ea78a719. Measurements and scripts:
/home/flo/work/opentoit-sandbox-artifacts/esp32-layout/README.md.

- Mechanism. The classic ESP32's flash cache is 32 KB per CPU, two-way
  set-associative, 32-byte lines (TRM 3.3.4), in front of code, literals,
  rodata and the program images alike; addresses equal modulo 16 KB
  compete. New measurement option `TOIT_HW_PERF_STALL_SAMPLES`: the
  performance monitor interrupts every 1,021 flash-busy stall cycles (or
  12,007 cycles) and records the latched PC. The same code, data and work
  fits the cache in one layout and misses in another (yield-2k: 0.3 M vs
  11 M stall cycles per run; 47 % of the misses in one set holding
  `Locker::enter` and FreeRTOS `xQueueSemaphoreTake` plus a data line):
  conflict misses. The PAD method moves code against data only;
  real changes also move code against code.
- `TOIT_PIN_HOT_FLASH_CODE` (default y on the classic ESP32): an output
  section inserted before `.flash.text` (at 0x400d0020) holds the functions
  of toolchains/idf/components/toit/hot_flash_functions.txt in order, each
  with its literals: group A, the run time's flash code, first 6 KB with
  the most fetch misses per byte, then the largest time share per byte, 14
  KB of code per bytecode format (one cache way); group B, the whole
  verifier (toit_vmverify + toit_spec, 31 KB). The generated script goes
  right before ESP-IDF's sections.ld on the link line (`toit_postprocess`);
  no ESP-IDF change. Tried and dropped: lists from misses only (they split
  the Rust library and the verifier: new variation), from time share only
  (lost the yield pair), the verifier aligned to 16 KB (no steadier).
- `TOIT_VERIFIED_CORE_IRAM_FUNCTIONS` (classic ESP32) redone from cycle
  samples with the flash code pinned: `step::slow`/`slow_body` (4.4 KB,
  0.02 % of the time) out; ret_try_v, large_loc, probe_x, hf_at_x,
  reload_cold, unwind_resume_v, cxx_primitive_rest, blob_arg and the
  string/number helpers in; about 1.7 KB of IRAM free (TOIT_HW_PERF builds
  need 0.9 KB).
- Results (four builds with the code shifted by 0-11 KB, mean, spread
  before -> after): format 2 rpc-200 681 (15 %) -> 460 ms (15 %), tasks-1k
  396 (28 %) -> 244 (0.2 %), yield-2k 31.5 (75 %) -> 25.1 (0.2 %), tison-2k
  78 (49 %) -> 61 (1.6 %), interp-1k 15.8 (78 %) -> 11.5 (1.2 %), json
  (hwbench) 369 (18 %) -> 256 (2.5 %), map-set 174 (26 %) -> 132 (0.6 %);
  strings still 14-18 %. f2/f1 rpc-200 1.12 (measure-3 1.38), yield 1.05
  (1.18). Format 1 with its own list: most spreads drop too (yield 79 ->
  1 %, interp 87 -> 2 %), tasks-1k, json-encode, set-str and tison still
  swing. Verification (25 KB program) 0.78-0.86 s (0.84-1.05 before);
  device suite unchanged. With the rodata and the program images shifted
  instead (code fixed) format 2 stays steadier than before except
  tasks-1k (38 %).
- Not changed: the C6/S3 defaults (pinning off, their IRAM lists), the
  core's Rust code (no proof or trust change), the ESP-IDF submodule.

## The collector in the model, stage 0 (branch gc/stage0-spec, 2026-11-24)

Base c5ee1c2c (wip/collector-proofs). Plan and pilot:
/home/flo/work/opentoit-sandbox-artifacts/gc-proof-pilot/README.md.

- Spec (verified/spec/src/v2/gc.rs): `collection`, what a collection may
  do: weak processing (maps reset, values of maps' backings nulled, as
  `weak_processing` does, over-approximated), then a compaction (a closed
  live set with the roots survives, renumbered `0..n`, references renamed;
  program heap and constants keep their ids). `gc_steps`: any number.
  Proven: collections keep `wf` and the unwinding invariant of a raise;
  an allocation commutes with them; PRIMITIVE and double operators are
  the same step after them. `prim::raised` gained a completion that
  collects first (`raised_gc`, opaque).
- Core: the five GC leaf contracts promise collections
  (`alloc::gc_alloc_post`, `step::grow_post`, exception, primitive; none
  when the epoch is unchanged) instead of the same state; `advances`
  allows collections around a step (`gc_around`); every GC point
  re-proved (ALLOCATE and doubles: step, then collections; growth:
  collections first; C++ primitives: collections, then a completion of the
  collected state, via a ghost source machine, `step::src_ok`; raises:
  `raised_gc`; `regain`/`ensure_room_all` return a collected state).
  `refines` is unchanged (renumbering, not a partial refinement:
  OBLIGATIONS.md "The collector").
- Bridge (verified/core/src/gcbridge.rs, proof only): the pilot's
  `collected` for the core's model, after weak processing, is a
  `collection` represented by the core's heap model at the collector's
  addresses.
- Theorems: same text; `reaches` includes collections, `resumed` assumes
  collections (weaker), spec `raised` has one more completion. The
  conclusion `reaches(s0, m.g)` is weaker than before (a state reached by
  spec steps and collections); the old one rested on contracts no
  collector that frees memory or processes weak maps meets. For the
  lead's decision before a merge.
- C++ side: the `gc_equiv` family's wording (CONTRACTS.toml, annotated
  README): gc_equiv is gc_steps; no VeriFast change.

Verus: spec 1,066 (64 and 32 bit), core 1,072 / 1,074 verified (64 / 32
bit), core-split 1,074 / 1,076, 0 errors (base: spec 1,025, core 1,056 /
1,058, core-split 1,058 / 1,060). Trusted items: the same five GC leaf
contracts, restated (no new item); audit, contract table, layout table
and no-Python check pass; THEOREMS.txt: the two core theorems' text
unchanged, eight new top-level proof fns (`gcbridge::lemma_collected`;
the spec's `gc_steps` lemmas the core uses). VeriFast `run.sh --quick ffi`
(LP64, ILP32) passes. Not run: the sandbox ctests (no host build in the
worktree), the rest of the C++ matrix, the slow tier.

## Service calls and task switching, second round (branch core/rpc-task-speed-2, 2026-11-24)

Base fd95ac85 (wip/collector-proofs). Artifacts:
/home/flo/work/opentoit-sandbox-artifacts/rpc-task-speed-2 (README.md).

C6, f2/f1 over three sessions (head 0e0ad162): rpc-200 1.12, rpc-echo-50
1.12, yield-2k 1.21, tasks-1k 1.18 -> 1.16; richards 0.90, deltablue
1.01, pystone 0.96, json 1.10-1.11. Two layout-shifted builds: rpc
1.12 / 1.04, yield 1.21 / 1.20, tasks 1.16 / 1.16.

- Core: `room::ensure_room_all` without the per-frame bound check (the
  bases are at most the stack's height, `lemma_bases_below`): 13 -> 10
  x86 instructions per frame, tasks-1k -1.3 %, -24 B.
- Attribution of the finally-code slow path (48 calls and returns per
  ping-pong): value-returning `monitor` methods return through
  `locked_`'s try/finally (the compiler's monitor block). An SDK change
  (compiler + lib/core, artifacts sdk-monitor-nlr-v3.patch, not on the
  branch) brings f2 tasks-1k to 278 ms against f1's 274 ms with the same
  change (301 ms without), host ping-pong f2 36.7 K -> 27.1 K, f1 24.6 K
  -> 21.9 K.
- Not done, with the proved designs written up (OBLIGATIONS.md, status
  of S2-S6): no room scan at task switches (a per-run arity bound threaded
  with the Env, or a spec lemma that steps keep suspended stacks), S3's
  records layout, S5; the C++ side of the primitive round trip is
  rendered for the C++ proofs.

Verus: core 1,056 / 1,058 verified (64 / 32 bit), core-split 1,058 /
1,060, 0 errors; spec unchanged (1,025); audit passed, THEOREMS.txt
unchanged; nostd, nopanic (riscv32, thumbv7m), thumb codegen ok; sandbox
ctests 126/126; host ctest 1217/1220 (version, reader, udp-reuse-port).

## Service calls and task switching (branch core/rpc-task-speed, 2026-11-24)

Base 9d79d677 (core/split-option). Artifacts:
/home/flo/work/opentoit-sandbox-artifacts/rpc-task-speed (README.md:
attribution, scripts, logs, tables).

Attribution. Host instruction counts (callgrind, the same task and RPC
benchmarks) of 9d618634 (the 11-12 November f2) and the base are equal
(per RPC 95.9 K vs 95.2 K, per ping-pong 40.4 K vs 40.3 K): none of the
ten days of C++ changes costs instructions there. The C6's rpc-200
regression (373 -> 420 ms) is flash layout: measure-2's unsplit firmware
(378 ms) and the base (424 ms) run the same code, and moving FreeRTOS to
IRAM or shifting all flash code changes rpc-200 by 7-10 % in either
direction (f1 alike). The f2-f1 gap itself is outside the run loop (the
loop is faster than format 1's on the C6: 225 vs 255 ms of tasks-1k):
finally-code calls and returns through `slow` with a ROM memmove of the
records, full room scans (`ensure_room_all`), the C++ primitive round
trip and the try/unwind paths.

Changes: no full scan after a primitive's return on the machine
(`rarrays::ret_room_kept`); finally records moved five words per step
(`StackMem::move_records`, no memmove); finally-code calls and returns at
the entry of `slow` (`slow_body` is the machine part); TRY in finally code
on the registers (`rnonlocal::try_fins`); a C++ primitive's failure
without GC on the registers; the RPC/task helpers in the C6/S3 IRAM list.
C6, three sessions, f2/f1: rpc-200 1.31 -> 1.14, rpc-echo-50 1.26 ->
1.15, yield-2k 1.24 -> 1.20, tasks-1k 1.43 -> 1.18 (430 -> 355 ms);
richards, deltablue, pystone, json equal or faster. Flash +752 B, free
heap -3.5 KB (C6).

| crate | 64-bit | 32-bit |
|---|---:|---:|
| core (whole loop) | 1,052 verified, 0 errors | 1,054, 0 |
| core-split | 1,054, 0 | 1,056, 0 |

## Split loop as a build option (branch core/split-option, 2026-11-24)

Base sandbox-integration 7f7ad28e. Requests R1-R3 of device/measure-2
(the split loop of call-speed-size made the C6 4-50 % slower). Artifacts:
/home/flo/work/opentoit-sandbox-artifacts/split-option (README.md:
scripts, configurations, all tables and logs).

The option. `step::split_loop()` (`cfg!(target_os = "none")`, an
external_body without contract) is gone, and with it its TRUSTED.toml
entry (core external_body items 43 -> 42). The split is the core's Cargo
feature `split-loop` (forwarded by vmverify and its staticlib), set by
CMake `TOIT_VERIFIED_CORE_SPLIT_LOOP` (default OFF), Kconfig
`TOIT_VERIFIED_CORE_SPLIT_LOOP` (default n on every ESP32 target) and
Makefile `EC618_SPLIT_LOOP` (default ON: the EC618 keeps its earlier,
unmeasured configuration). In `step_r` the arms of the rare opcodes carry
`#[cfg(not(feature = "split-loop"))]` and one `#[cfg(feature =
"split-loop")]` arm calls `step_cold`; `cold_op`, `step_cold` and `step_c`
exist only with the feature. Both configurations are separate
compilations, both verified: check.sh verifies the core twice (`core`,
`core-split`) at both word sizes; nopanic_check.sh, thumb_codegen_check.sh
and nostd_check.sh build both.

| crate | 64-bit | 32-bit |
|---|---:|---:|
| spec | 994 verified, 0 errors | 994, 0 |
| core (whole loop) | 1,038, 0 | 1,040, 0 |
| core-split | 1,040, 0 | 1,042, 0 |
| core before (7f7ad28e) | 1,041, 0 | 1,043, 0 |

The split loop (R3). The cold call no longer goes through the machine:
`step_r`'s cold arm calls `step_cold(m, *r, env)` (the registers by value,
out of line), and `step_cold` runs a slow path its handler hands on
(`Ctl::Slow`) itself, so it never returns `Slow`; `Slow::Cold`, the
request store/load and the old `slow` wrapper (which copied the registers
with ROM memcpy on Xtensa, unconditionally) are gone; `slow_body` is now
`slow`. The hot set follows dynamic opcode counts of the device benchmarks
(hwbench and perfbench without RPC, trusted format 2, debug host build
with -Xtrace; split-option/logs/opcounts.txt): PRIMITIVE (in every
benchmark: 28,063 in strings, 19,329 in json), LOAD_SMI_U32 (1,000,001 in
loop-1M, 6,000 in gc-stress), TRY and UNWIND (20,000 each in tasks-1k),
IDENTICAL (12,001 in tasks-1k), MOD, DIV, SHL, XOR and
INVOKE_STATIC_TAIL moved to the hot part. Cold now: the opcodes with no
execution in the benchmarks (the _WIDE forms, interface/wide IS/AS, wide
lazy and dynamic globals, the conditional back branches, USHR, LAMBDA_TAIL,
THROW, HALT) and NON_LOCAL_BRANCH, STORE_GLOBAL_VAR_DYNAMIC,
INITIALIZER_TAIL (a few hundred). Hot part 17.2 KB (was 12.3), cold part
2.8 KB (was 7.0) on the classic ESP32.

Devices (classic ESP32 rig boards, ESP32-C6; split-option/README.md):

- C6, whole loop (the default) against measure-2's split loop, means of 5
  builds/sessions: json 0.81x, strings 0.78x, loop-1M 0.66x, tasks-1k
  0.85x, rpc-200 0.93x, richards 0.92x; faster than the 11-12 November
  firmware everywhere except RPC (rpc-200 1.12x: 420 vs 373 ms; C6 f1
  moves 6 % on RPC between layouts, f2 4 %). Free heap at boot 219.7 KB
  (split 227.7 KB in measure-2, the new split 222.0 KB). The new split
  loop is within 0-4 % of the whole one on the C6.
- Classic ESP32: whole loop (the default) against the new split loop over
  four layout-perturbed builds each (same pads): the whole loop is faster
  on the layout-insensitive benchmarks (richards 914 vs 945 ms, pystone
  142 vs 148, loop-1M 1,674 vs 1,764, calls 531 vs 554) and equal or
  faster in the means of all others. IRAM: whole 125,826 B used (5,246
  free), split with the cold part in IRAM 126,750 (4,322), split with it
  in flash 122,887. Flash with Jaguar: whole -23,104 B (measure-2 split:
  -23,280), split -24,256. Free heap at boot 131.2 KB.
- Layout noise on the classic ESP32: shifting the VM's flash code by 2.4,
  6.3 or 11.1 KB (dead code at the start of `VM::VM()`) moves f1 by up to
  -42 % (tison-2k) / +98 % (interp-1k) / +39 % (tasks-1k) and f2 alike,
  so single builds do not compare there; the tables give means and
  min-max over the builds.
- Device suite (f2) on both chips: all verdicts as before; untrusted
  install on the ESP32 5.8-7.4 s with WiFi (measure-2: 5.8-7.3 s).

## Call speed, loop size, inline allocation (branch core/call-speed-size, 2026-11-12)

Base sandbox-integration a773bcfe (compact records), sandbox-integration
d369b967 (hardware runs, loop in IRAM) merged before the final gates.
Nothing was flashed. Artifacts: /home/flo/work/opentoit-sandbox-artifacts/
call-speed-size (dev/: firmware, QEMU scripts, profiles `qprof.sh`,
`byhandler.sh`, `cmph.sh`; tools/: verification, gates, `opcount.sh`,
`split_step.pl`; bench/opcounts.txt: dynamic opcode counts).

Measurement: a benchmark-only QEMU suite (dev/qemu/progs/bench-only.toit,
`-icount shift=0`, f2/f1 instructions; f1: richards 181,659, deltablue
10,333, pystone 24,333, json 26,793 µs) and per-handler instruction
profiles of QEMU traces (`qprof.sh`: TB counts, attributed to the
handlers through the jump table). Pre-compact (16-byte records,
device/size firmware): 0.708 / 0.994 / 0.857 / 1.076.

Item 1, the Xtensa call path (format note 21, "Xtensa"):

| Step | Commit | richards | deltablue | pystone | json |
|---|---|---:|---:|---:|---:|
| compact records as merged | a773bcfe | 0.761 | 1.064 | 0.906 | 1.108 |
| odd entries, aligned `l16ui` fields (+1.5 KB pad bytes) | acf24c76 | 0.767 | 1.061 | 0.890 | 1.105 |
| virtual calls take the arity from the operand | acf24c76 | 0.741 | 1.036 | 0.890 | 1.093 |
| tables addressed through `pre` (offsets fold) | acf24c76 | 0.737 | 1.040 | 0.888 | 1.104 |
| word class ids (no 64-bit compares on 32-bit) | b1aaa438 | 0.717 | 0.981 | 0.878 | 1.047 |
| one-shift class id | b1aaa438 | 0.696 | 0.947 | 0.867 | 1.031 |

The regression was only partly the header reads (6 instructions per u16
field: 10 per selector check instead of 5); the rest was register
allocation of the run loop (one more spill, moves) that the per-handler
profiles showed. The register allocation of the 30 KB loop changes with
every edit (QEMU deltas of ±1-3 % from unrelated changes); LLVM flags
(split-spill-mode, misched, local interval cost, tail-dup 8/16/20)
changed nothing beyond ±0.3 %. Host (callgrind, trusted): richards
1,066 M, deltablue 754 M, pystone 810 M, json 1,314 M, RPC 417 M
(EXPERIMENT-trusted.md 1,078 / 761 / 810 / 1,332 / 444). RISC-V (C6):
selector check `lw, add, lhu` instead of `lbu, lbu, slli, or`.

Item 2, size and the loop's hot part (classic ESP32 f2; IRAM matters
since the hardware runs, the coordinator's request):

| Change | Commit | toit.bin | run_loop | QEMU f2/f1 richards / deltablue / pystone / json |
|---|---|---:|---:|---|
| start (a773bcfe, measured here) | | 1,544,000 | 28,275 | 0.761 / 1.064 / 0.906 / 1.108 |
| item 1 | b1aaa438 | 1,541,376 | 26,654 | 0.696 / 0.947 / 0.867 / 1.031 |
| core at opt-level s, `run_loop` `optimize(speed)` (Xtensa only, esp nightly) | 324b0d93 | 1,537,088 | 26,127 | 0.689 / 0.935 / 0.830 / 1.011 |
| one slow-path call site (`Ctl::Slow`, request in the machine) | 9214fcd1 | 1,529,696 | 19,030 | 0.673 / 0.917 / 0.822 / 1.002 |
| hot/cold split (`step_cold`, flash) | 2e816470 | 1,529,968 | 12,208 | 0.720 / 0.995 / 0.919 / 1.191 |
| inline allocation proven (item 3) | 2fecc427 | 1,530,144 | 12,351 | (final, below) |

Opt levels on the classic ESP32: the core crate at s, `step::run_loop`
(with every handler inlined into it) at speed through
`#[optimize(speed)]`; toit_spec and toit_vmverify at z (unchanged);
RISC-V targets at 3 (stable toolchain, no attribute). The slow paths:
98 call sites of `slow` (22 Xtensa instructions each: the registers, the
request and the result through memory) became one; the result of a step
must not be passed on whole (it then lives in memory and every handler
stores it: 40 % slower, slow1-3 in the artifacts).

The split: the rare opcodes (`cold_op`, by dynamic counts of richards,
deltablue, pystone, json, RPC, strings and map-set: the _WIDE variants,
dynamic globals, HALT, THROW, non-local branches, TRY/UNWIND, rare
arithmetic, PRIMITIVE) go through the loop's one call site (`Slow::Cold`)
to `step_cold` (flash). Sections: `step::run_loop` is the hot part (renamed
to `.iram1.toit_run_loop` by localize-libm.cmake with
TOIT_VERIFIED_CORE_LOOP_IN_IRAM), everything else stays in `.text`
(flash). Classic ESP32: hot 12.4 KB, cold 7.2 KB plus `slow_body` 4.4 KB;
the firmware links with ESP_WIFI_RX_IRAM_OPT on (IRAM 129,379 of 131,072).
C6: hot 12.4 KB (was 19.8 KB). Cost in QEMU instructions against the
unsplit loop: richards +7 %, deltablue +9 %, pystone +12 %, json +19 %
(primitive calls take the cold path, and in this allocation the jump
table base is reloaded per dispatch); with PRIMITIVE hot the hot part is
15.9 KB (does not fit with the WiFi option) at +3 / +4 / +4 / +5 %.

Flash with Jaguar (dev/jag-all.txt, Jaguar compiled with this SDK): ESP32
f2 -18,736 B against the OTA partition (start of the branch: -28,512;
the Jaguar image crossed a 4 KB page through the pad bytes: +4,224 B),
f1 +56,176; C6 f2 +69,392, f1 +141,008.

Remaining size options (not done): the verifier left out (Kconfig
TOIT_VERIFIED_CORE_VERIFIER=n, -29.6 KB: fits with ~11 KB), image
off-heap rounded to a word instead of a 4 KB page (about 2 KB per image,
here 4 KB of Jaguar), the C++ copies of ported primitives (up to 5 KB,
each needs "never declines" proven), shared twin and _WIDE bodies (now
in the cold flash part: flash only), the partition layout.

Item 3, inline allocation on the permission model: `Runtime::bump`
(external_body, the derivation point) hands out the permissions of the
fresh words with `Heap::fresh_ok`; `bump_instance` and `bump_double`
write through them (`Heap::write_fresh`) and append the object
(`Heap::append`, `fresh::append_mem`: the heap invariant for the new
object id), and `alloc::lemma_refines_append` proves the machine
contract. bump_double checks the double class' tag at run time (no spec
fact) and bump_instance class ids below 2^16 (the model's). TRUSTED.toml:
-5 entries, +2.

Merged onto wip/collector-proofs (2026-11-23): that branch had proven the
same fast path independently and without `unsafe` (`Runtime::bump` over
`Runtime::allocation_window`, `allocate_modeled` and
`Heap::register_inline`; trusted: the window's `assume_new` and
external_body). The merge keeps that proof and drops item 3's code
(`Runtime::bump` with its three trusted entries, `fresh.rs`,
`Heap::{fresh_ok, write_fresh, append}`, `alloc::lemma_refines_append`);
the device measurements above were taken with item 3. The loader's
alignment and odd-entry checks of item 1 moved into the factored,
proven table validation (`v2_check_header`, `v2_compute_method_table.h`).

Proofs: core 962 -> 1007 items (spec 962 unchanged), zero admits, both
widths (core 64-bit ~2 min, 32-bit ~1 min with 16 jobs). Two proofs of
view.rs (`lemma_bytes_written`, `copy_content`) needed explicit hints
after the new module contents at 32 bits.

## Hardware runs: where the time goes (branch device/hw-perf, 2026-11-12)

Attribution and fixes of the format-2 gaps on the boards; details in
docs/format2-migration.md, "Where the time goes"; artifacts
/home/flo/work/opentoit-sandbox-artifacts/hw-perf.

- Tool: Kconfig TOIT_HW_PERF (src/hw_perf.h): cycles, retired
  instructions and Xtensa stall counters per VM activity and per C++
  primitive, plus PC samples; `Profiler.start`/`stop` without a profiler
  reset and print them.
- Cause: not instructions (200 service calls: 32.4 M in format 2, 29.1 M
  in format 1) but flash: the core's out-of-loop functions and glue ran
  from flash (25-30 % of format 2's busy time on the classic ESP32, 16-25 %
  on the C6) and evicted the C++ runtime from the shared flash cache. Of
  the ESP32's extra cycles in service calls: instruction-fetch stalls 79 %
  (core and glue 42 %, C++ runtime 37 %), data stalls 26 %.
- Fix (no proven code changed): the C++ hand-over and primitive glue in
  IRAM; Kconfig TOIT_VERIFIED_CORE_IRAM_FUNCTIONS places named core
  functions in IRAM (classic ESP32 3.8 KB, all that fits; C6/S3 11.7 KB).
  200 service calls f2/f1: ESP32 1.82 -> 1.25, C6 1.70 -> 1.17, S3 2.46 ->
  1.08; json ESP32 1.06-1.11, C6 1.16.
- Logic costs found for the core: the finally records move (ROM memmove)
  on every call inside a `try` (9-12 % of task switching), and
  `ensure_room_all` walks every frame on resume (2-8 %). With room for the
  rest of the hot functions in IRAM the classic ESP32 matched format 1 on
  service calls (543 vs 560 ms, a firmware without Bluetooth). Requests S1
  (split the loop: 99 % of its samples in 8 KB, all in 13.8 KB of 28 KB),
  S2-S6 in OBLIGATIONS.md ("Device speed requests").
- WiFi RX opt (13.2 KB IRAM): no measurable throughput difference (Toit
  TCP receive 200-300 KB/s either way).
- Install on the classic ESP32: 5.4-6.8 s (the trace build added 0.7 s);
  verification 4.0-5.0 s, of which 99 % method checks: 270-490 M
  instructions at CPI 2.5, malloc/free a third of the busy samples;
  verifier opt-level 3 or s within 5 % of z. Requests V1 (allocations),
  V2 (instructions).

## Hardware runs (branch device/hardware, 2026-11-12)

First runs of format 2 on the core on real boards: an ESP32-C6, the rig's
classic ESP32 boards and an ESP32-S3 (brought up here). Details, tables
and the measurement method: docs/format2-migration.md, "Devices: hardware
results"; artifacts /home/flo/work/opentoit-sandbox-artifacts/hardware.

- Everything runs on all three chips without the C++ interpreter: the
  device suite (services, preemption, stack traces, untrusted installs
  and rejections, deep sleep), installs with WiFi up, long busy loops (no
  watchdog), OTA without Jaguar (C6, ESP32). The hw test suite
  (tests/hw/esp32, 74 tests) has the same failures in f1 and f2 apart from
  two radio/timing tests (see the doc).
- **The loop must run from IRAM**: from flash it thrashed the flash cache
  (classic ESP32 json 5.1x, map/set 5.4x slower than the C++ interpreter;
  QEMU had counted 1.07x instructions). Kconfig
  TOIT_VERIFIED_CORE_LOOP_IN_IRAM renames `step::run_loop`'s sections in
  the device library (no change in verified/core). With it, f2/f1 wall
  time: ESP32 richards 0.53, deltablue 0.72, pystone 0.88, json 1.47,
  map/set 1.38, strings 1.09, 200 RPCs 2.26; C6 0.93 / 1.16 / 1.01 / 1.31
  / 1.17 / 1.19 / 1.79; S3 0.70 / 1.03 / 0.89 / 1.27 / 1.18 / 0.96 / 2.46.
  A split loop (dispatch and hot handlers in IRAM) would need changes in
  verified/core: not tried.
- Remaining gaps on hardware: RPC between containers (1.8-2.5x), json and
  map/set (1.2-1.5x); verification at install 1.8-2.2 s on the C6 (opt-z
  verifier; opt 3 only 13 % faster for +12.6 KB) and 4.6-5.5 s on the
  classic ESP32 with peak heap 12-23 KB.
- Rust opt-level of the core (C6): s saves 5.6 KB and costs 7-24 %, z
  saves 7.4 KB and costs 42-133 %; on the classic ESP32 the z loop (33 KB)
  does not fit IRAM.
- Compact method records cost 2.7-4.3 % on call-heavy code on the C6
  (RISC-V) and 0.4-4 % on the ESP32; no alignment fault.

## Compact method records (branch core/compact-methods, 2026-11-11)

The method table of format 2 shrinks from 16 to 4 bytes per method
(format note 21, verified/spec/format/21-compact-method-records.md: the
design comparison, the decision and the costs). Base: sandbox-integration
(88a3fe30, later 655e860d merged) plus device/size (040bfdac). Nothing
was flashed. Artifacts: /home/flo/work/opentoit-sandbox-artifacts/
compact-methods (tools/: bench, verification, batteries, gates; dev/:
firmware, Jaguar and QEMU scripts and results; toolsrc/methstats.toit:
the size model of the layouts).

Chosen (K2): a record `entry << 8 | arity`; the header ends at the entry,
a kind byte (the kind, or 4 for a method of one class or none) and every
field at a fixed distance before the entry (selector e-3, receiver start
e-5, end e-7, accessor field e-9, lambda captured count e-3; 0xffff for
none); a body ends at the next header, so the table literal ("TMT2") is
mandatory. Why this one: the layouts whose field offsets depend on flag
bits (E1/E2, 3.6 KB smaller) cost 6 to 11 % on the call paths (measured,
`k2a`..`k2c` in tools/bench); K2 keeps every hot read at a constant
offset, and a dispatch target of an accepted program needs no kind test.

- C1 (126811f0, 59c3e113): compiler emission and the literal
  (program_builder.cc), `V2MethodTable` (records, `at` decodes,
  `compute` checks the literal: headers inside the bytecodes before
  their entries, back to back from the tag, canonical kind bytes and
  ranges), tools/snapshot.toit, the dump loader (loader.rs), vmverify,
  the fuzz driver. Spec: `vprog::{vdecode, table_ok, MTable, x_table_ok}`
  (MTable's view is the decoded table, so the verifier's proofs did not
  change beyond `ix` -> `at`); core: `Program::{minfo, method, entry_of,
  arity_of, is_kind, dispatch_selector, dispatch_recv_start,
  dispatch_recv_contains}`, `calls::lemma_dispatch_kind` (from
  `accepts`: a dispatch target is a method or an accessor),
  `prog_rel` relates `ap.methods` to `minfo` and states `table_ok`
  (with a canonical kind byte, so a kind is one compare); `lookup` and
  `check_type` require `accepts`. Verus: spec 962, core 976 verified at
  64 and 32 bits (core 41-109 s wall), zero admits; THEOREMS unchanged
  but for `vmethods_of`/`vprogram_of` (an `MTable` instead of a `Vec`).
- C2 (85abc751): red-team batteries pass again (item of the
  coordinator, below); gc_metadata.h's unaligned mark-bit access through
  memcpy (UBSan reported it on every GC of the ASan build).
- C3 (93ae138f): LAYOUT.toml rows for the Stack header words
  (`STACK_LENGTH/TOP/RECORD_TOP/BCI_WORD`, `STACK_FRAME_TOP_SHIFT`) and
  the payload split of doubles and large integers (`VALUE_WORDS`, moved
  from view.rs to layout.rs), checked against the C++; MTable::len
  without `when_used_as_spec` (the audit counts it as an escape hatch);
  the verifier's decoder through `xvec::ix` (no panic paths).

Sizes (classic ESP32 unless noted; firmware builds dev/bins, dev/jag-all.txt):

| | before (device/size) | after | saved |
|---|---:|---:|---:|
| system image (-m32 binary) | 109,824 | 88,704 | 21,120 |
| Jaguar image (-m32) | 126,720 | 101,376 | 25,344 (= format 1's) |
| toit.bin ESP32 f2 | 1,542,256 | 1,544,032 | -1,776 |
| flashed, system only | 1,652,864 | 1,634,144 | 18,720 |
| flashed with Jaguar, ESP32 | 1,775,744 (-71,808) | 1,732,448 (-28,512) | 43,296 |
| flashed with Jaguar, C6 | 1,871,152 (+29,392) | 1,825,920 (+74,624) | 45,232 |

Table plus headers of system and Jaguar (methstats): 75.3 KB -> 30.7 KB.
toit.bin grows by 1.8 KB (the decoders and the stricter loader). The
classic ESP32 with Jaguar is still 28.5 KB over its OTA partition; with
the verifier left out (Kconfig, S4 of device/size, -29.6 KB) it would fit
by about 1 KB.

Speed (callgrind Ir in `Interpreter::run`, trusted format 2, against the
starting point built in this worktree, build/host-f2-base):

| | base | after | | EXPERIMENT-trusted.md |
|---|---:|---:|---:|---:|
| richards | 1,072.9 M | 1,080.1 M | +0.67 % | 1,077.9 (+0.21 %) |
| deltablue | 755.8 M | 759.8 M | +0.52 % | 760.8 (-0.13 %) |
| pystone | 811.5 M | 812.7 M | +0.16 % | 810.2 (+0.31 %) |
| json | 1,311.6 M | 1,311.4 M | -0.01 % | 1,331.6 (-1.5 %) |
| RPC | 418.2 M | 417.9 M | -0.06 % | 443.6 (-5.8 %) |
| static call loop | 245.5 M | 245.4 M | -0.04 % | |
| virtual call loop | 314.5 M | 314.4 M | -0.04 % | |

QEMU (ESP32, icount; dev/qemu/run-{f1,f2}-cm): the suite output is
identical to device/size's final runs for f1 and f2, but **f2 is slower
on Xtensa** (us, before -> after; f2/f1): richards 128,565 -> 138,186
(0.720 -> 0.774, +7.5 %), deltablue 10,086 -> 10,786 (0.968 -> 1.032),
pystone 20,986 -> 22,186 (0.863 -> 0.912), json 28,559 -> 29,426 (1.068
-> 1.100), strings +3.7 %, map-set +1.7 %, RPC +1.8 %, gc-stress 0. Not
within the 2 % bound. Cause (dev/scripts/runloop-dis.sh): Xtensa has no
unaligned 16-bit load and only positive load offsets, so each header u16
is `addi, l8ui, addi, l8ui, slli, or` (a virtual lookup's selector
compare is about 10 instructions instead of an l16ui and a compare), and
the record's entry and arity cost a shift and a mask. x86 hides this
(`cmpw -3(%rbp,%rcx)`). Fix (not done): 2-byte aligned entries with the
u16 fields at even distances (one l16ui each; about 0.5 B of padding per
method, 1.8 KB), or the hot fields loaded from one base with positive
offsets; then re-measure.

Gates (artifacts gates/, logs/): verified/check.sh --tests passed (spec
962, core 976 at both widths; audit exact, 262 occurrences: -1, the
`when_used_as_spec` of a first version removed; VeriFast 111; sandbox
ctests 125/125; round-3 and round-4 batteries on build/asan and the
debug build); ctest -j16 format 2 1205/1206 (udp-reuse-port-test; 16
toitp/image tests needed `ninja build_test_assets` after the format
change), format 1 (build/host-f1) 1203/1206 (version, reader,
udp-reuse-port-test); untrusted suite 280 identical plus the two known
differences; primitive differential 10/10 seeds identical; compare_trace
--format 2 clean on the four programs; 32-bit host sandbox 125/125;
nostd, nopanic (3, s, z), Xtensa codegen (3, z); firmware ESP32 and C6 in
f1 and f2; QEMU suite output identical (f1, f2). Fuzz with the launch
filter, 30 minutes: on Release+ASan (the earlier gates' build) 115,465
mutants, 0 crashes; on build/asan (CMAKE_BUILD_TYPE=asan: assertions and
UBSan) 31,010 mutants, 3 hits of one debug assertion (`objects.h:591`:
`EncodeVisitor::visit_byte_array` takes the bytes of an external byte
array with a non-raw tag while encoding an exception; release throws
LOOKUP_FAILED; not related to the table; gates/fuzz-cm2). The fuzz seeds
had all been skipped since the trusted default compiles twins
(core_fuzz.toit now compiles them --untrusted, c41084fd).

### The red-team batteries (coordinator's item)

Cause: not the table check. tools/asm.toit overwrote the program
header's off-heap byte count with the bytecodes' size alone; since
device/format2 the method table literal is an external byte array that
the count also covers, so every patched snapshot (even the unchanged
`good-retnull`) failed to install with INVALID_ARGUMENT (the flash
allocation's size check), on both builds. Fixed (the count moves by the
bytecodes' share), and asm.toit now moves the table records of the
following methods (`--stale-table` leaves them stale on purpose), and
takes `@NAME` operands (the dispatch index of a static method). An
inconsistent table is refused at load with INVALID_SNAPSHOT ("format-2
program rejected: bad method kind byte"), untrusted and trusted, no
sanitizer report: four new cases in round-4 battery A
(`table-stale-shorter/longer/by-one`, `table-same-size`). The heap
battery's hard-coded object indices and class ids had drifted with the
library (the table literal and new failure strings moved the objects,
new classes the class ids): `heapcraft find` names them now; its bases
are compiled `--untrusted` (a trusted compile has the unchecked twins,
which an untrusted run rejects before any case). Expectations updated:
round-3 asm and round-4 A (method index and bci only: library drift and
the header layout), `good-print` (prints 55 now: the hard-coded dispatch
index pointed to another method). With build/asan (address,undefined)
and build/host32 in the worktree, round 3 (heap 61, asm 68) and round 4
(A 38, A-cert 9, B 32, C 31, D 31, E 31, F 22) pass.

### Not done

- Second item (inline bump allocation on the permission model): not
  started; the steps in "Proven accessors" below stand. The LAYOUT.toml
  rows it asked for are in (C3).
- Further size in the core (Xtensa; estimates, not measured here): the
  verifier (27.5 KB) is the one item that alone closes the remaining 28.5
  KB (Kconfig off: -29.6 KB, device/size S4) for products that install no
  untrusted containers; the checker without the inference could shed its
  cold diagnostics (`diagnose_shipped`, verdict texts: 2-3 KB). Run loop
  (28.3 KB now): the ten unchecked twins duplicate their checked handlers
  (2-3 KB if they share a body with a flag known at the call site), the
  _WIDE operand variants another 1-2 KB. Cold paths (13.7 KB): one
  generic slow call path instead of per-opcode slow arms, 3-5 KB. The 106
  primitives (15 KB) plus their 99 C++ copies (9.6 KB) kept for
  `NotPorted`: up to 5 KB where the port provably never declines.

## EC618 on format 2 (branch device/ec618, 2026-11-12)

The EC618 (Cortex-M3) builds and runs format 2 on the core; details,
tables and the remaining work in docs/format2-migration.md, "EC618".
Nothing was flashed; scripts, logs and runs:
/home/flo/work/opentoit-sandbox-artifacts/ec618. Nothing inside
verified/core/src or verified/spec changed.

- The device library for `thumbv7m-none-eabi` (upstream tier 2) at 3, s,
  z with LTO: nostd_check.sh (now with thumbv7m), nopanic_check.sh
  (`NOPANIC_ARCH=arm`), device_size.sh (`DEVICE_SIZE_ARCH=arm`: Rust
  75,728 / 66,578 / 62,418 B at 3 / s / z, against 72,806 riscv32 and
  79,129 Xtensa at 3), and the new thumb_codegen_check.sh (v7-M Thumb-2,
  GCC-compatible ABI attributes, no FPU, no movw/movt, no atomic helpers;
  check.sh runs it and the arm no-panic check when the tools exist).
  Atomics are native on v7-M; none are linked.
- verified/vmverify/.cargo/config.toml: `+no-movt` for thumbv7m (the EC618
  slot relocator moves words, not movw/movt pairs).
- Firmware: `make ec618 EC618_BYTECODE_FORMAT=2` (base, both slot links,
  SRL3 byte-identity check, envelope with `bytecode-formats` [2]); format
  1 builds as before. VM body 315,408 -> 378,404 B (Rust 74,511, C++
  interpreter -13,997), system image 90,156 -> 118,828, slot 502,324 of
  786,432 B.
- Fixed on the way: `Stack::v2_frames_skip_` is a plain static on the
  EC618 (emulated TLS broke the slot relocation); the slot's `.bss` lay
  over the CP's AON backup in the ASMB (a bug of format 1 too).
- QEMU (mps2-an385, tests/ec618-qemu: the slot's objects with the EC618
  base's prebuilt FreeRTOS and heap): the ESP32 device suite gives the
  same results in format 1 and 2; primitive differential f1 against f2 on
  the Cortex-M3 (3 MB heap): 7 of 8 seeds x 250,000 calls identical,
  seed 8 differs at a two-NaN multiply (which NaN propagates); with the
  354 KB heap the runs diverge at allocation failures that the two
  interpreters' GC retries resolve differently. Instructions f2/f1
  (libinsn plugin): richards 1.079, deltablue 1.195, pystone 1.071, json
  1.232, map/set 1.071, strings 1.160, GC stress 0.913; opt-level s is
  9.2 KB smaller and slightly faster (richards 1.052).
- Not a core bug but worth knowing: on soft-float targets the NaN a float
  primitive returns depends on whose soft-float helpers are linked
  (compiler_builtins canonicalizes, libgcc propagates an operand); the
  EC618 firmware links the base's libgcc for both interpreters.

Gates (ae8a4970): verified/check.sh --tests: Verus spec 940 and core 954
at both widths, audit, VeriFast 135, nopanic (riscv32imac and thumbv7m),
thumb codegen, sandbox ctests 125/125, round-4 batteries A-cert, B, D, E,
F pass (C skipped: no host32 build). Three red-team batteries fail, and
only run at all with an ASan build (built here for the gate; without one
battery A fails at its environment check): round-3 heap and asm, round-4
A. Not this branch: tools/asm.toit (and the round-3 snapshot mutator)
patch methods without updating the method-table literal (`TMT1`,
-Xv2_table_literal, device/format2 M3), so the patched snapshots fail to
start with INVALID_ARGUMENT in the release build too; with
`-Xv2_table_literal=false` the same patch runs. Host ctest -R
tests/sandbox/ 125/125. Firmware: ESP32 and ESP32-C6, format 1 and format
2 (core, no C++), build (toit.bin 1,463,072 / 1,541,840 and 1,574,848 /
1,636,480 B); the EC618 in format 1 as before and in all format-2
configurations.

## Device size (branch device/size, 2026-11-11)

Size reduction of the format-2 firmware (core, no C++ interpreter) for the
classic ESP32. Nothing was flashed; scripts, logs and builds:
/home/flo/work/opentoit-sandbox-artifacts/device-size (README.md).
**Result: the classic ESP32's format-2 firmware with Jaguar still does not
fit (1,775,744 of 1,703,936 B, 70 KB over; was 108 KB over); the ESP32-C6
now fits with 29 KB to spare (was 2 KB over). The default was not
flipped.** Nothing inside verified/core/src or verified/spec changed.

Attribution before (classic ESP32, f2 against f1 at d960ca45; linker map,
esp_idf_size, `scripts/mapsyms.sh`, `rust-groups.sh`, `img.sh`):

| Part | Bytes |
|---|---:|
| toit.bin f2 - f1 | +87,136 |
| Rust: run loop (`step::run_loop` with its jump table) | +30,887 |
| Rust: core cold paths (`step::slow`, r* helpers, raise, unwind) | +13,728 |
| Rust: the 106 primitives (`prims::`) | +14,952 |
| Rust: verifier (toit_spec 13,582, vmverify glue 12,210, C entry 1,687) | +27,479 |
| Rust: other (core/alloc, entry points, rodata) | +2,022 |
| Rust: compiler_builtins (C math 23.5 K, u128 division 2.6 K, rest) | +27,009 |
| newlib libm (replaced by compiler_builtins' weak math functions) | -20,571 |
| C++ interpreter (interpreter_run, method_entries) | -14,583 |
| C++ format-2 glue (interpreter_v2, verifier_v2) and messages | +5,890 |
| interpreter.cc, interpreter_core.cc, other | -2,677 |
| system image f2 - f1 (88,704 -> 114,048) | +25,344 |
| method-table literal (16 B x 1,743 methods, with relocation bits) | +28,776 |
| bytecodes (61,898 -> 58,883: format 2 is 5 % smaller) | -3,015 |
| Jaguar image f2 - f1 (101,376 -> 126,720; literal 29,408 B) | +25,344 |
| DROM extension padding (64 KB pages): with Jaguar 4 pages, f1 3 | +65,536 |

There is no second loop on devices: the checked loop is not linked (393
B remnant); trusted and verified programs share `run_loop`. The dispatch
table is dense (no holes worth packing), the trusted images carry no
certificate, and the C++ side is already -Os (-Oz gives the same code
with this GCC).

Bytes saved per change, classic ESP32 f2 (format 2 on the core, no C++
interpreter): toit.bin, and the flashed binary with the system and Jaguar
(v1.73.0, -O2) against the 1,703,936-byte OTA partition (scripts/
jag-check.sh, as tests/esp32/check-partition-sizes.sh). Base d960ca45:
f1 toit.bin 1,462,912 B, with Jaguar 1,659,520 B.

| Change | Commit | toit.bin | saved | with Jaguar | saved |
|---|---|---:|---:|---:|---:|
| base (d960ca45) | | 1,550,048 | | 1,812,192 | |
| S1 newlib's libm instead of compiler_builtins' C math functions | f803b3a8 | 1,543,488 | 6,560 | 1,805,632 | 6,560 |
| S2 TOIT_V2_VALIDATE, TOIT_VERIFY_TIME on hosts only | ebbdf36a | 1,542,272 | 1,216 | (1,804,416) | 1,216 |
| S3 the binary laid out around the DROM extension (no 64 KB padding) | 2d51679f | 1,542,272 | 0 | 1,779,840 | 24,576 |
| S4 Kconfig TOIT_VERIFIED_CORE_VERIFIER (off: no verifier; default on) | d9ac75e8 | (1,512,672) | (29,584) | (1,750,256) | (29,584) |
| S5 images without unused trailing heap blocks (system 114,048 -> 109,824) | 30f496ed | 1,542,272 | 0 | 1,775,744 | 4,096 |
| total (default configuration) | | 1,542,256 | 7,792 | 1,775,744 | 36,448 |

(The final builds, with a pinned version string, have toit.bin 1,542,256
B; parenthesized rows are the non-default configuration.) S3 is a change of
`toit tool firmware` only: the bootloader, the VM and the envelope format
are unchanged; QEMU boots the relaid binaries (8 segments of at most 16)
and runs the suite. S1 also makes the C++ math primitives (math.pow, sin,
...) newlib's again, as in format 1.

After (QEMU suite: `scripts/suite-all.sh final`, output identical to the
previous agent's runs for f1 and f2):

| | ESP32 f1 | ESP32 f2 | ESP32 f2, no verifier | C6 f1 | C6 f2 |
|---|---:|---:|---:|---:|---:|
| toit.bin | 1,462,864 | 1,542,256 | 1,512,672 | 1,574,544 | 1,637,680 |
| flashed, system only | 1,548,896 | 1,652,864 | 1,627,376 | 1,660,576 | 1,748,272 |
| flashed, with Jaguar | 1,647,200 | 1,775,744 | 1,750,256 | 1,758,880 | 1,871,152 |
| OTA partition, margin | +56,736 | -71,808 | -46,320 | +141,664 | +29,392 |
| Rust library | 0 | 89,068 | 61,804 | 0 | 78,557 |
| system image | 84,480 | 109,824 | 109,824 | 84,480 | 109,824 |
| iram0.text | 129,087 | 116,947 | 116,947 | 156,350 | 139,998 |
| free heap at boot (QEMU) | 116,904 | 133,712 | | | |

Instructions (QEMU icount, f2/f1): richards 0.720, deltablue 0.968,
pystone 0.863, json 1.068 (unchanged). Host (callgrind Ir in
`Interpreter::run`, trusted format 2): richards 1,075.3 M, deltablue
758.7 M, pystone 811.9 M (EXPERIMENT-trusted.md: 1,077.9 / 760.8 /
810.2 M).

Gates (30f496ed): verified/check.sh --tests passed (VeriFast 87 checks,
sandbox ctests 125/125); ctest -j16 1201/1204 (version, reader not run;
udp-reuse-port-test); nostd, nopanic, xtensa_codegen_check (3, z) pass;
firmware: classic ESP32 and C6 in f1 and f2 (and ESP32 without the
verifier); QEMU suite identical for f1 and f2.

What closing the remaining 70 KB would take (not done):

- Both table literals out of the images (`-Xv2_table_literal=false`):
  -57.5 KB flash (Jaguar alone -28.7 KB measured), but +57 KB of RAM
  with Jaguar running (16 B per method, 1,743 + 1,837 methods; format 1
  needs 13 KB of entry bitmaps for the two). Even then about 14.5 KB
  over; together with the verifier left out about 15 KB to spare.
- A smaller method record (core: `V2Method`, `exec::Program::methods`,
  their proofs and the C++ table builder): 12 bytes (24-bit entry with the
  kind, length, arity, selector, aux and receiver range packed) saves
  4 B per method, 14.3 KB for system plus Jaguar; 8 bytes (entry, length,
  arity, kind; selector, aux and receiver range in a side table for the
  40 % / 62 % of methods that have them) saves 28.6 KB, and as much RAM
  per installed untrusted program, at the cost of a second lookup on
  virtual calls and receiver checks. Jaguar's headers hold the same
  fields in 9.4 KB (5.1 B per method).
- The C++ copies of the ported primitives (99 in primitive_core.cc,
  9.6 KB) stay for `NotPorted`; removing those the Rust port never
  declines needs that shown per primitive: at most 5 KB.
- Image off-heap rounded to a word instead of a 4 KB page: about 2 KB per
  image, if no VM code assumes page-aligned program-heap blocks (not
  checked exhaustively).
- Core at opt-level 2: -2.8 KB (riscv/Xtensa device_size); speed not
  measured. Opt s: -9.2 KB at 11-15 % more instructions (rejected).
- Partition layout (last resort): ota_0/ota_1 0x1a0000 -> 0x1c0000 (the
  programs partition 640 -> 384 KB) gives +59 KB of margin; the C6's
  0x1d0000 layout +125 KB. Deployed devices cannot change it over the air.

## Device builds on format 2 (branch device/format2, 2026-11-11)

The classic ESP32 and the ESP32-C6 firmware can run everything in format
2 on the core, without the C++ interpreter (three Kconfig lines; not the
default yet because the Jaguar firmware no longer fits the OTA partition;
details, tables and the other targets in docs/format2-migration.md,
"Devices").
Nothing was flashed; the ESP32 ran under Espressif's QEMU (the C6 has no
QEMU machine). Artifacts: /home/flo/work/opentoit-sandbox-artifacts/
device-format2 (README.md).

- M1 (a5915a49): verifier_v2.cc did not build for devices since the
  `--untrusted` hint (GCC 14 `-Werror=address` on the message array).
- M2 (baeca848): Kconfig `TOIT_BYTECODE_FORMAT_2` and
  `TOIT_CXX_INTERPRETER` (CMake `TOIT_CXX_INTERPRETER=OFF` drops
  interpreter_run.cc and method_entries.cc; format-1 programs refused);
  the envelope's `bytecode-formats` metadata, which `container install`
  checks.
- M3 (6aafa887): the method table as the program's last literal (in
  flash for images): the format-2 tables took 37 KB of the ESP32's heap
  at boot (80 KB free against format 1's 117 KB); now 134 KB.
- M4 (88acdaf1, 3da07458, bd80cbc7): `TOIT_TRACE_INSTALL`; format 2
  without the core is a CMake error on devices.
- M5 (4f488c84, reverted by 7c716b70): the ESP32 and C6 defaulted to
  format 2 without the C++ interpreter (and CI installed the Rust
  targets); reverted because the Jaguar firmware no longer fits the OTA
  partition (ESP32 108 KB over, C6 2 KB over).
- M6 (1ea5ca7c): `sandbox-integration` merged (no conflicts).
- Nothing changed in verified/.

Install-time verification under QEMU (f2 with `TOIT_TRACE_INSTALL`,
icount, Xtensa instructions; the images carry their table literal):

| Program | Methods | Bytecodes | Verification | Free before | Heap drop |
|---|---:|---:|---:|---:|---:|
| a-hello | 788 | 25,084 | 403.6 M | 63,968 | 23,264 |
| b-fold | 795 | 25,877 | 412.1 M | 63,936 | 23,400 |
| c-map | 973 | 31,060 | 497.2 M | 51,656 | 23,416 |
| d-string-slice | 799 | 25,705 | 413.9 M | 59,848 | 23,456 |
| e-exception | 926 | 28,493 | 451.0 M | 55,752 | 23,488 |
| f-lambda | 800 | 25,419 | 407.5 M | 63,944 | 23,272 |

Rejected: deep sleep (3.4 M, certificate rejected), no certificate,
another program's certificate (malformed), a trusted-compiled image (no
certificate), format 1 (FORMAT_2_REQUIRED). A trusted image installed
into the programs partition (Jaguar's path) runs. The heap drop is the
lowest free heap of any allocation during the verification (the whole
system), not the verifier's own peak.

Gates (1ea5ca7c, after the merge): verified/check.sh --tests passed;
ctest -j16 1198/1202 (version, reader not run; udp-reuse-port-test; the
gold of tests/negative/illegal-system-call-test was stale after
74bf3729 on `sandbox-integration` changed lib/rpc/broker.toit: updated
here, passes); nostd_check, nopanic_check and
xtensa_codegen_check (3 and z) passed (on 7c716b70; verified/ is
unchanged by this branch); firmware builds: ESP32 and C6 in f1, f2cxx,
f2 (and opt-level s), C3, S2, S3 default, the EC618 VM library.

Measurements (classic ESP32, QEMU icount; f1 = format 1/C++, f2 = format
2/core without C++): toit.bin 1,462,800 -> 1,549,952 B (C6 1,574,496 ->
1,640,400); IRAM 129,087 -> 116,947 B (13.1 KB free; C6 156,350 ->
139,998); free heap at boot 116,952 -> 133,760 B; instructions f2/f1
richards 0.720, deltablue 0.969, pystone 0.863, json 1.068, map/set
0.958, strings 0.990, GC stress 1.025, service calls 0.996. The core's
28.2 KB loop does not fit the free IRAM and, by an instruction-cache
simulation of the trace, does not need to (one miss per 16,000
instructions). Install: see below.

## Proven accessors (branch core/proven-accessors, 2026-11-11)

The raw-memory accessors of src/view.rs become verified code against an
explicit memory-ownership model (TRUSTED.md section 1, "Memory model").
Artifacts: /home/flo/work/opentoit-sandbox-artifacts/proven-accessors
(tools/: verification, codegen comparison, callgrind benchmark, census).

- P0 (trial, artifacts trial/heap_inv.rs): a field read and a field write
  through an untagged reference (`with_exposed_provenance(obj - 1)`)
  verify against a `PointsTo` taken from the heap model, with the model
  update, for 64-bit and 32-bit words (10 verified, 0 errors each).
  Design found there: the permissions live inside the view structs as
  tracked (erased) fields, the views' ghost content is defined from them,
  and a type invariant ties each permission to the address the accessor
  computes. Callers are unchanged: the contracts are the same, only
  `sid()` changed type (a pointer instead of an uninterpreted int).
  Writes go through a helper that takes a tracked mutable borrow of the
  permission field (`no_unwind`), so the invariant is checked against the
  helper's contract; whole-struct replacement (`mem::swap`) verified too
  but cost +34% code on riscv32 (stores LLVM cannot remove), and passing
  `&mut` to the field cost the register allocation of the stack view.
- P1 (stack, tables, globals): `Table` (`len`, `at`, `cursor`), `Globals`
  (`len`, `at`, `set`), `StackMem` (`len`, `slot`, `read`, `write`,
  `header`, `set_header`, `copy_within`) and `Cursor` (`offset`, `diff`,
  `read`, `write`, `byte`, `lt`) are verified. Trusted instead: the three
  derivation points (`Table::from_raw`, `Globals::from_raw`,
  `StackMem::from_stack`: `Tracked::assume_new` of the permissions, with
  their statement), the Rust semantics of `pointer::wrapping_add` and
  `wrapping_offset` (two `assume_specification`s, used instead of vstd's
  `with_addr`, which lost scaled addressing and cost 1 percent on the
  checked handlers), `global size_of u8 == 1` (compile-time checked), and
  libc memmove for `copy_within` (an FFI leaf on the permissions; the
  verified word loop, artifacts copy_words_verified_loop.rs, cost 0.9
  percent on sys:rpc). Core census: external_body 95 -> 76, unsafe 68 ->
  60 entries, uninterp 14 -> 6; plus 3 assume_new, 2
  assume_specification. Instructions (callgrind, 36 runs): all within
  0.01 percent of sandbox-integration; riscv32 opt=s text 59,332 ->
  59,346 B, run_loop 6,479 -> 6,483 instructions. One proof hint in
  rloops.rs (`fall_r`, unstable at 32 bits after the change).
- P2 (object headers, fields, elements): `Heap` owns `HeapMem`, the
  permissions of every object's header and of the fields of instances
  and the length and elements of arrays, keyed by (object id, word
  index), with the heap's exposed provenance and the model (`objs`,
  `addrs`, `class_bits`) as ghost fields. The layout is one spec
  function, `view::word_val` (header: class id and class tag; fields at
  `INSTANCE_FIELDS_WORD`; length and elements at `ARRAY_LENGTH_WORD`,
  `ARRAY_ELEMENTS_WORD`; references by `abs::enc`), the Rust side of
  CONTRACTS.toml's bridge `heap`. Tagged references: the accessor
  computes `obj - HEAP_TAG` and gets the pointer with
  `with_exposed_provenance` (the heap's `IsExposed` token), then
  `wrapping_add(k)`; the permission of word k of object id is the one at
  that pointer (`obj_ptr`), so the recomputed pointer matches by the
  invariant. Verified: `class_id`, `class_tag`, `field`, `set_field`,
  `array_length`, `element`, `set_element` (the writes update the
  permission and the model in one helper, `write_heap_word`, and call
  the write barrier, a trusted leaf without contract: the card table is
  outside every view). Trusted instead: `Heap::new` (the derivation
  point at entry; after a GC point the heap is the one the GC contract
  states) and `Heap::write_barrier`. Measured trap: reading the header
  through the generic `read_word` (`wrapping_add(0)`) cost 5 percent on
  every smi loop (the run loop's stack pointer moved between registers
  across handlers); a header read without the offset is exact. Census:
  external_body 76 -> 69, unsafe 60 -> 54, uninterp 6 -> 3.
  Instructions: all 36 runs within 0.01 percent; riscv32 text 59,348 B.
- P3 (doubles, large integers): the payload is the words from
  `DOUBLE_VALUE_WORD` (one, or two little-endian words on 32-bit
  targets: `value_word`), read as words instead of an unaligned u64
  (`read_value64`, bit-vector proofs per width). `double_bits` and
  `large_int` verified. riscv32 opt=s: run_loop 6,479 -> 5,960
  instructions, text 59,332 -> 57,498 B (the unaligned read was eight
  byte loads there); host instructions 0 to -0.4 percent.
- P4 (`array_copy`): the elements are moved by a memmove leaf stated on
  the heap permissions (`heap_memmove`); the model's new array and the
  heap invariant after the move are verified (`copy_elements`), as is
  the write barrier's condition. With P2 this completes the instance and
  array group. Instructions unchanged.
- P5 (strings, byte arrays, content views): `HeapMem` gains the half
  words of strings (length, hash code), the blob header words (external
  length and address of a string; length, tag, address of a byte array),
  the content bytes and, per object, its content pointer (`cptrs`). The
  layouts are two spec functions, `str_ok` and `ba_ok` (V5 included: an
  object with the byte-array tag is a model byte array exactly when it is
  internal or raw external at a non-null address). Verified:
  `string_len`, `string_byte`, `bytes_len`, `byte_at`, `set_byte_at`,
  `string_content`, `byte_array_content`, `string_hash_field`,
  `set_string_hash_field`, `content_at`, `content_set`, `content_copy`,
  `content_fill`, `Content::len`; `Content` carries its pointer, length,
  object and writability as (ghost) fields, and `content_ok` now also
  says that the view's pointer is the object's content pointer, which
  every accessor keeps (`cptrs()` unchanged) and allocation appends to
  (`appended`); a heap after a GC point promises nothing about it, so a
  view cannot outlive a GC point by proof, not by review. Two prims
  lemmas take the new fact (`lemma_blob_mono`, `lemma_blob_update`) and
  `new_string` ensures it: no other change in the 106 primitives. The
  memmove of `array_copy` and `content_copy` is one generic FFI leaf on
  permissions (`perm_memmove`), memset another (`perm_memset`).
  `set_string_hash_field` now ensures the model, addresses, class bits and
  content pointers unchanged instead of the whole view (its permission
  changes). Census: external_body 67 -> 53, unsafe 54 -> 40 entries,
  uninterp 3 -> 0. Instructions 0 to -0.5 percent (strings -0.25);
  riscv32 text 57,608 B.
- Totals (TRUSTED.toml, crate core, entries): 224 -> 146; external_body
  95 -> 53, unsafe 68 -> 40 (occurrences 74 -> 46), uninterp 14 -> 0,
  plain_rust_item 42 -> 42, assume_new 2 -> 6 (the four derivation
  points), assume_specification 0 -> 2 (wrapping pointer arithmetic),
  global_layout occurrences 2 -> 3 (`size_of u8`). view.rs: 125 -> 47
  entries. TRUSTED.md section 0 lists the whole residual base.
- Device library (device_size.sh, Rust library without libc, linked):
  riscv32 opt 3 81,220 -> 79,716 B, opt s 75,354 -> 73,418 B; Xtensa
  (classic ESP32) opt s 80,095 -> 77,667 B. Host instructions (callgrind,
  18 workloads x 2 configurations against sandbox-integration): between
  -0.52 and +0.01 percent.
- Gates (on 64d2812b, artifacts gates/final-*.log): verified/check.sh
  --tests: spec 940 and core 954 verified at both widths, audit exact,
  layout check, spec differential 15/15, nopanic, sandbox ctests
  123/123, red-team batteries no crash; it fails on two drifts that
  predate the branch and that sandbox-integration has since fixed in
  files this branch does not touch: CONTRACTS.toml's table of the leaf
  contracts (epoch and `needed` clauses from core/trusted-integration)
  and VeriFast's grow/grow_stack.render. ctest format 1 1198/1201
  (version, reader, udp-reuse-port-test); everything in format 2
  1197/1201 (the same and services-network-test); untrusted suite 280
  identical plus the two known differences; primitive differential 10 x
  1M identical; compare_trace --format 2 clean on the four programs;
  32-bit host sandbox 123/123; nostd, nopanic (3, s, z), xtensa codegen
  (3, z) pass; riscv32 and Xtensa device libraries link
  (device_size.sh); ASan fuzz with the launch filter, 30 minutes:
  131,438 mutants, 113,244 rejected at launch, 0 crashes.
- Shared layout facts: every layout.rs constant the heap invariant uses
  (`word_val`, `str_ok`, `ba_ok`: 21 constants) is a row of
  verified/LAYOUT.toml on branch cxx/verifast-coverage (acece1a5, the
  table both the Verus and the VeriFast models consume; checked with
  artifacts tools/layoutcheck.sh). Not in that table yet: the Stack
  header words (`STACK_*_WORD`, layout-checked by layout_check.cc), the
  card-table constants of the write barrier, and the 32-bit split of a
  double's or large integer's payload into two little-endian words
  (`view::VALUE_WORDS`, `value_word`): rows to add on the merge.

Not migrated, with the exact steps:

- Inline allocation (`alloc::bump_instance`, `bump_double`, about a
  day): make `Runtime::bump` a Verus external_body (inside `verus!`)
  that returns the address with a tracked `Map<int, PointsTo<usize>>` of
  the `size / WORD_SIZE` fresh words and ensures the allocator facts
  (word aligned, `a + size <= usize::MAX`, `a | HEAP_TAG` is no address
  of the model, outside the program heap): the trusted part shrinks to
  that statement of `SemiSpace::try_allocate`. Then a verified
  `Heap::append(&mut self, a, Tracked(words), Ghost(o))` that pushes the
  object (model, address, a dummy content pointer) and moves the
  permissions to keys `(n, k)`, proving `heap_ok` (`word_val` of the
  header needs one bit-vector lemma for `smi(c << 5 | tag)`); the
  bodies of `bump_instance`/`bump_double` write through the permissions
  (a verified loop for the null fields). Their machine-level ensures
  (`with(r).refines` of `alloc2(g, new)`) need a new lemma like
  `primitive::lemma_refines_heap` for an appended instance or double:
  `heap_model_ok` of the appended heap (fresh address, `obj_model_ok` of
  the new object), the ro facts and `prog_rel` under the address
  extension (`lemma_post_append` does this for the primitives'
  allocations but excludes instances).
- The checked loop's raw accessors (`Heap::{header, word, word64,
  set_word, byte, set_byte, half_word_at}`): they have no ghost content
  on purpose (the checked loop is plain Rust and runs only programs the
  launch did not accept; devices do not build it). Proving them means
  verifying the checked loop; until then they stay with it in section 4.
- `Preemption` (the scheduler's watermark, written by another thread:
  an atomic with no model) and `proven_unreachable` are not memory
  accessors.

## Trusted containers integrated (branch core/trusted-integration, 2026-11-11)

`experiment/trusted-fast` (0c7b1f6b) merged into `sandbox-integration`
(09a8a644): **trusted integration complete at 84cddeab** (the merge
commit; mergeable on its own). Conflicts: `V2MethodTable::compute` keeps
the out-of-memory flag of the install retry and gains
`trusted_on_verified_loop`; this file keeps both sections. Artifacts:
/home/flo/work/opentoit-sandbox-artifacts/trusted-integration.

Gates on 84cddeab: verified/check.sh --tests (spec 939, core 870 at both
widths, audit exact, no-panic check, sandbox ctests 123/123),
`cargo verus verify` (verified_core_verify); ctest format 1 1197/1200
(version, reader, udp-reuse-port-test); everything in format 2 1195/1200
(the same three, services-network-test, and bytes-allocated-test: item
M2 below); untrusted suite 280 identical plus the two known differences;
primitive differential 10 x 1M identical; compare_trace --format 2 on the
four trace programs clean; 32-bit host sandbox 123/123; nostd and
nopanic (3, s, z); xtensa_codegen_check (3 and z, with the llvm#139
differential); ESP32-C6 firmware with the core links (toit.bin 1,660,352
B), classic ESP32 too (toit.bin 1,565,120 B, iram0.text 129,087 B, 957
free); ASan fuzz with the launch filter, 20 minutes: 72,745 mutants,
62,571 rejected at launch, 0 crashes.

- M1 (13c3063e): the build output committed by mistake under
  verified/vmverify/staticlib/devsize (289 MB, 415 files) removed and
  ignored.
- M2 (07c691ee): bytes-allocated-test in format 2. Not nondeterminism: a
  real allocation, a new stack. A GC inside the external byte array's
  primitive (two GCs: the external-memory limit) shrank the task's stack
  to the room of a call at the primitive's height (`Stack::roots_do`);
  the caller's next call, from a higher point of its frame, grew it again
  (116 -> 174 words, 1,472 B), counted against the byte array. Format 1
  needs less room per call and fits. The format-2 shrink now keeps room
  for the top frame to reach the maximal height as well: 40,168 B as in
  format 1, 15/15 runs pass.
- M3 (920fb95d, a6f2abd5, 5e1411ac): request D3, the 16-byte method
  record (`entry`, a 16-bit `length`; `unused` dropped): 20 -> 16 bytes
  of RAM per method at install and per running format-2 program
  (OBLIGATIONS.md D3 has the details). richards -0.2 %, deltablue +0.1 %,
  pystone +0.2 % (trusted). Spec files touched (item e): vprog.rs
  (`VMethod`, `end_spec`/`end`), encode.rs and infer.rs (read `end()`),
  the bins toit_spec_verify, toit_vmverify_fuzz and toit_vmverify_mem.
- M4 (698017e9): size. With integration's LTO packaging the device library
  (riscv32, opt 3, Rust without libc) is 77,072 B before the fast paths
  (ea831741 + sandbox-integration) and 80,656 B at 84cddeab (+3,584).
  `step::slow` has one resume tail (`top_room_kept` is a predicate,
  `resume_with` skips the rescan): -302 B. Tried and dropped: `pop_to` and
  `ret_r` out of line (+152 B under LTO: the callers' spills grow more
  than the bodies shrink), the unchecked twins merged into their base arms
  (-376 B, but richards +7.5 % checked / +9 % trusted: the run loop's
  register allocation). After M5-M7: 81,220 B (+1,000 for the new fast
  paths), target 79,072 not reached.
- M5 (00524eb5, 9f2420df): a leaner C++ primitive call: the Stack header
  from the registers (`Machine::save_r`) instead of writing them back,
  everything but the unmoved success in `cxx_primitive_rest`,
  `leave_primitive` inline. A trivial C++ primitive with its Toit call and
  return: 242 -> 219 instructions (C++ interpreter 68). Inlining the lean
  path into the run loop reaches 180 but costs richards +1.6 %,
  deltablue +2.4 %, json +1.2 %: not taken.
- M6 (cde5ae34): calls and returns while finally records exist, on the
  registers (rfins.rs, run from `step::slow` before it syncs): RPC
  440.7 -> 425.5 M.
- M7 (99b74080): a non-local return or branch that meets a handler enters
  its finally code on the registers (`pop_to` stops at the handler,
  `enter_fin_r`): RPC 425.5 -> 412.7 M (1.200 of C++), json 1.177.
- M8 (c1b81bc7): red
  team round 3, F1. `String::read_content` assigned a literal's hash with
  `_assign_hash_code`, which asserts valid UTF-8, before the loader's
  rejection (`loaded_ok`): debug and assert-enabled ASan builds stopped
  with an assertion. Now `_assign_unvalidated_hash_code`. The reproducer
  and tests/sandbox/invalid-utf-8-literal-test.toit pass on the Debug SDK
  (build/dbg); release unchanged.
- M9 (7903b94e): `sandbox-integration` merged again (red-team rounds 1-3,
  the integer-overflow fixes, the annotated C++ pilot); no conflicts.
- M10 (ca2f56f6): the red team's batteries (66 crafted heaps, 69
  assembled methods) are parameterized (battery-env.sh: HOSTRUN, ASANRUN,
  WORK) and an optional step of `verified/check.sh --tests` against
  build/asan and build/dbg/host: 61 heap cases and 68 method cases with
  the recorded verdicts, no crash, no sanitizer report, no assertion
  (opcode 101 is LOOP_REPEAT here: rejected for crossing the method end
  instead of as a bad opcode).
- Gates on ca2f56f6 (and on 5e1411ac before the second merge, with the
  same results): verified/check.sh --tests (spec 940, core 878 at both
  widths, audit, no-panic check, sandbox ctests 123/123, batteries);
  ctest format 1 1196/1200 (version, reader, udp-reuse-port-test, and
  tls-ubuntu-test: a network timeout, marked flaky); everything in format
  2 1195/1200 (the same plus services-network-test; bytes-allocated-test
  passes); untrusted suite 280 identical plus the two known differences;
  primitive differential 10 x 1M identical; compare_trace clean; 32-bit
  sandbox 123/123; nostd, nopanic (3, s, z), xtensa_codegen_check (3, z)
  pass; ESP32-C6 (toit.bin 1,661,152 B) and classic ESP32 (1,565,936 B,
  iram0.text 129,087 B) link; ASan fuzz 20 minutes, 0 crashes: on
  ca2f56f6 120,486 mutants (103,697 rejected at launch), on 5e1411ac
  92,797 (79,822).
- Speed at the end (x86-64 instructions, ratio to the C++ interpreter;
  before -> after this branch's items): trusted richards 1.052 -> 1.050,
  deltablue 1.162 -> 1.163, pystone 1.056 -> 1.058, json 1.192 -> 1.177,
  yaml 1.200 -> 1.197, RPC 1.290 -> 1.200, strings 1.105 -> 1.107; checked
  richards 1.138 -> 1.136, json 1.212 -> 1.197, RPC 1.327 -> 1.237.
  Per operation (with the Toit call, minus the loop): C++ primitive 242 ->
  219 (C++ 68); static call and return 89 (C++ 60), virtual call 159
  (118), block call 115 (111). json/yaml are in the run loop's calls and
  returns: INVOKE_STATIC reloads spilled table bases, computes the return
  bci from the ip and loads the preemption watermark through a pointer;
  the 1.15 target was not reached.
- Install-time verifier opt level (item c; measurements in
  trusted-integration/verifier-opt/): verifier and glue at z / s / 2 / 3:
  riscv32 library 80,478 / 82,872 / 90,130 / 90,548 B, Xtensa 86,047 /
  87,775 / 94,804 / 94,437 B; Xtensa QEMU instructions of one install
  (fold, format, map, deque, list) 249/284/299/339/575 M at z, -4.0 % at
  s, -9.5 % at 2 and 3 (x86-64: z -> 3 is 1.58x fewer). Kept at z.
  Estimate (CPI 1.2-2): 30 KB programs 1.4-3.8 s at 240 MHz, 2.2-5.7 s at
  160 MHz; 65 KB 3.1-8.2 s and 4.7-12.3 s (the progress reports keep the
  dead-lock check quiet).

## Device builds (branch device/esp32-build-fixes, 2026-11-11)

Fixes for the findings of verified/XTENSA-RUST-FIXES.md. Nothing was
flashed; Xtensa code ran only under Espressif's QEMU (esp_develop_9.2.2).
Scripts, logs and data: /home/flo/work/opentoit-sandbox-artifacts/
esp32-build/ (`scripts/`; QEMU runs in `fw-qemu/`).

1. LTO for the device library (8cd79b8e). Cargo silently ignores `lto`
   for a library with the crate types `staticlib` and `rlib`, which
   verified/vmverify had: the firmware library was never LTO'd, on any
   target. The VM's library is now its own package,
   verified/vmverify/staticlib (`libtoit_rust.a`, crate type `staticlib`
   only, no code; toit_vmverify is an rlib for its tools and tests), with
   the device profile, and the glue (toit_vmverify) at opt-level z like
   the verifier: with LTO the checker is inlined into the glue, which
   would otherwise compile it for speed again (LTO alone: +0.2 % on
   RISC-V, +1.5 % on Xtensa). Confirmed: rustc gets `-C lto`, the archive
   has one object for all Rust code (plus `compiler_builtins`), whose
   bitcode holds the spec's and the core's functions. Linked size at opt 3
   (`device_size.sh`, which now also measures Xtensa: `DEVICE_SIZE_ARCH=
   xtensa`, and the old layout: `DEVICE_SIZE_LTO=false`), bytes:

   | Component | riscv32 before | riscv32 after | Xtensa before | Xtensa after |
   |---|---|---|---|---|
   | core: verified loop and cold paths | 28,314 | 27,754 | 37,182 | 35,457 |
   | core: checked-loop remnant | 788 | 790 | 536 | 523 |
   | core: primitives | 13,558 | 14,224 | 13,791 | 14,628 |
   | verifier: checker | 17,674 | 10,762 | 17,866 | 10,759 |
   | verifier: heap check | 2,228 | 266 | 2,336 | 281 |
   | spec: other | 1,832 | 1,384 | 1,620 | 1,306 |
   | glue (vmverify; with LTO the inlined checker) | 5,044 | 10,424 | 4,154 | 12,868 |
   | other core/alloc, compiler builtins | 7,620 | 7,202 | 3,819 | 3,307 |
   | Rust library total | 77,058 | 72,806 (-5.5 %) | 81,304 | 79,129 (-2.7 %) |

   (Of the saving, LTO gives 3.1 / 2.0 KB and the glue at z 1.2 / 0.2 KB:
   75,870 / 81,113 without LTO.) Firmware: the classic ESP32 with the core
   links (toit.bin 1,557,040 B); host builds are unchanged (no LTO there):
   x86-64 instructions in `toit_v2_run`, format 2, TOIT_VERIFY=1:
   richards 1,154.15 M, deltablue 910.39 M, pystone 887.07 M (before
   1,154.15 / 910.39 / 887.08 M). nopanic_check.sh (3, s, z),
   nostd_check.sh and xtensa_codegen_check.sh (3 and z, with the #139
   differential against the cached llc builds) pass.
2. IRAM of the classic ESP32 (f145fb1f). `Interpreter::run` is
   `IRAM_ATTR`, and the format-1 hardening and the checked dispatch table
   grew it by 2.9 KB: iram0_0_seg overflowed by 2,720 bytes even without
   the Rust library. The stack-overflow handling of the 28 call sites and
   the preemption of the 4 back branches are now one shared slow path each
   (they were copied into every site), the field-access checks of
   untrusted processes, the accessor lookup of their virtual getter and
   setter calls and the corrupt-stack message are out-of-line functions
   (flash). `Interpreter::run` with its literals: 16,389 -> 12,510 bytes
   on the ESP32 (master 13,507); iram0.text 129,087 B, 957 B free (was
   2,720 over). ESP32-C6: iram0.text 161,694 -> 156,350 B,
   `Interpreter::run` 19,104 -> 13,764 B. Format 1 on x86-64 (callgrind
   in `Interpreter::run`): richards 1,023.6 -> 1,024.3 M (+0.07 %),
   deltablue 650.3 -> 652.5 M (+0.35 %), pystone 761.7 -> 767.4 M
   (+0.74 %): the hot handlers are unchanged in source; the difference is
   GCC's layout and register allocation of the 12 KB function (two
   variants with `cold` or with a separate accessor call site were 0.2-1.1
   % worse; the per-handler profile shows one extra move or jump in
   INVOKE_AT, LOAD_GLOBAL_VAR, LOAD_LOCAL); wall time, minimum of 7
   interleaved runs: 10.87 / 6.67 / 7.30 -> 10.34 / 6.63 / 7.45 ms (noise).
   Ported to the upstream stack: #3365 (sandbox-1, b0696608: the shared
   slow paths; 14,590 -> 12,462 B, was 964 over) merged up through -2..-5
   and -6 without rebasing, and #3370 (sandbox-5, 6dd13420: the
   out-of-line field checks; 13,790 -> 12,394 B). The esp32 CI job passes
   on #3365, #3366, #3370 and #3371 (cross fails as before:
   `qemu-user-static` is not installable on the runner).
3. Install-time verification time (8f5a418e, 4ea27a41). Instructions of
   one install-time verification with the shipped certificate (conversion,
   heap check, proven check; `scripts/verify-ir.sh`, x86-64 callgrind):
   50-74 M for the 25-38 KB suite programs, 112 M for run-image (55 KB of
   bytecodes), 132 M for toit.run (66 KB), plus 0.25-0.56 M for the C++
   method table. On the Xtensa core (QEMU `-icount shift=0`, one
   instruction per virtual ns): 251 M (fold, 25.7 KB), 289 M (format,
   29.5 KB), 302 M (map, 30.9 KB), 505 M (deque, 32.7 KB), 582 M (list,
   37.9 KB): 5-8 times the x86-64 count (the verifier and the glue are at
   opt-level z on devices, every call is `l32r`+`callx8`). Estimate for
   real hardware (flash-cached code, CPI 1.2-2): 30 KB programs 1.3-2.5 s
   at 240 MHz and 2-6 s at 160 MHz; 65 KB programs (extrapolated
   0.65-1.05 G instructions) 3-9 s at 240 MHz and 5-13 s at 160 MHz, so
   the 10 s dead-lock check (`PROCESS_MAX_RUN_TIME_US`, scheduler.cc) can
   trip on hardware too. Design: progress reports at method boundaries,
   which keep the proof statement unchanged. `toit_spec::progress::
   verify_shipped_progress` (verified/spec/src/progress.rs, verified by
   Verus, same postcondition as `cert::verify_shipped`, whose body it
   repeats) wraps the shipped-certificate oracle so that a `Progress`
   callback runs before each method's maps are read; the VM passes a
   callback in `toit_vmverify_input` (`progress`, `progress_context`) that
   calls `Process::note_progress`, and the dead-lock check uses
   `Process::stalled_us` (time since the slice started or the last
   report, a 32-bit atomic). Trusted (TRUSTED.toml, three `unsafe`
   entries): the callback only records a time and touches nothing the
   verifier reads; CPU time and the run-time limits of policies still
   count the whole run. Not chosen: verifying a bounded number of methods
   per primitive call would split the proven loop of `check::verify`
   (its invariant carries soundness) into a resumable state machine and
   need a multi-call commit protocol in the container service; the
   scheduler thread stays busy for the verification's duration (other
   scheduler threads run; FreeRTOS preempts it as before). Tests: host,
   install-verdict-test checks one report per method on the install path
   (TOIT_VERIFY_TIME prints `progress N (to the scheduler)`); QEMU, with
   `-icount shift=6` (64 ns per instruction, so fold's and list's
   verifications take 16 and 37 s of virtual time) both install and exit
   0; the same firmware with the report disabled (control build) stops
   with "Potential dead-lock" in process 0 at primitive 27:3
   (`image.writer-commit`) for both (`fw-qemu/wdprog.summary`,
   `wdnoprog.summary`). The QEMU runs no longer need the 600 s limit of
   the investigation.
4. Install-time RAM (ac435fa3). Measured under QEMU (classic ESP32, no
   PSRAM; temporary trace patch in the artifacts: free heap and largest
   block before, the table's size, the Rust heap's high-water mark through
   the device allocator), per install: the C++ method table 16-25 KB (20
   bytes per method rounded up to pages; 28.7 KB for is-as-many-test), the
   Rust peak 9-23 KB (conversion 3-5.5 KB, the rest the maps of the
   largest method in the proven checker; 75 KB for is-as-many-test, whose
   largest method is large), together 25-44 KB, against 47-63 KB free
   (largest block 32-49 KB) when the installer runs: list, deque, format
   (verifier OUT_OF_MEMORY) and is-as-many (table calloc) failed alone.
   Most of the free heap's shortfall is Toit garbage: an allocation
   failure of the table or the verifier now returns
   `V2Verifier::OUT_OF_MEMORY`, both commit primitives fail once with
   CROSS_PROCESS_GC, and the retry runs with 117 KB free (largest block
   100 KB); a second failure is the error OUT_OF_MEMORY. Peak use is
   unchanged; all twelve install and pass alone (was 8) and in one boot
   (12/12 in the final run without the trace patch; 11/12 in a traced run,
   where is-as-many-test, which needs 103 KB, met a fragmented heap). The cheapest reduction of the peak
   itself needs the core: the 16-byte record of OBLIGATIONS.md D3 (-4 B
   per method, also for every running format-2 program); the table stored
   with the image in flash would remove it but needs a flash layout
   change; the checker's maps of a large method are the spec's
   (`ShippedOracle::decode`: 4 bytes per bytecode byte plus nodes).

Gates (final code): verified/check.sh --tests passed (spec 903, core 830
verified at both widths, audit passed, nopanic_check.sh, sandbox ctests
123/123); ctest -j16 1196/1200 (version, reader not run;
udp-reuse-port-test; tls-global-cert-simple-test timed out once and
passes alone: network); 32-bit host tests/sandbox and layout 124/124;
firmware links: classic ESP32 without and with the core (toit.bin
1,462,336 / 1,557,040 B, 957 B of IRAM left), ESP32-C6 with the core
(toit.bin 1,651,856 B); QEMU, classic ESP32, the twelve untrusted suite
tests of the investigation: 12/12 in one boot and 12/12 alone (was 9 and
8), with the stock 10 s dead-lock limit.

Still needs hardware: install time of 30-65 KB programs at 160 and 240
MHz (the estimate above), the free heap of a running system when the
installer runs, the verified core's speed from flash, the IRAM fix's
effect on format-1 speed (the shared slow paths are cold).

## Trusted containers on the core, fast (branch experiment/trusted-fast, 2026-11-11)

Experiment, not for merging without the owner's decision. Results:
EXPERIMENT-trusted.md, "Follow-up". Artifacts:
/home/flo/work/opentoit-sandbox-artifacts/trusted-fast.

- M0 (ea831741): `experiment/trusted-on-core` + `sandbox-integration`
  (time_info, provider policy, UTF-8 literal check); no conflicts.
- M1 (71941878): register fast paths for NON_LOCAL_RETURN/BRANCH, TRY,
  UNWIND (null token) and the return into a TRY (rnonlocal.rs). RPC 1.81
  -> 1.41, yaml 1.50 -> 1.26, json 1.34 -> 1.25 times C++.
- M2 (4b293c42): inline bump allocation (new trusted item) and the mask
  of unported core primitives. Allocation 258 -> 175, double boxing 215
  -> 100, C++ primitive call 293 -> 245 instructions; strings 1.11.
- M3 (814d6db7): unchecked twins instead of the mode flag (format note
  20). Checked richards/deltablue/pystone 1.139/1.242/1.132, trusted
  1.053/1.170/1.064.
- M4 (76231ced): room facts (`room_ok` without the records for every
  frame, `resume_kept`) and the UNWIND resume of a non-local return or
  branch. RPC 1.30, json 1.20, yaml 1.20.
- M5 (10ae6b02): the range of `needed` in the stack-growth contract on both
  sides (review finding); two proofs stabilized for `cargo verus`. Gate
  green at every milestone; final heavy gates in EXPERIMENT-trusted.md
  (f1 1197/1200, format 2 1196/1200, untrusted suite 280 + 2 known,
  primitive differential 10M identical, compare_trace clean, 32-bit
  sandbox 123/123, ASan fuzz 30 min 0 crashes).

## Trusted containers on the core (branch experiment/trusted-on-core, 2026-11-11)

Experiment, not for merging without the owner's decision. Results:
EXPERIMENT-trusted.md. Artifacts:
/home/flo/work/opentoit-sandbox-artifacts/trusted-on-core.

- M0 (248837ae): `proposal/builtins` merged with `sandbox-integration`. In
  check.rs the built-ins' rules were ported to the fallible, panic-free
  style. Gate green (spec 917, core 846 at both widths).
- M1 (67d7003e): trusted format-2 programs run on the verified loop
  (`TOIT_V2_TRUSTED`, `Accepted::trusted_program`), and
  `TOIT_SYSTEM_FORMAT2` builds the system snapshots in format 2. Hello
  world runs with a format-2 system process. The whole suite in format 2
  passes 1192/1197 (format 1: 1194/1197).
- M2 (f88ecf1d): cheap C++ calls. `toit_v2_primitive` and the heap epoch
  complete PRIMITIVE, ALLOCATE and double boxing on the registers when
  nothing moved. A C++ primitive call costs 293 instructions instead of
  676 (the C++ interpreter: 68).
- M2 also adds the unchecked mode of trusted programs
  (`Program2::unchecked`, `step::trusted_field_accesses`): richards,
  deltablue and pystone run at 1.11 / 1.21 / 1.10 times C++. Gate green
  (spec 917, core 850, both widths, audit, sandbox ctests 121/121). Suite
  again 1192/1197.
- Open items, measured: the machine slow paths and the room rescan cost
  13-22% of yaml and RPC; an unsound prototype without the rescan reached
  1.17-1.43x on system workloads. Also open: inline allocation, and twin
  opcodes instead of the mode flag (the flag costs +2.2% on richards for
  checked code). EXPERIMENT-trusted.md has the list for "format 2 only".

## Panic-free device library, primitive size (branch device/panic-free, 2026-11-11)

Size and robustness work on the device-side Rust code (verified/vmverify/
README.md, "No panics on devices" and "Device size"; artifacts
/home/flo/work/opentoit-sandbox-artifacts/panic-free: `devsize.sh`,
`callers.sh` (callers of the panic machinery in the linked map),
`ir.sh`, `fw.sh`).

1. No panic paths (fd9be491). The device library linked core::panicking
   and core::fmt only through the verifier: bounds checks of exec indexing
   in the checker, the heap check and `x_info` (and the opt-z checker's
   out-of-line `Vec::index`, which no call site can elide), vstd's
   `Vec::set` and `slice_subrange`, and infallible allocation
   (`handle_alloc_error` aborted the VM). Now `toit_spec::xvec` holds the
   trusted accessors (`ix`, `ix_ref`, `vix`, `vput`, `subslice`:
   `get_unchecked` under a precondition Verus proves at every call site)
   and fallible growth (`try_push`, `try_with_capacity`, `try_copy`,
   `try_filled`); the checker's allocating functions return
   `Result<_, Oom>` (exact for `Ok`, spec/SOUNDNESS.md), the decoder
   `Dec::Bad`/`Dec::Oom`, the conversion `Malformed::oom`; the verdict is
   OUT_OF_MEMORY (code 8). In the core only `prims::blob::apply_ranges`
   had a check, at opt s/z (index masked). `vmverify/tests/nopanic_check.sh`
   (in check.sh --tests) fails if any panic or formatting symbol is linked;
   it passes at opt 3, s and z. 17 new TRUSTED.toml entries (the 9 xvec
   functions and their unsafe blocks).
2. Primitives: `int_arg`, `double_arg` and `num_arg` out of line (one copy
   each instead of one per primitive: -1.0 KB; the other argument
   decoders are smaller inline), and `fp::compare_numbers` delegates the
   mixed int/double case to the spec's `compare_mixed_impl`, which the run
   loop's comparisons already link (the two were the same code: -0.6 KB).
   Not kept: a table-driven integer dispatch (one call site for the 22
   binary, 10 comparison and 6 unary integer primitives, the operation
   from a byte table: proven, -1.0 KB more) changed the register
   allocation of the run loop: +1.2 / +1.1 / +2.2 percent instructions
   (richards, deltablue, pystone), also with the family dispatch out of
   line; the float and blob families gained nothing (LLVM already merges
   their arms). The split into a crate compiled at opt-level s (stable
   Rust has no per-function `optimize`) is not done: the primitives use
   the core's views, heap model and allocator, and the run loop's
   PRIMITIVE handler calls them, so the split means three crates (base:
   layout, abs, view, exec, ffi; prims; loop) in the Verus import chain,
   the TRUSTED.toml paths of view.rs and ffi.rs moved, and a conflict with
   every branch that touches the core (about 2-3 KB: the primitives are
   13.4 KB at s, 12.4 KB at z). Policy check: all 106 Rust primitives are
   in the reduced untrusted policy (src/primitive_policy.cc); none removed.
3. Other candidates: the double-arithmetic out-of-memory fallback
   (`rops::arith_double`, about 0.6 KB) needs a new `step::Slow` request
   and its proof (not done); jump tables stay 32-bit (LLVM has no
   compressed jump tables on RISC-V; the run loop's opcode and primitive
   dispatch tables are its 2.3 KB of rodata, and a byte-table dispatch of
   the primitives is the change rejected in 2 for speed), and
   `exec_opcode_length2` as a match became a 4-byte table (+0.2 KB,
   reverted).

Device library (riscv32imac, core opt 3, verifier opt z; device_size.sh),
bytes:

| Component | before (sandbox-integration) | after |
|---|---|---|
| core: verified loop and cold paths | 28,056 | 28,314 |
| core: checked-loop remnant | 788 | 788 |
| core: primitives | 15,458 | 13,558 |
| verifier: checker | 17,674 | 17,662 |
| verifier: heap check | 1,894 | 1,982 |
| spec: other (float helpers, xvec) | 1,076 | 1,832 |
| glue (vmverify) | 4,670 | 4,958 |
| Rust formatting and panics | 1,596 | 0 |
| other core/alloc, compiler builtins | 9,404 | 7,620 |
| attributed Rust total | 80,616 | 76,612 |
| linked .text / .rodata / .eh_frame | 90,630 / 11,260 / 1,720 | 87,654 / 3,524 / 1,168 |
| linked total (with 12.4 KB newlib and the C stubs) | 103,610 | 92,346 (-11.0 KB) |

(.rodata: the panic locations and the formatting tables, 7.2 KB, were
not attributed to a component; the conversion's error texts, 0.6 KB, are
now hosts only.) ESP32-C6 firmware (built, never flashed): toit.bin
1,669,344 -> 1,658,656 B (-10.4 KB: flash.text -3.0 KB, flash.rodata
-7.7 KB).

x86-64 instructions inside `toit_v2_run` (callgrind, TOIT_VERIFY=1, the
core-size snapshots): richards 1,154 M (was 1,158 M), deltablue 910 M
(913 M), pystone 887 M (889 M).

Gates (final code): verified/check.sh --tests (spec 895, core 830
verified at both widths, audit passed, nopanic_check.sh, sandbox ctests
121/121), ctest -j16 1194/1197 (version, reader not run;
udp-reuse-port-test), untrusted suite 280 identical + the two known
differences, prim_diff.sh 10 x 1,000,000 identical, vmverify certificate
fuzz with failing allocations 8 x 15 minutes (README.md, "No panics on
devices": 0 panics, 0 aborts), core_fuzz.toit --filter launch on ASan 20
minutes (seed 51: 69,897 mutants, 9,799 accepted and run, 0 crashes;
under load from the other gates), 32-bit host tests/sandbox
and layout 122/122, nostd_check.sh.

## Size diet of the interpreter (branch core/size-diet, 2026-11-11)

Size and speed work on the verified run loop, keeping every proof
(DESIGN.md section 2a, "One body per opcode" and "Finally records in the
register loop"; section 8, "Size diet"). Nothing was assumed or
admitted; the allowlist went from 299 groups / 309 occurrences to 298 /
307 (gone: `settle`'s loop without decreases clause and the two unsafe
moves of `cold!`; new: `view::Cursor::lt`, a pointer comparison).
Scripts and raw numbers: /home/flo/work/opentoit-sandbox-artifacts/
core-size (`devsize.sh`, `ir.sh`, `attr.sh`, `ir/results.txt`,
`devsize/`).

Steps (callgrind Ir inside `toit_v2_run`, TOIT_VERIFY=1, x86-64; device
size: "verified loop and cold paths" of verified/vmverify/tests/
device_size.sh, riscv32imac, opt 3):

| Step | richards | deltablue | pystone | device KB |
|---|---|---|---|---|
| before (sandbox-integration 05c1664b) | 1,234 M | 952 M | 940 M | 54.3 |
| finally records in the register loop (gate in the machine), cold paths take the machine by reference | 1,206 M | 928 M | 909 M | 54.3 |
| one body per opcode: `step::slow`, the machine's step and the bridge gone; top-frame room with finally records, a record of slack per call | 1,212 M | 939 M | 915 M | 31.5 |
| field checks instance-first, program-heap test as one compare, `-Xpreempt_a_lot` only in debug builds | 1,167 M | 925 M | 898 M | 31.5 |
| the top frame's method read from its frame record | 1,158 M (1.13) | 915 M (1.41) | 891 M (1.17) | 31.2 |

(C++ format 1 -O3: 1,023 M / 650 M / 762 M.)

1. Finally records in the register loop (37c75bbb). The register loop
   ran only without finally records, and `step::settle` ran finally code
   on the machine's step over all opcodes (`step_m`), which therefore had
   to stay complete. Now the registers hold the frame top, and the
   machine holds a gate (`regs::gate_ok`): the record words `fw`, the
   room a call's fast path needs (`need`, all ones with records: the call
   fails its existing room check `free >= (watermark | need)`) and the
   lowest frame top of a return's fast path (`bot`, the end of the array
   with records: one pointer compare, `view::Cursor::lt`, which is also
   the bottom-frame test and costs one instruction less than before).
   Calls and returns that would move records run on the machine; nothing
   else looks at them. LOAD_SMIS_0 lost its room check (the next state is
   well formed, `room::lemma_room_next`).
2. `cold!` (6906bbb7) moved the whole machine by value into the C++
   trampolines and back (memcpy once the machine grew by three words);
   it now passes a reference: -2 to -3 percent instructions, and two
   unsafe blocks fewer.
3. One body per opcode (79be90bf, deletions in the following commit).
   Every bridge site calls `step::slow` (out of line, one copy) with a
   `step::Slow` request: a raise of a given kind (one copy of each message
   builder), a call (growth, preemption, records), a return (bottom frame,
   TRY, records), a C++ primitive (`primitive::op_primitive_cxx`, the Rust
   ports run on the registers only) or the machine handler of a rare
   opcode (`step::machine_op`: lazy globals, tail calls, INVOKE_BLOCK,
   unwinding, TRY, HALT). The machine's step (`step_m`, 25 KB) and 45
   machine handlers that duplicated the register handlers are gone
   (883 -> 836 verified items). Found by the untrusted suite:
   tests/regress/issue1027-test.toit (finally code after a stack overflow
   at the maximal stack length) stopped with LIMIT, because the room of
   every frame with the new record counted did not exist; with finally
   records the room is now the top frame's only (`room::room_ok`), and a
   call keeps one finally record of slack.
4. Speed items against the prototype: LOAD/STORE_FIELD test the instance
   tag first (task objects on a cold branch, `Machine::task_field_ok`);
   the program-heap test is one compare (`w - ro_start < ro_size`
   wrapping; the range is checked once per run, `exec::ro_ok`); the
   `-Xpreempt_a_lot` test at POP is compiled only with the `preempt-a-lot`
   feature (CMake: debug VM builds, as the C++ flag; Verus verifies with
   it); the top frame's method is read from its frame record
   (`Machine::with`), so calls, returns and tail calls store no method
   into the machine.
5. Shared copies of the machine's cold code: `Machine::do_unwind`,
   `push_call` and `do_return` out of line (they were inlined into every
   raise, every slow path and the PRIMITIVE handler): -3.2 KB, no change in
   speed.

Milestones (gates: verified/check.sh --tests at both widths, ctest -j16
1161/1164 with the known version/reader/udp-reuse-port-test, untrusted
suite 280 identical + the two known differences, prim_diff.sh 10 x
1,000,000 identical, compare_trace.toit --format 2 2,053,625 steps without
divergence, core_fuzz.toit --filter launch on ASan 30 minutes without a
crash, 32-bit host tests/sandbox 95/95, device library links):

Device configuration and next size candidates: DESIGN.md section 8 ("Size
diet": opt 3 with tail duplication stays the best trade-off; opt s saves
4.1 KB for 11-15 percent more instructions). What is left of the
interpreter on devices (opt 3): the loop 20.0 KB (of which about 4 KB the
inlined primitive dispatch, which costs 1-5 percent when taken out of
line), its cold paths 8.1 KB, the Rust primitives 15.5 KB. Candidates:
the primitives' argument decoding and failure results (shared code, or opt
s for them alone, which needs them in a crate of their own: about 2-3 KB),
the double-arithmetic out-of-memory fallback through the register virtual
call (0.6 KB), and, outside the core, the verifier's run-time bounds
checks (Vec indexing in toit_spec's checker and vmverify's conversion):
they are the only panic paths left and pull in core::fmt and 5.5 KB of
panic-location strings (about 7 KB). The core itself has no panic path
(no call of core::panicking from toit_verified_core in the linked
library).

- M1 (385b9469): items 1-4. Gates as listed (fuzz seed 31: 86,722
  mutants, 12,466 accepted and run, 0 crashes; check.sh: spec 892, core
  837 verified at both widths, audit passed).
- M2 (ed164a6b plus documentation): item 5, DESIGN.md section 8. Gates as
  listed (fuzz seed 41: 169,490 mutants, 23,869 accepted and run, 0
  crashes; ctest 1161/1164; check.sh: spec 892, core 837 at both widths,
  307 occurrences in 298 groups; nostd_check.sh for riscv32imac and
  riscv64imac). Wall time: DESIGN.md section 8.

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
| total | 106 of the 143 allowed (141 core + 2 bitmap) | 45 |

Stays in C++ (37, contracts written down in TRUSTED.md section 8): task
and message plumbing, process_send, time/clock/random, finalizers,
encode_error, main/spawn arguments, platform queries, the formatting and
parsing primitives (int_parse, float_parse, *_to_string, float_round,
UTF-16, UTF-8 validation, crc), bitmap blit/byte_zap.

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
