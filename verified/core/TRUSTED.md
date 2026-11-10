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
| `Heap` | process and program heap objects | the heap model (`objs`, `addrs`, `class_bits`; `abs::obj_model_ok`: instances, arrays, doubles, large integers and strings agree with their class tag, field count, length and encodable contents; a byte array of the model has the byte-array tag): `class_id`, `class_tag`, `field`/`set_field`, `array_length`, `element`/`set_element`, `double_bits`, `large_int`, `string_len`/`string_byte`, `bytes_len`/`byte_at`/`set_byte_at` relate memory to it; without ghost content (used only by the checked loop of programs not accepted): `header`, `word`, `byte`, `u32_at`, `set_word`, `set_byte` access the object a tagged word designates; the setters of references apply the write barrier (card mark) |
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
- V5 Byte arrays of the model (`Heap::bytes_len`): an object with the
  byte-array tag is `Body::Bytes` exactly when it is internal or external
  with `RAW_BYTE_TAG` and a non-null address (its bytes are then readable
  and, outside the program heap, writable memory owned by it). Mapped
  files and resource proxies (other external tags) are opaque objects of
  the model: INVOKE_AT/AT_PUT/SIZE call their methods (format 1 reads
  mapped files in place; same result through the primitive).

## 2. FFI (`src/ffi.rs`, `src/interpreter_v2.cc`)

`Runtime` wraps the C++ functions of src/interpreter_v2.h. Each function
that may GC takes the only `StackMem` by `&mut` and replaces it with a
fresh view of the current task's stack; the caller has stored its state
(top, record top, bci and finally-record count) into the Stack object
first (`Machine::save`) and
re-derives everything after (`Machine::reload`). The full contract, with
the precondition the core discharges for each function, is in DESIGN.md,
"FFI contract".

GC and allocation: every may-GC call of the verified loop has a contract
in terms of the abstraction (the leaf contracts of section 6):
`alloc::gc_allocate_instance` (ALLOCATE), `alloc::gc_allocate_double`
(double arithmetic), `raise::gc_allocate_exception` (raising),
`step::gc_grow_stack` (stack growth) and `primitive::gc_call_primitive`
(C++ primitives). For the first, before the call
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
the reload after are proven (`Machine::save`, `alloc::reload`). The other
four state the same about the views, with the spec's object (double), the
spec's raise completion (heap extended by the trace, `exception_obj2`
appended, `prim::raised`), the unchanged state with room (stack growth),
or one of the spec's PRIMITIVE completions (`theorem::completion`).

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

