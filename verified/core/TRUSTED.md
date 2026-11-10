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
| Primitives | inside `step_unverified` (PRIMITIVE is not verified yet) | every allowed primitive's effect satisfies `prim_heap_ok` and the arity table | for the 106 primitives ported to Rust: proven (`prims::call`, section 7), once the verified PRIMITIVE handler calls it; for the rest: reviewed C++ (section 7), OBLIGATIONS.md S1 |
| Resource stops | `step::resource_throw`, `stuck::LIMIT` | running out of stack or heap throws STACK_OVERFLOW / OUT_OF_MEMORY or stops the process: not a spec transition (the spec's memory is unbounded) | spec request R6 (PHASE4-REQUESTS.md) |
| Word size | `abs.rs` `global size_of usize == 8` | usize is 64 bits | compile-time assertion in the erased build |
| Termination | `run_loop` `exec_allows_no_decreases_clause` | none claimed: a program may run forever (the scheduler preempts it) | nothing to discharge |

## 7. Primitives (`src/prims`)

The allowed primitives the core runs in Rust (`prims::call`) are proven
against the spec's primitive protocol (verified/spec/src/v2/prim.rs:
`prim_default`, i.e. `prim_heap_ok` and a `good` result or a resource
error, refined by `prim_refined` and the per-primitive `core_contract` of
verified/spec/src/v2/prim_core.rs). Status, counts and measurements:
PROGRESS.md, "Primitives". What the proofs rest on:

| Item | Where | Assumption |
|---|---|---|
| Blob bodies | `Heap::lemma_body_tag` (external_body proof fn) | heap integrity (V2) for the bodies `abs::obj_model_ok` leaves open: an object is a string, byte array, double or large integer exactly if its class has that tag. Consistent with `obj_model_ok` (instances and arrays by tag) |
| Number and blob accessors | `Heap::large_integer_value`, `double_bits`, `string_content`, `byte_array_content`, `byte_array_is_raw`, `string_hash_field`, `set_string_hash_field` | each reads (writes) the layout-checked words of the object `id` the model says has that body; `string_content`/`byte_array_content` return a `Content` whose length is the model's content length (the C++ `String::Bytes`/`ByteArray::Bytes` rules: inline, or external with the raw-bytes tag; mapped files only for reading; external structs never) |
| Content views | `Content`, `Heap::content_at/set/copy/fill` | a view stays valid for the whole primitive call: primitives never reach a GC point (allocation does not collect, below), so no object moves and no external memory is freed while a view is alive; the views never leave `prims::call`. Every access is bounds-checked by its precondition |
| Array memmove | `Heap::array_copy` | memmove of elements with the card mark of the destination, as C++ `array_replace` |
| Allocation without GC | `ffi::Allocator` (`toit_v2_try_allocate_*`) | appends exactly one object of the program's builtin class (`p.ap@.builtin[k]`) with the stated body at a fresh tagged address outside the program heap, keeping the model below 2^30 objects (`view::appended`), or changes nothing and returns 0. The class tag of each builtin class is checked at run time (`prims::builtin_with_tag`), not assumed |
| Float operations | `prims/fp.rs` (external_body, no contracts) | none: scalar IEEE-754 and libm operations with the C semantics; the contracts do not depend on float values. Compared bit for bit with the C++ by the differential test |
| The bridge | `prims/bridge.rs` (plain Rust, TEMPORARY) | the preconditions of `prims::call` (`heap_inv`, `args_ok`) hold at the checked PRIMITIVE handler (the machine refines a well-formed state; the arguments are `prim_args`). It runs only where the policy resolves the VM's own primitive (`toit_v2_lookup_primitive` sets `rust`), so denied primitives stay denied. On `NeedsGc` it collects (`toit_v2_primitive_gc`, attempts 1-3 as the C++ protocol) and calls again; a fourth failure throws ALLOCATION_FAILED (the spec's `PrimRet::OutOfMemory`). Replaced by the verified PRIMITIVE handler (branch core/refinement-2) |

### Primitives that stay in C++, and the contract the proof relies on

The theorem needs every allowed primitive to satisfy `prim_default`
(`prim_heap_ok`: objects are only added, keep their class, machine-owned
objects (suspended stacks, tasks' stack and id fields) are untouched,
every object stays well formed with good references; results are good
values; out of memory is a resource error) and the arity of
`prim_arity.rs`. For the allowed primitives not ported, reviewed (not
proven) as follows (src/primitive_core.cc unless noted):

| Primitives | Contract the proof relies on | Why the C++ meets it (review) |
|---|---|---|
| `task_new`, `task_transfer` | completed by the machine: `prim::task_step` (`task_new_step`, `task_transfer_step`); a call returns only `OutOfMemory` | `Interpreter::v2_task_transfer` / `v2_start_task` (interpreter_v2.cc) build exactly the spec's new stack and task objects and switch the current task; the C++ allocates a Stack and a Task instance with the stack and id fields and nothing else |
| `task_has_messages`, `task_receive_message` | `prim_default`; the received value is a good value | the result is null, a finalizer lambda (an existing object), a notifier's object (an existing object) or a new 4-element array of smis and the decoded message; `MessageDecoder` only allocates strings, byte arrays (raw external bytes), arrays, lists, maps, doubles and large integers of the program's builtin classes, each fully initialized before it is reachable; it never creates a Stack or a Task |
| `process_send` | `prim_default`; the heap is unchanged | encodes the argument into malloced memory (`MessageEncoder` reads, never writes, the heap; neutering of external byte arrays only clears their address and length: a byte array stays a byte array); the result is true, false or a failure root |
| `add_finalizer`, `remove_finalizer` | `prim_default`; the model is unchanged | they set or clear the finalizer bit in the object header (not modeled) and register the finalizer in a C++ list (a GC root); program-heap objects are left alone |
| `time`, `time_info`, `seconds_since_epoch_local`, `get_real_time_clock`, `random`, `random_seed`, `gc_count`, `bytes_allocated_delta`, `process_current_id`, `process_system_id`, `word_size`, `platform`, `architecture`, `vm_sdk_*`, `app_sdk_*`, `literal_index`, `spawn_method`, `get_generic_resource_group` | `prim_default` (environment nondeterminism: any good result) | they read the clock, the PRNG, counters or constants and return smis, booleans, program roots, new strings or a new array of smis (`time_info`); `random_seed` only changes the C++ PRNG state |
| `main_arguments`, `spawn_arguments` | `prim_default` | decode the launch arguments with `MessageDecoder` (as `task_receive_message`) |
| `encode_object`, `encode_error` | `prim_default` | encode into a malloced buffer (bounded since PR 3373/3374) and return a new byte array; read-only on the heap |
| `byte_array_new_external`, `create_off_heap_byte_array` | `prim_default` | allocate one byte array with raw external bytes (a proxy of malloced memory), zeroed |
| `int_parse`, `float_parse`, `float_to_string`, `float_round`, `int64_to_string`, `uint64_to_string`, `printf_style_int64_to_string`, `smi_to_string_base_10`, `string_to_utf_16`, `utf_16_to_string`, `byte_array_convert_to_string`, `byte_array_is_valid_string_content`, `crc` | `prim_default` | read blobs through `Blob` (bounds-checked by the `ARGS` macros) and return smis, large integers, doubles, booleans, new strings or new byte arrays; never write existing objects |
| bitmap `blit`, `byte_zap` (src/primitive_bitmap.cc) | `prim_default`; only the bytes of the destination byte array change | write inside `MutableBlob` bounds; a byte array stays a byte array |
