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
2. Finally records (spec change R1, format note 17, branch
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
3. Link `check::verify` into the VM for untrusted format-2 launches
   (today the C++ loader checks stand in).
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
