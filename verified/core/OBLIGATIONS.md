# Proof obligations of the verified core

What is proven about the core today, and what is left for the proof half of
Phase 4. "Proven" means: Verus, zero `assume`/`admit`, with only the
trusted items of TRUSTED.md and verified/TRUSTED.toml. Run
`verified/check.sh` (the merge gate) to reproduce.

Current result: `core 128 verified, 0 errors` (Verus 0.2026.11.02, about
1.4 s wall). See DESIGN.md for the run loop the obligations refer to.

## 1. What is proven now

The handlers in the `verus!` part of `src/exec.rs` carry functional
contracts over the object-stack words (`Machine::words()`, bottom first)
and the machine invariant `stack_ok` (`ftop <= top <= lim <= len`,
`lim == len - base`, `len < 2^20`). For each handler: the run-time check
that corresponds to the spec's stuck condition, and the exact new word
sequence, bci and globals when it continues. They are word-level
transcriptions of the spec functions of the same name in
verified/spec/src/v2/spec.rs; memory safety (every index in bounds) follows
from the view contracts.

| Family | Opcodes | Handler(s) | Status |
|---|---|---|---|
| stack | POP, POP_1 | `op_pop` | functional contract proven |
| locals | LOAD_LOCAL(_WIDE), LOAD_LOCAL_0..5, POP_LOAD_LOCAL, STORE_LOCAL, STORE_LOCAL_POP | `op_load_local`, `op_pop_load_local`, `op_store_local`, `op_store_local_pop` | proven |
| constants | LOAD_LITERAL(_WIDE), LOAD_NULL, LOAD_SMI_0/1/U8/U16/U32, LOAD_SMIS_0, LOAD_METHOD | `op_load_literal`, `op_load_smis_0`, `push_next` | proven (the smi encoding of the pushed value is computed in `machine.rs`) |
| globals | LOAD_GLOBAL_VAR(_WIDE), STORE_GLOBAL_VAR(_WIDE) | `op_load_global`, `op_store_global` | proven |
| branches | BRANCH*, BRANCH_BACK* | `op_branch` | proven (target in the method, condition popped, `branch_taken`) |
| helpers | | `push`, `put`, `drop`, `at`, `has_slot`, `binary_result` | proven |

Not yet a refinement proof: the contracts talk about words, not about
`State2`. Closing the gap is obligation R below.

## 2. Open obligations

### R. Refinement to `spec::step` (all families)

State the abstraction function `abs(p, m, heap) -> State2` and prove, per
handler, `abs(after) == spec::step(pview(p), abs(before))` (or the matching
`Outcome2`). Needed pieces:

- R1 value abstraction: a word is a smi, a program-heap or process-heap
  object (ghost map address -> heap index), or a block reference. Block
  references are smis in the implementation (`frame << 20 | slot`) but
  `Value::Block(h)` in the spec, so the abstraction needs a ghost map from
  object-stack slots to their kind. The spec's block payload is a height;
  the implementation's is (frame, slot): the map is `h = slot + 1`.
- R2 frames: frame records `mem[0..ftop]` (method, ret, base, handler) to
  `frames` and `tries` (at most one handler per frame in the
  implementation; the spec allows a stack of handlers but TRY always
  opens a new frame, so the abstraction is injective).
- R3 the cached frame fields (`base`, `lim`, `method`, `mend`, `mfast`)
  equal the decoded top frame (an invariant of `Machine`).
- R4 instruction decoding: `dispatch` reads the same operands as
  `spec::step` (the fast-path check `bci < mfast` implies the instruction
  ends inside the method).

### Per-family status of the handlers in `src/machine.rs` (not verified)

Every stuck state of the spec is a run-time check that terminates the
process (`Ctl::Stuck`), so these handlers are memory safe by construction
only to the extent that their checks are right; that is what the
obligations below would prove.

