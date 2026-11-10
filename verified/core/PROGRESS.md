# Phase 4a progress (verified core, format 2 on x86-64)

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
  functional contracts (124 verified, 0 errors); `verified/check.sh`
  passes; the end-to-end obligation is stated (unproven).
- Layout check covers every constant the core assumes (237 + behavioral).
- Fuzz harness (verified/core/fuzz) with `toit_spec_verify` as filter and
  an ASan build (build/asan).

## In progress / next

1. Performance: the core executes 3.5-4x the instructions of the C++
   interpreter on the benchmarks (1.6-1.9x wall time). Next: keep `top`
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
5. Spec change request R1 (unwinding without a heap token).

## Known failures with the whole suite in format 2

(`TOIT_BYTECODE_FORMAT=2 ctest`, not an exit criterion any more)

- channel-retention-test, services-resource-close-pressure-test: the
  unwinding token of note 4 (PHASE4-REQUESTS.md R1).
- profiler/basic-test, profiler/lambda-test: format 1's
  `SmallInteger.repeat` intrinsic makes `repeat` invisible in profiles;
  in format 2 it is ordinary bytecode and shows up.
- version, reader, udp-reuse-port-test: environmental, as in format 1.
