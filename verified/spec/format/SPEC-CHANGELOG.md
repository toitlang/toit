# Changes to the format-2 specification

One entry per change of `src/v2/spec.rs`, `src/v2/prim.rs`, `src/v2/types.rs`
or the verifier's rules (`src/v2/verifier.rs`) that an implementation of
the spec (the verified core, the VM's loader) must follow. Newest first.

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
