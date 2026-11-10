# Changes to the format-2 specification

One entry per change of `src/v2/spec.rs`, `src/v2/prim.rs`, `src/v2/types.rs`
or the verifier's rules (`src/v2/verifier.rs`) that an implementation of
the spec (the verified core, the VM's loader) must follow. Newest first.

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
