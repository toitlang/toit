# Changes to the format-2 specification

One entry per change of `src/v2/spec.rs`, `src/v2/prim.rs`, `src/v2/types.rs`
or the verifier's rules (`src/v2/verifier.rs`) that an implementation of
the spec (the verified core, the VM's loader) must follow. Newest first.

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
