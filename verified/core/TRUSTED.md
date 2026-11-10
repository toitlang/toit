# Trusted base of the verified core

Everything the core relies on without proof. The machine-checked list of
every escape hatch (external_body, uninterp, unsafe, plain-Rust items) is
verified/TRUSTED.toml, enforced by `verified/check.sh`; this file explains
the contracts behind the entries. The list must only shrink.

## 1. Memory views (`src/view.rs`)

Opaque structs holding raw pointers into VM memory. Their ghost content
(`view`, uninterpreted) is related to memory only by the `requires` /
`ensures` of the `external_body` accessors.

| View | What it wraps | Contract |
|---|---|---|
| `Table<T>` | an immutable program table `ptr[0..len)` (bytecodes, method table, dispatch table, class tables, roots, literals) | `len() == view.len()`; `at(i)` requires `i < len`, returns `view[i]` |
| `Globals` | the process' global variables | `at`/`set` require `i < len`; `set` updates `view[i]` |
| `StackMem` | the array of the current task's `Stack` object | `read`/`write` require `i < len`; `copy_within` is a memmove with an exact contract; `header`/`set_header` access the Stack header words (top, record top, bci with the finally-record count) |
| `Heap` | process and program heap objects | the heap model (`objs`, `addrs`, `class_bits`; `abs::obj_model_ok`: instances and arrays agree with their class tag, field count, length and encodable contents): `class_id`, `class_tag`, `field`/`set_field`, `array_length`, `element`/`set_element` relate memory to it; without ghost content: `header`, `word`, `byte`, `u32_at`, `set_word`, `set_byte` access the object a tagged word designates; the setters apply the write barrier (card mark) |
| `Preemption` | `Interpreter::watermark_` | `requested`/`clear`/`request`: environment nondeterminism, no contract |

Assumptions behind the views:

- V1 Single owner: the interpreter thread owns the process while the core
  runs, so nobody else writes the stack, globals or heap; program tables
  are immutable.
- V2 Heap integrity: a word with the heap tag that the core reads from a
  root (object stack, globals, program tables) or from a field of such an
  object designates a live object with a valid header, and the offsets the
  core computes from the header (layout constants, field counts from
  `class_bits`, array lengths) are inside it. Maintained by the GC and by
  every allocation; the core's own writes only store such words or smis.
  This is the largest assumption: the core reads object fields through
  `Heap` without a ghost bound (OBLIGATIONS.md F1).
- V3 Method table: every `V2Method` has `entry <= end <= bytecodes.len()`
  (checked by the C++ loader, `V2MethodTable::compute`). The fast dispatch
  path reads up to `MAX_INSTRUCTION_LENGTH` bytes from `bci < end - 6`.
- V4 Word size: `usize` is 64 bits and `Object*`, `uword` and
  `std::atomic<Object**>` are word-sized (the layout check tests the
  latter; the CMake option is only on for 64-bit hosts).

## 2. FFI (`src/ffi.rs`, `src/interpreter_v2.cc`)

`Runtime` wraps the C++ functions of src/interpreter_v2.h. Each function
that may GC takes the only `StackMem` by `&mut` and replaces it with a
fresh view of the current task's stack; the caller has stored its state
(top, record top, bci and finally-record count) into the Stack object
first (`Machine::save`) and
re-derives everything after (`Machine::reload`). The full contract, with
the precondition the core discharges for each function, is in DESIGN.md,
"FFI contract".

GC and allocation: `alloc::gc_allocate_instance` (ALLOCATE) is the one
may-GC call with a contract in terms of the abstraction. Before the call
the views represent the ghost state `g`: `alloc::reloaded(m, g).refines(p)`,
where `reloaded` re-derives the machine's cached fields (length, top, frame
top, bci, the top frame's base and method) from the stack view and its
header words. ASSUMED: afterwards the views represent `g` with the spec's
new instance (class `c`, every field null, outside the program heap)
appended and the result is its address; or `g` itself if the result is 0
(out of memory). This is "the GC preserves the abstraction" (it moves
objects and rewrites every root: object-stack slots, globals; it keeps the
frame records and the header, possibly moving or shrinking the Stack
object) plus "allocation appends exactly one object". The save before and
the reload after are proven (`Machine::save`, `alloc::reload`); the other
may-GC calls still go through the assumed bridges (`step_unverified`,
`grow_bridge`).

`toit_v2_run` builds the program view from the context
`Interpreter::run_v2` fills and checks the table sizes it relies on
(roots, literals, method and bytecode limits); `Interpreter::run_v2` is
trusted to fill it from the process' program and method table.

Trusted C++ the core depends on (src/interpreter_v2.cc): the method-table
decoder (`V2MethodTable::compute`, V3), `v2_program_tables` (the tables
the core and the verifier get, verified/vmverify), `prepare_process_v2`
(initial frame), the task
start and transfer glue (`v2_start_task`, `v2_task_transfer`), stack
growth (`toit_v2_grow_stack`, `Stack::v2_copy_to`), the GC and shrinking
of format-2 stacks (`Stack::roots_do`, `Stack::v2_frames_do`), the
exception allocation and trace encoding, and the C++ primitives.

