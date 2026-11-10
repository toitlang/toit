# Phase 4a progress (verified core, format 2 on x86-64)

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
trusted base: TRUSTED.md section 7). Entry point `prims::call(module,
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

Stays in C++ (48, contracts written down in TRUSTED.md section 7): task
and message plumbing, process_send, time/clock/random, finalizers,
encode_object/error, main/spawn arguments, SDK info, the formatting and
parsing primitives (int_parse, float_parse, *_to_string, float_round,
UTF-16, UTF-8 validation, crc), external byte arrays, bitmap blit/byte_zap.

Wiring: a temporary one-line hook in `machine.rs` (`op_primitive_cold`
calls `prims::bridge::bridge` instead of `Runtime::call_primitive`),
opt-in with `TOIT_V2_RUST_PRIMITIVES=1`; the bridge runs the Rust port
only where the policy resolved the VM's own primitive. The verified
PRIMITIVE handler (core/refinement-2) is to call `prims::call` directly.

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
  `memcpy` (VM-BUGS.md); and one compiler-dependent NaN payload
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