| Family | Opcodes | Reason not yet verified |
|---|---|---|
| B1 blocks | NON_LOCAL_RETURN, NON_LOCAL_BRANCH; INVOKE_BLOCK's CODE_INVOCATION_FAILED path | unwinding over frames (`spec::unwind`); raising allocates. LOAD_BLOCK, LOAD_OUTER, STORE_OUTER, LOAD_OUTER_BLOCK and INVOKE_BLOCK are verified (src/blocks.rs) |
| F1 fields | LOAD_FIELD(_WIDE), LOAD_FIELD_LOCAL, POP_LOAD_FIELD_LOCAL, STORE_FIELD(_WIDE/_POP), LOAD_FIELD_THIS, STORE_FIELD_THIS | needs a heap view with a contract (`Heap` is a raw view today): object header, class id, field count, program-heap range, write barrier |
| C1 calls | INVOKE_STATIC(_TAIL), INVOKE_VIRTUAL(_WIDE/_GET/_SET), INVOKE_LAMBDA_TAIL, INVOKE_INITIALIZER_TAIL, RETURN, RETURN_NULL | needs R2/R3; `call`, `replace_frame`, `return_from` and the preemption point |
| T1 try/unwind | TRY, UNWIND, THROW | needs R2 and the heap (the token is a 5-element array); `unwind` is a loop over frames, `enter_finally` allocates |
| Y1 type checks | AS_*, AS_LOCAL raising AS_CHECK_FAILED | the checks and the IS_*/AS_* successes are verified (`src/types.rs`); the failing AS path goes through `step_unverified`: needs `raise` (allocates the exception, then `unwind`, see T1/A1) |
| O1 operators | INVOKE_EQ..INVOKE_SIZE, IDENTICAL | smi fast paths of INVOKE_EQ..INVOKE_MOD and IDENTICAL proven (src/ops.rs); left: INVOKE_AT, INVOKE_AT_PUT, INVOKE_SIZE, and the other paths (doubles, which allocate; large integers; `compare_numbers`, i.e. `spec_helpers::compare_mixed`, uninterpreted in the spec; IDENTICAL of distinct heap objects; the virtual-call fallback) |
| A1 allocation | ALLOCATE(_WIDE) | GC point (see G below) |
| P1 primitives | PRIMITIVE | calls C++ (see FFI in DESIGN.md); P2 below |
| H1 halt | HALT 1 raising INVALID_PROGRAM | HALT 0 (yield), 1 (exit), 2 (deep sleep), 3 (reset) are verified (src/halt.rs); a heap object as exit value goes through `step_unverified`: needs `raise` (see Y1) |
| G1 globals (lazy, dynamic) | LOAD_GLOBAL_VAR_LAZY(_WIDE); the INVALID_PROGRAM raise of LOAD/STORE_GLOBAL_VAR_DYNAMIC | the dynamic fast paths are verified (src/globals.rs); the raise needs `raise` (see Y1); the lazy load calls the initializer entry point (C1) |

### G. GC safety

The rule: no object reference read before a call that may GC is used
after it. Today it holds by construction for the views and by review for
the words:

- By construction (type system): every `Runtime` function that may GC
  takes the only `StackMem` view by `&mut` and replaces it with a fresh
  view of the (possibly moved) current stack; the `Machine` re-derives its
  cached fields (`reload`) right after. No raw stack pointer survives.
- By review: object references held in Rust locals across a GC point.
  The audited places are `enter_finally` (value and payload are pushed on
  the object stack before the token allocation and re-read after),
  `raise_value_msg` (the value is a program-heap string, which does not
  move; the message words are consumed by C++ before its first GC point),
  `op_invoke_arith_slow` (no reference is used after `alloc_double`), and
  `op_primitive` (the result comes back from C++ after the GC).
- G1 (open): make it a proof: give `Heap` a ghost epoch that every may-GC
  call increments, tag every word read from the heap or the stack with the
  epoch it was read in, and require the current epoch for every use.

### Obligations from Phase 3 (verified/spec/SOUNDNESS.md)

- S1 primitives: every allowed primitive satisfies `prim_heap_ok` and has
  the arity of verified/spec/src/v2/prim_arity.rs. Open: the core calls
  the C++ primitive table (`toit_v2_call_primitive`); none of the allowed
  primitives is ported to Rust yet (DESIGN.md, open work). The arity is
  checked at run time against the C++ `PrimitiveEntry::arity` only.
- S2 loader: the loader establishes `loaded_ok`. Open: the C++ loader
  (`V2MethodTable::compute`, src/interpreter_v2.cc) checks the method
  table, dispatch entries, receiver ranges, this-field indices, branch
  targets and terminators; the heap part of `loaded_ok` is checked only by
  the unverified verified/spec/src/interp/heap_check.rs (not run by the
  VM). Untrusted launches do not yet run `check::verify` in the VM.
- S3 size bound `small`: enforced at run time as a defined
  out-of-memory outcome. Partly: heap allocation failures throw
  `OUT_OF_MEMORY` (C++ heap limits); the object stack is bounded by
  `Stack::max_length() < 2^20` (stack overflow exception); globals are
  fixed. Not shown that these bounds imply `small`.
- E2E (stated, not proven): `obligations::end_to_end_no_fatal` in
  `src/obligations.rs`: for an accepted and loaded program, every
  reachable machine state takes a step that is not stuck. It is an
  `external_body` proof function with uninterpreted placeholders for the
  spec predicates (the core crate cannot import the spec crate while the
  gate runs Verus per crate); nothing uses it as an axiom. Proof plan:
  `theorem_soundness` plus R.

### Other open items

- P2 the handlers' checks that the verifier makes redundant (for example
  the receiver check of LOAD_FIELD_THIS) stay as run-time checks until
  untrusted launches run the verified verifier (S2).
- The `cold!` trampoline (`ptr::read`/`ptr::write` of the machine) is
  trusted; it is small and listed in TRUSTED.toml.