The C++ primitive path (`toit_v2_lookup_primitive`,
`toit_v2_call_primitive`) calls arbitrary `PrimitiveEntry` functions of
the process' policy with the arguments on the object stack, as the C++
interpreter does. It is UNVERIFIED and OUTSIDE THE SECURITY BOUNDARY of
the core: for untrusted programs the policy only resolves the allowed set
of docs/sandbox-policy.md; trusted format-2 programs (used by the test
suite) reach every primitive this way. Porting the allowed primitives to
Rust (with `prim_heap_ok`) removes it for untrusted programs
(OBLIGATIONS.md S1).

## 3. Layout constants (`src/layout.rs`)

Every constant is compared with the C++ headers by verified/layout_check.cc
at build time (CMake target `toit_verified_core_layout`, a dependency of
`toit_vm`; also the ctest `verified_core_layout`): tags, header and field
offsets (behaviorally, on fake objects), Stack header words, frame record
layout, roots and builtin class indices, result states, FFI result codes,
message kinds, method kinds, FFI struct layouts, opcode numbers and
lengths, the failure-literal count, the table limit, the longest
instruction, and `Stack::max_length() < 2^BLOCK_SLOT_BITS`. 237 constants
plus behavioral checks.

## 4. Plain Rust (`src/machine.rs`)

The run loop and the handlers listed in OBLIGATIONS.md are plain Rust
outside `verus!`. They follow the spec function of the same name; every
spec stuck state is a run-time check, so a wrong program terminates the
process ("verified core: stuck state ..."), it does not crash the VM.
That this is true is tested (sandbox tests, the untrusted suite, the fuzz
harness), not proven.

`cold!` (src/machine.rs) moves the `Machine` into an out-of-line function
by value and back with `ptr::read`/`ptr::write` so that the hot loop keeps
its state in registers; sound because the machine has no destructor, the
moved-from place is not read in between, and nothing unwinds
(panic = abort).

## 5. The spec

verified/spec/src/v2/spec.rs is the definition the handlers follow. That it
matches the format-1 VM's observable behavior is validated by the
differential tests of verified/spec (run_suite.py) and by
verified/core/tests/untrusted_suite.py, not proven. Known differences of
the core from the spec, all outside the spec's model:

- Allocation can fail (the spec's heap is unbounded): out of memory throws
  the preallocated `OUT_OF_MEMORY` error. Unwinding itself allocates
  nothing (finally records live in the task's stack, format note 17).
- The exception the machine raises carries a stack trace and the format-1
  failure message (the spec's trace is null).
- Preemption, stack growth and stack overflow (the spec has unbounded
  stacks): a call checks for room first and throws `STACK_OVERFLOW` when
  the stack cannot grow.

## 6. The contracts of the end-to-end theorem

`src/theorem.rs` proves that the verified run loop's precondition
(`Machine::inv`: refines a well-formed state of an accepted program)
holds on every run. These are all the assumptions it rests on, besides
sections 1 to 5:

| Contract | Where | Statement | Discharged by |
|---|---|---|---|
| Loader | `theorem::loaded`, `ffi::toit_v2_run` (`Ghost::assume_new` of `ap`, `cert`, `trusted`) | the program tables are an abstract program `ap` the verifier accepts with certificate `cert` (`accepts`), its heap and globals satisfy `loaded_ok`, and the first task encodes `initial_state` | verified/vmverify at every untrusted launch (and with -Xverify / TOIT_VERIFY=1): it builds the abstract program and heap from the same `toit_v2_program` tables the core executes (TRUSTED conversion: verified/vmverify/src/from_vm.rs) and runs the proven `check::verify` (`== accepts`) and `x_loaded_ok` (`== loaded_ok`) before the process starts; `prepare_process_v2` (C++) builds the initial frames. Programs not accepted run on the checked handlers only (`toit_v2_context.accepted`, DESIGN.md section 9) |
| Between runs | `theorem::resumed`, `machine::run` (`Ghost::assume_new` of `g`) | the scheduler resumes a preempted or yielded task in the state it saved; GC between runs moves objects but preserves the abstraction | C++ scheduler and GC (trusted) |
| Heap model integrity | `abs::heap_model_ok`, `Machine::refines` | one distinct tagged address per object; an object is an instance iff its class has the instance or task tag, with its class' field count; fields are encodable; read-only objects are exactly those in the program-heap range | the GC, the allocators and the C++ primitives maintain it (TRUSTED V2) |
| GC and stack growth | `step::grow_bridge` (external_body) | growing the stack (a GC point) leaves the abstract state unchanged and gives the room; a failed growth throws (`step::resource_throw`) | `toit_v2_grow_stack`, `Stack::v2_copy_to`, the GC |
| Unproven paths | `step::step_unverified` (external_body) | the checked handlers of machine.rs refine the spec like a verified step (`step_post`) | NOT discharged: OBLIGATIONS.md lists the opcodes and paths; tested by the untrusted suite and the fuzz harness |
| Primitives | inside `step_unverified` (PRIMITIVE is not verified yet) | every allowed primitive's effect satisfies `prim_heap_ok` and the arity table | NOT discharged (OBLIGATIONS.md S1) |
| Resource stops | `step::resource_throw`, `stuck::LIMIT` | running out of stack or heap throws STACK_OVERFLOW / OUT_OF_MEMORY or stops the process: not a spec transition (the spec's memory is unbounded) | spec request R6 (PHASE4-REQUESTS.md) |
| Word size | `abs.rs` `global size_of usize == 8` | usize is 64 bits | compile-time assertion in the erased build |
| Termination | `run_loop` `exec_allows_no_decreases_clause` | none claimed: a program may run forever (the scheduler preempts it) | nothing to discharge |