The checked run loop (`run_checked`) and its handlers are plain Rust
outside `verus!`. They run only programs the launch did not verify (a
trusted format-2 program without -Xverify; no `ffi::Accepted` token).
They follow the spec function of the same name; every spec stuck state is
a run-time check, so a wrong program terminates the process ("verified
core: stuck state ..."), it does not crash the VM. That this is true is
tested (sandbox tests, the untrusted suite), not proven. The verified loop
uses none of them: its only plain-Rust callees are the `*_raw` FFI
trampolines of the leaf contracts and the `cold!` trampoline.

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

- (Now spec transitions, `prim::resource_throw`.) Allocation can fail:
  out of memory throws the preallocated `OUT_OF_MEMORY` error. Unwinding
  itself allocates nothing (finally records live in the task's stack,
  format note 17).
- (Now the spec's oracle step, `prim::raised`.) The exception the machine
  raises carries a stack trace and the format-1 failure message.
- Preemption (not a spec transition: the machine leaves the loop in a
  state the spec reached). Stack growth and stack overflow are resource
  throws of the stack-growing instructions.

## 6. The contracts of the end-to-end theorem

`src/theorem.rs` proves that the verified run loop's precondition
(`Machine::inv`: refines a well-formed state of an accepted program)
holds on every run, and every opcode of format 2 has a verified handler.
These are all the assumptions it rests on, besides sections 1 to 5:

| Contract | Where | Statement | Discharged by |
|---|---|---|---|
| Loader | `theorem::loaded`, `ffi::toit_v2_run` (`Ghost::assume_new` of `ap`, `cert`, `trusted`), `ffi::Accepted` | the program tables are an abstract program `ap` the verifier accepts with certificate `cert` (`accepts`), its heap and globals satisfy `loaded_ok`, and the first task encodes `initial_state` | the runtime fact: verified/vmverify accepted (`check::verify == accepts`, `x_loaded_ok == loaded_ok`) the program on exactly the `V2MethodTable` the process runs (`V2MethodTable::verified`, set only by `V2Verifier::verify`'s accept path); `Interpreter::run_v2` then writes `TOIT_V2_ACCEPTED` and `toit_v2_run` builds the `Accepted` token (private field), which `step::run_loop` requires, so the verified loop cannot be entered otherwise. TRUSTED: the conversion verified/vmverify/src/from_vm.rs, `prepare_process_v2` (initial frames) and `toit_v2_run` filling `Program` from the same tables |
| Between runs | `theorem::resumed`, `machine::run` (`Ghost::assume_new` of `g`) | the scheduler resumes a preempted or yielded task in the state it saved; GC between runs moves objects but preserves the abstraction | C++ scheduler and GC (trusted); `reload` re-checks the Stack header's shape |
| Heap model integrity | `abs::heap_model_ok`, `Machine::refines`, TRUSTED V2, V5 | one distinct tagged address per object; class tag and body agree; read-only objects are exactly those in the program-heap range | the GC, the allocators and the C++ primitives maintain it |
| Allocation | `alloc::gc_allocate_instance`, `alloc::gc_allocate_double` | the views represent the state with exactly the spec's new object appended, or the state itself (out of memory) | `toit_v2_allocate_instance`/`_double` and the GC |
| Raise | `raise::gc_allocate_exception` | the views represent the state with the heap extended (`prim::heap_extended`: the trace) and `exception_obj2(value, trace)` appended, or only extended (out of memory): `prim::raised` | `toit_v2_allocate_exception` (`ProgramOrientedEncoder`, `allocate_byte_array`, `allocate_instance`) and the GC |
| Stack growth | `step::gc_grow_stack` | the views represent the same state, with `needed` free words on success | `toit_v2_grow_stack`, `Stack::v2_copy_to`, the GC |
| Primitives | `primitive::gc_call_primitive` | the status, result and resulting state are one of the spec's completions of the PRIMITIVE step (`theorem::completion`): `prim_default`/`prim_spec` for each C++ primitive the policy resolves (docs/sandbox-policy.md: every allowed primitive), `task_step` for task_new/task_transfer | NOT discharged per primitive: the C++ primitives (S1); the Rust ports of branch core/primitives prove their own `prim_spec` and are not wired in yet (OBLIGATIONS.md) |
| Floating point | spec crate: `x_double_add/sub/mul`, `x_compare_mixed` | host IEEE-754 and the interpreter's `compare_numbers` are the spec's uninterpreted functions | as format 1 (shared code) |
| Word size | `abs.rs` `global size_of usize == 8` | usize is 64 bits | compile-time assertion in the erased build |
| Termination | `run_loop` `exec_allows_no_decreases_clause` | none claimed: a program may run forever (the scheduler preempts it) | nothing to discharge |

## 7. Review of the trusted items

One sentence per item (or per group of identical accessors): how the
contract could be wrong, and the test that would catch it. Contracts
tightened in this review: `StackMem::header`/`set_header` now require one
of the three header words the core uses (before: any word offset);
`Accepted` replaced the boolean `accepted` (before: "untrusted policy or
-Xverify", not "this table was accepted").

| Item | How it could be wrong | What catches it |
|---|---|---|
| `Table::{len, at}`, `Table::from_raw` | `toit_v2_run` passes a wrong length for a table (e.g. a short invoke-offsets table) | layout check (struct offsets), vmverify differential (the verifier reads the same tables), ASan fuzzing |
| `Globals::{len, at, set}`, `from_raw` | the globals pointer or length differs from the process' globals | ASan fuzzing, untrusted suite (globals tests) |
| `StackMem::{len, read, write, copy_within}`, `from_stack` | the Stack object's length word differs from the array the core indexes | `TOIT_V2_VALIDATE=1` (slot checks around GCs), ASan fuzzing |
| `StackMem::{header, set_header}` | a header word offset collides with the array | layout check (`STACK_*_WORD`), tests/sandbox |
| `Heap::{class_id, class_tag}` | header decoding (smi shift, tag mask) differs from the C++ `HeapObject` layout | layout check (behavioral, fake objects) |
| `Heap::{field, set_field, array_length, element, set_element}` | an object's field count or length disagrees with its class bits (heap integrity) | layout check, `TOIT_V2_VALIDATE`, ASan fuzzing |
| `Heap::{double_bits, large_int}` | value word offset wrong | layout check (`DOUBLE_VALUE_WORD`, `LARGE_INTEGER_VALUE_WORD`), build/t differential tests |
| `Heap::{string_len, string_byte}` | internal/external string encoding (sentinel, external words) differs from `String` | layout check, IDENTICAL on external strings (untrusted suite string tests) |
| `Heap::{bytes_len, byte_at, set_byte_at}` | a byte-array tag other than RAW_BYTE_TAG has a valid address, or the model treats proxies as bytes (V5) | layout check, fuzzing, tests on external byte arrays (`ByteArray 20_000`) |
| `Heap::{header, word, set_word, byte, set_byte, u32_at}` | only the checked loop; a missing run-time check there reads outside an object | ASan with programs not accepted (runtime-hardening-test) |
| `Preemption::*` | the watermark is not the interpreter's | tests that preempt (tests/sandbox scheduling tests) |
| `Runtime::*` (FFI wrappers), `PrimitiveRef` | a wrapper forgets to replace the stack view after a GC | `TOIT_V2_VALIDATE`, ASan |
| `alloc::gc_allocate_instance`, `gc_allocate_double` | the GC moves an object without updating a root the abstraction covers, or the new object is not the spec's | `TOIT_V2_VALIDATE=1` around every GC, untrusted suite, fuzzing |
| `raise::gc_allocate_exception` | the encoder reads a message word as an object after a GC point, or the exception is not `exception_obj2` (value field 0, trace field 1) | negative tests comparing traces with format 1 (untrusted suite), ASan |
| `step::gc_grow_stack` | records not copied (`Stack::v2_copy_to`) or the header not updated | deep-recursion tests (build/t/deep.toit, tests/sandbox), `TOIT_V2_VALIDATE` |
| `primitive::gc_call_primitive` | a C++ primitive breaks `prim_heap_ok` (e.g. writes a task's stack field, as before R5) or returns a non-value | fuzzing (found R5), vmverify differential, ported Rust primitives replace them (S1) |
| `ffi::toit_v2_run` `assume_new` (ap, cert, trusted) | the tables the core runs differ from those vmverify checked | vmverify differential (from_vm on the same `toit_v2_program`), the `Accepted` token ties the loop to the accepted table |
| `machine::run` `assume_new` (g) | the scheduler resumes a different state | tests/sandbox task tests, untrusted suite (tasks, channels) |
| `machine.rs` (plain-Rust file), `cold!` | the checked loop runs only programs not accepted; `cold!` (also used by the `*_raw` trampolines of the verified loop's leaf calls) assumes no unwinding panic in the moved-out machine | runtime-hardening-test, the checked loop's run-time checks; review: the `*_raw` bodies only call the FFI |
| `ffi.rs` plain items (layout tables, `Context`, `ProgramTables`, extern decls) | a C struct field moved | layout check (every offset) |
| uninterp views (`objs`, `addrs`, `class_bits`, `view`, `hdr`) | none by themselves: they are related to memory only by the accessors' contracts | (the accessors' tests) |
