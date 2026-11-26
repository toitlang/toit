# Changes to the format-2 specification

One entry per change of `src/v2/spec.rs`, `src/v2/prim.rs`, `src/v2/types.rs`
or the verifier's rules (`src/v2/verifier.rs`) that an implementation of
the spec (the verified core, the VM's loader) must follow. Newest first.

## 2026-11-26: resource failures at TRY run the finally code (format 3, step 3)

What (note 23, "Resource failures at TRY"): `prim::resource_throw` at a
TRY starts in `prim::resource_state(p, s)`, the try block's entry (the
state `op_try` enters), instead of in `s`: the out-of-memory error thrown
and the stack-overflow error raised when the stack cannot grow for the try
block unwind into the TRY's own finally code. Every other instruction is
unchanged. Language level: a resource failure never skips a finally whose
try was reached (`sound_resource::lemma_try_resource_finally`).

Why: the idiom `acquire; try: ... finally: release` leaked the state when
the failure landed on the TRY (a monitor lock at the heap quota, artifacts
quota-livelock); format 1 runs the finally code there.

Implementations: the core's `unwind::op_try`/`try_grow` and the checked
loop's `try_grow_cold` enter the try block's frame before raising; the
room check of TRY includes the block reference.

## 2026-11-26: TRY as a flagged block call, tokens in slots (format 3, step 3)

What (note 23): the image tag is `TBC3`. TRY calls its try block with
the handler flag in the new frame; returning from a try block, or
unwinding past it, enters the finally code of the frame below at the try
block's return bci with the object stack cut to its base. The finally
code has four slots: the value, two token words, the reason.

* `types.rs`: `Frame::handler`; `Value::Token(second, pending, frame,
  height)`; `Pending` replaces `Resume`; `Handler` and `Fin` are gone;
  `Body::Stack2(stack, frames, bci)`.
* `v2/types.rs`: `State2` has no `tries` and no `fins`.
* `spec.rs`: `op_try` (raises in the TRY's own state, then `try_call`),
  `return_from`, `unwind` (target first, then a try block's finally
  code), `enter_finally(s, h, bci, u)`, `pop_frame`, `replace_frame` (keeps
  the flag), `op_unwind` (`token_at`: both words of one token of the
  frame made for the UNWIND's height, else `Stuck(NotUnwind)`).
  `has_handler`, `cut_fins`, `fins_popped`, `fin_matches`, `resume_of`
  and `unwind_of` are gone.
* `prim.rs`: task switching saves and restores no handlers or records;
  `plain_args` excludes tokens like block references.
* `verifier.rs`: TRY pushes `[Val, Token, Token, Val]`; UNWIND requires
  `Token` at 1 and 2 and a value at 3 and pops four.
* An implementation must keep a try block's flag in its frame record and
  the token words in the finally code's slots (the core does, verified:
  `abs::token_a`, `token_b`; C++ only copies the frame records).

## 2026-11-26: short branches (format 3, step 1)

What (note 22): opcodes BRANCH_S (114), BRANCH_IF_TRUE_S (115),
BRANCH_IF_FALSE_S (116), BRANCH_IF_NOT_NULL_S (117) and BRANCH_BACK_S (118),
two bytes each (opcode, one-byte distance); `OPCODE_COUNT2` is 119.

* `spec.rs` `step`: the forward short branches are `op_branch(kind, bci +
  b1)`, stuck on `b1 == 0`; BRANCH_BACK_S is `op_branch(0, bci - b1)`.
* `verifier.rs`: `is_branch`, `is_terminator`, `branch_kind`, `post` and
  `terminator_ok` learn the short forms (`is_short_branch`,
  `is_fwd_branch`, `is_uncond_branch`, `is_cond_branch`); `instr_ok`
  checks the target at `branch_target` with the distance `branch_dist`.
  Programs without the new opcodes are accepted exactly as before; the
  theorem is unchanged.
* An implementation must decode the five opcodes (the core does, verified;
  `V2_OPCODE_LENGTHS`; the disassembler and the assembler).

## 2026-11-11 (branch experiment/trusted-fast only, not decided): unchecked twins

What (note 20): opcodes 104..113, the unchecked twins of the field
accesses; `OPCODE_COUNT2` is 114.

* `bytecodes.rs`: `is_twin`, `base_op`, the lengths and names.
* `spec.rs`: `step` dispatches on `base_op`; `unchecked_fail` and the
  accessor fast paths test `twin_at` (the opcode) instead of
  `Program2::unchecked` (the mode now only allows the twins).
* `verifier.rs`: `op_of` is `base_op` of the byte; `instr_ok` requires a
  twin only in the unchecked mode. `prim.rs`: `grows_stack` and
  `resource_throw` of a twin are its base's. `sound.rs`: `cur_op` is
  `base_op` of the byte. Programs without twins are accepted exactly as
  before; the theorem is unchanged.

## 2026-11-11 (branch proposal/builtins only, not decided): three built-ins

What (note 19): opcodes LOOP_REPEAT (101, 4 bytes), LOOP_ARRAY (102, 4
bytes) and HASH_FIND (103, 5 bytes); `OPCODE_COUNT2` is 104.

* `spec.rs`: `op_loop_repeat`, `op_loop_array` (with `loop_slots_ok`,
  `loop_taken`, `loop_array_go`), `op_hash_find` (with `Probe`,
  `hf_at`, `is_tombstone`, `hf_probe`, `hf_find`, `HF_FULL`,
  `HF_IRREGULAR`, `HF_MAX_INDEX`); `step` dispatches them.
* `verifier.rs`: `post` and `instr_ok` learn `is_loop`/`loop_ok`/
  `loop_kinds`/`loop_operands` (fall-through: the top popped; target of
  the backward branch: `loop_kinds`) and `hf_ok`/`hf_kinds` (fall-through:
  `hf_kinds`; forward miss target: the kinds plus a value). `accepts` is
  otherwise unchanged; programs without the opcodes are accepted exactly
  as before.
* An implementation must handle the three opcodes (the core does, verified;
  the VM's loader tables `V2_OPCODE_LENGTHS`; the disassembler).

## 2026-11-11: shipped certificates; the global part as byte tables

What (`src/v2/check.rs`, new `src/v2/cert.rs`; note 18): `accepts`, the
rules and the theorem are unchanged.

* `check::XGlobal<'a>` borrows byte tables (method words, context,
  selector and pin records, a node table; format/18) instead of owning
  vectors; it holds the method table (`methods`) and borrows the
  primitive table (`prim_arity: &[Vec<u8>]`). Its view is the same
  `GCert`. `check::verify` returns `g_ok(g) && split_ok(...)` (`g_ok`:
  selector records and pins sorted; was `pins_sorted`).
* `MapOracle::method_maps(&mut self, p, g, m)` gets the program and the
  global part, with `requires wf_program2(vview(p)), g_ok(g), m <
  p.methods.len(), g.n == p.methods.len()`.
* `x_post` and `x_sel_ok` require `g_ok(c.g)`; `x_ctx_of` returns an
  `XCtx` head (the kinds are `x_fchain(g.nodes, top)`), `x_ctx_kinds`
  an owned list.
* The VM: `toit_vmverify_input` has `certificate`/`certificate_length`
  (null: infer on hosts, reject without the `infer` feature); result codes
  `CERTIFICATE` (6) and `NO_CERTIFICATE` (7); `snapshot.launch` takes a
  sixth argument (the certificate or null; primitive table regenerated).

## 2026-11-11: per-primitive contracts in prim_spec; array_at_put order; block arguments

What (`src/v2/prim.rs`, `src/v2/prim_core.rs`, `src/v2/sound_prim_spec.rs`):

* `prim_refined`'s `else` branch for the core module is
  `prim_core::core_contract` (the per-primitive contracts of the primitives
  the verified core ports to Rust), so every one of them is part of
  `prim_spec`: the Rust ports are proven against it, and a C++ primitive
  the core calls must satisfy it (the core's leaf contract).
* `array_at_put_spec` follows the C++ decoding order (`ARGS(Array, int,
  Object)`, then the checks): for a smi index in the 32-bit range a
  program-heap array fails with PERMISSION_DENIED, then the bounds; an
  index that is not an `int` is left to the default contract (C++ fails it
  while decoding, before the program-heap check). Before, the program-heap
  check came first, which C++ does not do (the primitives proof carried
  the difference as `at_put_gap`). New satisfiability lemma
  `lemma_array_at_put_ro_spec`.
* `prim_spec` applies `prim_refined` only to arguments without block
  references (`plain_args`). A primitive method may have block parameters
  (`int.parse`'s `--if-error`; `int_parse` takes it as an ignored `int`),
  and the verifier allows that; the primitive sees a block reference as
  the smi that encodes it, so a value-level contract (e.g. `smi_add`'s
  WRONG_OBJECT_TYPE for a non-smi receiver) was unsatisfiable for such
  arguments, for C++ as for Rust. The default contract still applies.
* `byte_array_at_contract` specifies the byte only for a byte array of
  the model (`Body::Bytes`): C++ also reads mapped files, which the core's
  heap model treats as opaque objects (verified/core/TRUSTED.md V5).

Why: wiring the Rust primitives into the verified PRIMITIVE handler
(verified/core, branch core/prims-integration). Implementations: the core
proves its ported outcomes are `prim_returns` completions
(`primitive::lemma_completion`); C++ primitives are compared with the
proven ports by verified/core/tests/prim_diff.sh.

Opcodes: PRIMITIVE.

## 2026-11-10: the PRIMITIVE protocol and per-primitive contracts (S1)

What: `prim.rs` states the call/return protocol the machine implements
(comment "The PRIMITIVE protocol"), and `theorem::completion` is exactly
it. After the step's `Outcome2::Primitive(s, m, i)` (the top frame holds
exactly the method's parameters, `prim_args(p, s)`):

* `prim_missing(p, s)`: not implemented, denied by the policy, or an arity
  other than the method's (a raise of PRIMITIVE_LOOKUP_FAILED);
* a call returning heap `h2` and `r: PrimRet` with
  `prim_returns(p, s, m, i, h2, r)`, continued by `prim_complete(p, s,
  h2, r)`: `Success(v)` returns `v` from the frame (`prim_success`),
  `Failure(v)` pushes `v` and continues at bci + 4 (`prim_failure`),
  `OutOfMemory(v)` (the call's THROW status: memory ran out after the
  GC's retries; `resource_error(p, v)`: roots 7, 17, 18) is
  `Outcome2::Raise(with_heap2(s, h2), v)`;
* core.task_new / core.task_transfer (`machine_completed(m, i)`, 0:115 and
  0:116): `task_step(p, s, i)` (`task_new_step`, `task_transfer_step`), or
  a call returning only `OutOfMemory`. The generic success/failure
  oracle no longer applies to them.

`prim_returns` = `prim_spec(p, m, i, prim_args(p, s), s.heap, h2, r)`
(and `OutOfMemory` for the task primitives). `prim_spec` (the set of
allowed `(h2, r)`, as a predicate) is `prim_default(p, h, h2, r)` (the
hypothesis-2 contract: `prim_heap_ok`, results are values of `h2`,
out-of-memory values are resource errors) and
`prim_refined(p, m, i, args, h, h2, r)`, which is `true` except for three
examples: `smi_add_spec` (0:51), `array_at_spec` (0:14),
`array_at_put_spec` (0:15) (wrong types, bounds, read-only arrays, the
stored element; other cases default). `sound.rs::completions_ok`
quantifies over `prim_default`, so the theorem needs only the default
(`lemma_prim_spec_default`); `sound_prim_spec.rs` shows the three
refinements are satisfiable on well-formed heaps.

Why: S1 (OBLIGATIONS.md): the core's `op_primitive_cold` (lookup, arity
check, `toit_v2_call_primitive` with statuses SUCCESS, FAILURE, THROW)
can now refine PRIMITIVE step by step; before, the THROW status (raising
an allocation-failed error) was not a transition. A primitive ported to
Rust is proven against `prim_spec`.

Opcodes: PRIMITIVE.

## 2026-11-10: resource throws are transitions (core request R6)

What: `prim.rs`: `resource_throw(p, s, o)`, the outcomes the machine may
produce instead of the step in state `s` when its stack or memory runs
out. They start from `s` itself (the instruction has not run) and exist
only at these opcodes (`op = p.bytecodes[s.bci]`):

* `grows_stack(op)`: INVOKE_STATIC, INVOKE_STATIC_TAIL, INVOKE_BLOCK,
  INVOKE_LAMBDA_TAIL, INVOKE_INITIALIZER_TAIL, INVOKE_VIRTUAL(_WIDE),
  INVOKE_VIRTUAL_GET/SET, INVOKE_EQ..INVOKE_SIZE (operators, INVOKE_AT,
  INVOKE_AT_PUT, INVOKE_SIZE), TRY, LOAD_GLOBAL_VAR_LAZY(_WIDE): either
  `unwind(p, s, Throw(out_of_memory(p)))` (roots[4], nothing allocated) or
  `Outcome2::Raise(s, p.roots[ROOT_STACK_OVERFLOW])` (roots[28]; an
  `Exception_` with the machine's trace, completed by `raised`);
* `allocates_instance(op)`: ALLOCATE(_WIDE): `unwind(p, s,
  Throw(out_of_memory(p)))`;
* `allocates_double(p, s, op)`: INVOKE_ADD/SUB/MUL with two doubles:
  `operator_fallback(p, s, op)` (the result could not be allocated; the
  operator's method is called, as the core does).

`theorem.rs`: `outcome(p, s, o)` also includes every completed resource
throw; the theorem is unchanged otherwise (`sound_resource.rs`:
`lemma_resource`). A primitive's own out-of-memory is a PRIMITIVE
completion (entry "the PRIMITIVE protocol"), a raise's a completion of
the raise.

Why: core request R6. The core's `grow_cold` (stack overflow: raise of
roots[28]; out of memory: throw of roots[4]), ALLOCATE's failed
allocation (throw of roots[4]) and the failed double allocation of
`op_invoke_arith_slow_cold` (operator fallback) are now instances of spec
transitions, so `step::resource_throw` and `exception_like` can be
replaced by `prim::resource_throw` (completed by `prim::completes`).

Opcodes: those listed above.

## 2026-11-10: raising is an oracle step (core request R7)

What: `types.rs`: `Outcome2` has a new variant `Raise(State2, Value)`.
`spec.rs`: `raise(p, s, k)` is now `Outcome2::Raise(s, failure_value(p, k))`
(`failure_value(p, k) == p.literals[2 + k]`); the old deterministic
outcome is `raise_null(p, s, k)`. New: `exception_obj2(p, value, trace)`
(an `Exception_` with value, trace, null elsewhere; `exception_obj(p, k)`
is `exception_obj2(p, literals[2 + k], null)`), `throw_exception(p, s,
value, trace)` (allocate it at the end of the heap, then unwind; `Fatal`
if the exception class has fewer than two fields, as before). `prim.rs`:
`raised(p, s, value, o)` completes a raise:

* `o == throw_exception(p, with_heap2(s, h2), value, trace)` for any heap
  `h2` with `heap_extended(p, s.heap, h2)` (`prim_heap_ok` plus `s.heap`
  is a prefix: objects only added, under the primitive's heap contract)
  and any `trace` with `good(h2, trace)`; or
* `o == unwind(p, with_heap2(s, h2), Throw(out_of_memory(p)))` for any such
  `h2` (`out_of_memory(p) == roots[4]`): the exception's allocation failed.

`completes(p, o, o2)`: `raised` for a `Raise`, else `o2 == o`.
`theorem.rs`: `outcome(p, s, o)` = `completes(p, step(p, s), o)` or a
completed `completion` of a PRIMITIVE step; `transition` is `small(s2)`
and some `outcome` continuing in `s2`; the theorem also states that no
`outcome` of a reachable state is `Stuck` or `Raise`. `exec.rs`:
`ExecOutcome2::Raise(v)`, `x_raise` returns it without changing the state,
`x_throw_null` is the verified reference completion (the interpreter
calls it). Proofs: `lemma_raised`, `lemma_throw`, `lemma_throw_oom`,
`lemma_raise_value`, `lemma_raise_null` (`raise_null` is a completion).

Why: core request R7 (OBLIGATIONS.md section 3). The VM's exception
carries an encoded stack trace and the format-1 message (PHASE4-REQUESTS
R2), allocated by C++ (`toit_v2_allocate_exception`: a GC point that may
fail), so the machine's raise did not refine the old deterministic one.
The core's `raise_value_msg_cold` is now an instance: the trace byte array
(or null) is the extension and the trace, `allocate_instance` failing is
the out-of-memory completion.

Opcodes: every raised failure: LOAD_FIELD(_WIDE), LOAD_FIELD_LOCAL,
POP_LOAD_FIELD_LOCAL, STORE_FIELD(_WIDE,_POP), STORE_FIELD_THIS,
LOAD/STORE_GLOBAL_VAR_DYNAMIC, AS_*, IS/AS checks of INVOKE_STATIC(_TAIL)
and lazy globals (receiver ranges), INVOKE_VIRTUAL*, the operator
fallbacks, INVOKE_BLOCK, TRY, INVOKE_LAMBDA_TAIL, INVOKE_INITIALIZER_TAIL,
HALT 1, PRIMITIVE (missing primitive). The core's proven handlers are
unaffected (their `step` results are `Next`); a handler proving a raise
path shows `step(p, g0) == Outcome2::Raise(g, v)` and that its machine
continues in an outcome `o` with `raised(p, g, v, o)`.
## 2026-11-10: the verifier checks one method at a time (R8), no_std

What: `accepts` and the theorem are unchanged. New: `v2/split.rs`
(`split_ok`, the per-method form of `accepts`, proven equivalent:
`lemma_split_sound`, `lemma_split_complete`, `theorem_soundness_split`),
`v2/vprog.rs` (`VProgram`: the program as borrowed tables, `VMethod` in
the VM's `V2Method` layout; `vview(p)` equals `pview2` of the same
tables). `check::verify` now takes `(p: &VProgram, g: &XGlobal, oracle,
trusted)` and returns `pins_sorted(g) && split_ok(...)`; `XCert` is the
certificate one method is checked against. `heap_check::x_loaded_ok`
takes the global count instead of a certificate; new
`x_loaded_ok_stream` (one object at a time). The inference API is
`infer::infer_global` + `infer::Oracle` / `infer::check`.

no_std: the crate has a `std` feature (default). Without it, it is
`no_std` + `alloc` and leaves out `interp`, `exec_step` and `v2::exec`
(Verus still sees them: `verus_keep_ghost`). `types.rs` and `v2/exec.rs`
only gained `use alloc::vec::Vec;` (no other change).

Why: R8 (memory on devices), Phase 5.

For implementations: the VM must call the new entry points (vmverify
does); the theorem's hypotheses are the same, stated for the assembled
certificate `with_maps(g, ms)`.

Opcodes: none.

## 2026-11-10: a verified check of the loader's contract (R4)

What: `sound.rs` splits `loaded_ok` into `loaded_heap_ok` (heap size, every
object `loaded_obj_ok`: well formed, not a stack, not a task; roots and
literals are values) and the globals part; the contract is unchanged.
`v2/heap_check.rs` is now Verus: `x_loaded_heap_ok(p, heap)` (`Ok` iff
`loaded_heap_ok`) and `x_loaded_ok(p, c, heap, globals)` (`== loaded_ok`),
both requiring `wf_program2` (checked by `check::verify` first).

Why: R4; the VM can run the check at untrusted launch.

Opcodes: none.

## 2026-11-10: finally records instead of heap tokens (R1)

What (format note 17): entering finally code with an unwinding no longer
allocates. `types.rs`: new `Resume` and `Fin`; `State2.fins`,
`ExecState.fins`; `Body::Stack2`/`ExecBody::Stack2` gain the records
(`Stack2(words, frames, tries, fins, bci)`); `Body::Pending` and
`ExecBody::Pending` are removed. `spec.rs`:

* `enter_finally(Some(u))`: pops the handler, pushes
  `Fin { frame, height, resume_of(u) }`, and pushes the value
  (`value_of(u)`: the exception, the return value, or null for a branch),
  the token `smi(index of the record)` and the reason.
* UNWIND: a smi token `k` with `fin_matches(s, k)` (record of the top frame
  whose token slot is the UNWIND's) truncates `fins` to `k` and resumes
  `unwind_of(fins[k].resume, value slot)`; other tokens are
  `Stuck(NotUnwind)`.
* `return_from`, `pop_frame`, `replace_frame`: drop the popped frame's
  records (`fins_popped`, i.e. `cut_fins(fins, top, 0)`).
* TRY: drops the frame's trailing records whose token slot is at the TRY's
  height or above (`cut_fins(fins, top, H - 1)`) before installing the
  handler.
* `prim.rs`: task switching saves and restores the records; a new task has
  none.
* Verifier: UNWIND also requires the value slot (below the token) to be a
  value.

Why: R1 (allocation on every non-local return through a finally, and an
out-of-memory path that skipped finally code). The request's one record
per frame was unsound for try/finally nested inside finally code (note
17), hence the record stack.

Opcodes: TRY, UNWIND, THROW, RETURN, RETURN_NULL, NON_LOCAL_RETURN,
NON_LOCAL_BRANCH, INVOKE_STATIC_TAIL, INVOKE_LAMBDA_TAIL,
INVOKE_INITIALIZER_TAIL, every raised failure (they unwind), PRIMITIVE
core 115/116 (task_new, task_transfer).

## 2026-11-10: the fields of a task the machine owns (R5)

What: field 0 of a task (`Task::STACK_INDEX`, its stack) is neither
readable nor writable by the program; field 1 (`Task::ID_INDEX`, its id)
is read-only. A task is an instance of the builtin task class
(`spec::is_task_obj`).

* LOAD_FIELD, LOAD_FIELD_WIDE, LOAD_FIELD_LOCAL, POP_LOAD_FIELD_LOCAL:
  `field_readable` instead of `field_ok`; a task's field 0 raises
  INVALID_PROGRAM.
* STORE_FIELD, STORE_FIELD_WIDE, STORE_FIELD_POP: `field_writable`
  (exists, not read-only, not a task's field 0 or 1); otherwise
  INVALID_PROGRAM.
* INVOKE_VIRTUAL_GET / INVOKE_VIRTUAL_SET (and INVOKE_SIZE's fallback):
  the field-accessor fast path needs `field_readable` / `field_writable`;
  otherwise the accessor method is called.
* LOAD_FIELD_THIS 0 / STORE_FIELD_THIS 0 or 1 on a task: `Stuck`. The
  verifier excludes them: `this_load_ok` / `this_store_ok` reject the
  field in a method whose receiver range contains the task class.
* `task_transfer_step`: a running task that is not a task or has no stack
  (or no frames) is `Stuck(Fatal)` instead of the failure ERROR; the
  invariant proves it unreachable. A target without a (resumable) stack
  still fails with ERROR (a terminated task).
* Verifier tables (`task_class_ok`): the builtin task class has
  `TASK_TAG`, no other class has it, and the exception class is not the
  task class (so ALLOCATE never creates a task and the machine's tag test
  agrees with the spec's class test).
* Contracts: `loaded_ok` forbids task objects in the program heap;
  `prim_heap_ok` forbids primitives to create tasks or change a task's
  fields 0 and 1.

Why: R5 (PHASE4-REQUESTS.md). End-to-end fuzzing found an accepted
program that overwrote a task's stack field; the spec treated the field
as an ordinary instance field although the VM uses it as the task's
stack. The theorem now also states `machine_objects_ok` for every
reachable state (every task's stack field is a stack object or the smi 0,
its id a smi, the running task's stack field a stack object).

Opcodes: LOAD_FIELD(_WIDE), LOAD_FIELD_LOCAL, POP_LOAD_FIELD_LOCAL,
STORE_FIELD(_WIDE,_POP), LOAD_FIELD_THIS, STORE_FIELD_THIS,
INVOKE_VIRTUAL_GET, INVOKE_VIRTUAL_SET, INVOKE_SIZE, PRIMITIVE core 116
(task_transfer).
