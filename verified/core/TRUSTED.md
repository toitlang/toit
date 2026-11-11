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
| `StackMem` | the array of the current task's `Stack` object | `slot(i)` (`i <= len`) is the cursor at index `i`, carrying the view's identity `sid` (uninterpreted); `read`/`write` (verified: through `slot(0)`) require `i < len`; `copy_within` is a memmove with an exact contract; `header`/`set_header` access the Stack header words (top, record top, bci with the finally-record count); `write`, `copy_within` and `set_header` keep `sid` |
| `Cursor<T>` (`Slot` = `Cursor<usize>`, `Ip` = `Cursor<u8>`) | a pointer into the array of one `StackMem` (the run loop's registers: object-stack top, frame limit, frame top, array end) or into the bytecode table (the instruction pointer) | ghost index `s@` and identity `sid` (uninterpreted); `read(n, mem)`/`write(n, v, mem)` (stack) and `byte(k, t)` (bytecodes, `Table::cursor` creates the cursor, `Table::sid` the identity) require `s.sid() == mem.sid()` and `0 <= s@ + n < len` and access element `s@ + n`; `offset(k)` moves the index by `k` (wrapping pointer arithmetic, never dereferenced itself); `diff(o)` is the element distance of two cursors of the same view (`0 <= o@ <= s@`, less than 2^28 elements apart); `lt(o, mem)` is the order of two stack cursors of `mem` inside its array (the end included), a pointer comparison (the gate of the returns' fast path, 2026-11-11, branch core/size-diet). Sound because cursors are created only by `StackMem::slot`, and a view replaced at a GC point (section 2) has an identity no contract relates to the old one, so a cursor into an old array cannot be used (the type-level form of "no pointer survives a GC point"). Added by the register loop (2026-11-11): 10 more allowlist groups than the index-based `read`/`write` they replace in the hot path (6 for the stack cursors, 4 for the instruction pointer) |
| `Heap` | process and program heap objects | the heap model (`objs`, `addrs`, `class_bits`; `abs::obj_model_ok`: instances, arrays, doubles, large integers and strings agree with their class tag, field count, length and encodable contents; a byte array of the model has the byte-array tag): `class_id`, `class_tag`, `field`/`set_field`, `array_length`, `element`/`set_element`, `double_bits`, `large_int`, `string_len`/`string_byte`, `bytes_len`/`byte_at`/`set_byte_at`, and for the primitives `string_content`/`byte_array_content` (a `Content` view), `content_at`/`content_set`/`content_copy`/`content_fill`, `array_copy`, `string_hash_field`/`set_string_hash_field` (section 8) relate memory to it; without ghost content (used only by the checked loop of programs not accepted): `header`, `word`, `word64` (a 64-bit payload, two words on 32-bit), `byte`, `half_word_at`, `set_word`, `set_byte` access the object a tagged word designates; the setters of references apply the write barrier (card mark) |
| `Preemption` | `Interpreter::watermark_` | `word` (the raw watermark), `clear`, `request`: environment nondeterminism, no contract; `requested` (verified) is `word() == PREEMPTION_MARKER`. The call's room check is `free >= (word | needed)`, proven for every word value |

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
- V4 Word size: `usize` is the target's word (64 or 32 bits, Verus
  verifies both: section 6 "Word size") and `Object*`, `uword` and
  `std::atomic<Object**>` are word-sized (the layout check tests the
  latter on 64-bit and 32-bit hosts).
- V5 Byte arrays of the model (`Heap::bytes_len`): an object with the
  byte-array tag is `Body::Bytes` exactly when it is internal or external
  with `RAW_BYTE_TAG` and a non-null address (its bytes are then readable
  and, outside the program heap, writable memory owned by it). Mapped
  files and resource proxies (other external tags) are opaque objects of
  the model: INVOKE_AT/AT_PUT/SIZE call their methods (format 1 reads
  mapped files in place; same result through the primitive), and the
  Rust primitives return `NotPorted` for them (`prims::blob::ByteArg`,
  `BlobArg::NotPorted`), so the C++ primitive handles them. The program
  image follows the same rule (verified/vmverify/src/from_vm.rs models an
  external byte array without raw bytes as an opaque object). A C++
  primitive that neuters a byte array (`process_send` clears the address)
  turns a model byte array into an opaque one, which `prim_heap_ok`
  allows (the class stays).

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

Primitives. The verified PRIMITIVE handler runs the Rust port of a core
primitive (`prims::call`, section 8) when the process' policy resolves
that primitive to the VM's own entry with the method's arity: a table
lookup in `toit_v2_context::core_arities` (`PrimitivePolicy::core_arities`,
built once per standard policy from the policy's tables: arity + 1 where
the policy's entry is the VM's own function, else 0; derived policies share
their base's). TRUSTED: the table agrees with the policy (a C++ fact like
the policy itself; the spec does not model policies, so the proof does not
depend on it, but the sandbox does: a denied primitive must not run as
Rust). Otherwise, and when the port returns `NotPorted` or `NeedsGc`, the
C++ primitive path (`toit_v2_lookup_primitive`, `toit_v2_call_primitive`)
calls the `PrimitiveEntry` of the process' policy with the arguments on
the object stack, as the C++ interpreter does; it collects garbage and
retries on allocation failure. That path is UNVERIFIED and OUTSIDE THE
SECURITY BOUNDARY of the core (its leaf contract `gc_call_primitive`
states what it must do): for untrusted programs the policy only resolves
the allowed set of docs/sandbox-policy.md, 106 of whose 143 primitives
have Rust ports; trusted format-2 programs (used by the test suite) reach
every primitive, and the checked loop (programs not accepted) calls only
C++ primitives.

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
trampolines of the leaf contracts and the `cold!` trampoline. Without the
Cargo feature `checked-loop` (devices) the checked loop is not compiled:
`machine::run` then terminates a program without an `Accepted` token
(stuck report `FATAL`, `TERMINATED`) without executing an instruction;
the VM refuses such programs before (`ProcessGroup::create`,
`V2MethodTable::checked_loop_linked`), so the arm is a second line.

`cold!` (src/machine.rs) runs a closure on the machine (by reference) in
an out-of-line function: the C++ trampolines of the leaf contracts and the
cold paths of the checked loop. (Until branch core/size-diet it moved the
machine by value with `ptr::read`/`ptr::write`; the run loop keeps its hot
state in registers instead, and the copies cost 2-3 percent.)

`view::proven_unreachable` (performance, 2026-11-11) is an external_body
function with `requires false` whose body is
`core::hint::unreachable_unchecked()`. Verus proves that no call site can
meet the precondition, so the body never runs; the compiler may then drop
the path. Its one use is the default arm of the verified dispatch
(`step::step`: an opcode >= 101 contradicts the verifier's instruction
check), which removes the range check before the jump table. It assumes
nothing about the VM; it is wrong only if Verus' proof of the caller is.

## 5. The spec

verified/spec/src/v2/spec.rs is the definition the handlers follow. That it
matches the format-1 VM's observable behavior is validated by the
differential tests of verified/spec (run_suite.toit) and by
verified/tools/untrusted_suite.toit, not proven. Known differences of
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
| Loader | `theorem::loaded`, `ffi::toit_v2_run` (`Ghost::assume_new` of `ap`, `cert`, `trusted`), `ffi::Accepted` | the program tables are an abstract program `ap` the verifier accepts with certificate `cert` (`accepts`), its heap and globals satisfy `loaded_ok`, and the first task encodes `initial_state` | the runtime fact: verified/vmverify accepted (`check::verify == accepts`, `x_loaded_ok == loaded_ok`) the program on exactly the `V2MethodTable` the process runs (`V2MethodTable::verified`, set only by `V2Verifier::verify`'s accept path, or by `V2Verifier::accept_recorded` for the table spawn decodes from a flash allocation with the install-time verdict or a host verdict-cache entry: the allocation's header checksum covers the verified bytes, verified/vmverify/README.md "Where it runs"; TRUSTED: that binding, `V2MethodTable::compute` being deterministic in the bytes); `Interpreter::run_v2` then writes `TOIT_V2_ACCEPTED` and `toit_v2_run` builds the `Accepted` token (private field), which `step::run_loop` requires, so the verified loop cannot be entered otherwise. TRUSTED: the conversion verified/vmverify/src/from_vm.rs, `prepare_process_v2` (initial frames) and `toit_v2_run` filling `Program` from the same tables |
| Between runs | `theorem::resumed`, `machine::run` (`Ghost::assume_new` of `g`) | the scheduler resumes a preempted or yielded task in the state it saved; GC between runs moves objects but preserves the abstraction | C++ scheduler and GC (trusted); `reload` re-checks the Stack header's shape |
| Heap model integrity | `abs::heap_model_ok`, `Machine::refines`, TRUSTED V2, V5 | one distinct tagged address per object; class tag and body agree; read-only objects are exactly those in the program-heap range | the GC, the allocators and the C++ primitives maintain it |
| Allocation | `alloc::gc_allocate_instance`, `alloc::gc_allocate_double` | the views represent the state with exactly the spec's new object appended, or the state itself (out of memory) | `toit_v2_allocate_instance`/`_double` and the GC |
| Raise | `raise::gc_allocate_exception` | the views represent the state with the heap extended (`prim::heap_extended`: the trace) and `exception_obj2(value, trace)` appended, or only extended (out of memory): `prim::raised` | `toit_v2_allocate_exception` (`ProgramOrientedEncoder`, `allocate_byte_array`, `allocate_instance`) and the GC |
| Stack growth | `step::gc_grow_stack` | the views represent the same state, with `needed` free words on success | `toit_v2_grow_stack`, `Stack::v2_copy_to`, the GC |
| Primitives | `primitive::gc_call_primitive` | the status, result and resulting state are one of the spec's completions of the PRIMITIVE step (`theorem::completion`): `prim_spec` (the default contract, and for the core module the precise contracts of `prim_core::core_contract` and the three examples of `prim.rs`, for arguments without block references) for each C++ primitive the policy resolves, `task_step` for task_new/task_transfer | NOT discharged per C++ primitive (section 8 lists the reviewed ones; the precise contracts of the ported indices are validated against the C++ by verified/core/tests/prim_diff.sh). The Rust ports (`prims::call`, run by `primitive::op_rust_primitive`) are proven: their outcome is a completion (`primitive::lemma_completion`), no leaf contract |
| Floating point | spec crate: `x_double_add/sub/mul`, `x_compare_mixed` | host IEEE-754 and the interpreter's `compare_numbers` are the spec's uninterpreted functions | as format 1 (shared code) |
| Word size | `abs.rs` `global size_of usize == 8` (`target_pointer_width = "64"`) or `== 4` (`"32"`); the cfg'd constants of layout.rs; `abs::MAX_BLOB_LENGTH` | usize is the target's word; byte lengths of the heap model are below 2^62 (64-bit) or 2^30 (32-bit) | compile-time assertion in the erased build (and in Verus' own build for the target: verified/check.sh verifies both widths, the 32-bit one with `--target i686-unknown-linux-gnu`); layout constants by verified/layout_check.cc on each build; the blob bound by the heap model (lengths are non-negative words; a 32-bit address space holds no 1 GB object) |
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
| `StackMem::{len, slot, copy_within}`, `from_stack` | the Stack object's length word differs from the array the core indexes | `TOIT_V2_VALIDATE=1` (slot checks around GCs), ASan fuzzing |
| `Cursor::{read, write, byte, offset, diff, lt, view, sid}`, `StackMem::{slot, sid}`, `Table::{cursor, sid}` | a cursor outlives its view (a pointer into a moved Stack): only if a contract equated the identities of views across a GC point, which none does; `diff` inexact for cursors of different arrays (excluded by `sid`) | ASan fuzzing (core_fuzz.toit, launch filter), untrusted suite, `TOIT_V2_VALIDATE=1` |
| `StackMem::{header, set_header}` | a header word offset collides with the array | layout check (`STACK_*_WORD`), tests/sandbox |
| `Heap::{class_id, class_tag}` | header decoding (smi shift, tag mask) differs from the C++ `HeapObject` layout | layout check (behavioral, fake objects) |
| `Heap::{field, set_field, array_length, element, set_element}` | an object's field count or length disagrees with its class bits (heap integrity) | layout check, `TOIT_V2_VALIDATE`, ASan fuzzing |
| `Heap::{double_bits, large_int}` | value word offset wrong | layout check (`DOUBLE_VALUE_WORD`, `LARGE_INTEGER_VALUE_WORD`), build/t differential tests |
| `Heap::{string_len, string_byte}` | internal/external string encoding (sentinel, external words) differs from `String` | layout check, IDENTICAL on external strings (untrusted suite string tests) |
| `Heap::{bytes_len, byte_at, set_byte_at}` | a byte-array tag other than RAW_BYTE_TAG has a valid address, or the model treats proxies as bytes (V5) | layout check, fuzzing, tests on external byte arrays (`ByteArray 20_000`) |
| `Heap::{header, word, word64, set_word, byte, set_byte, half_word_at}` | only the checked loop; a missing run-time check there reads outside an object | ASan with programs not accepted (runtime-hardening-test) |
| `Preemption::*` | the watermark is not the interpreter's | tests that preempt (tests/sandbox scheduling tests) |
| `Runtime::*` (FFI wrappers), `PrimitiveRef` | a wrapper forgets to replace the stack view after a GC | `TOIT_V2_VALIDATE`, ASan |
| `alloc::gc_allocate_instance`, `gc_allocate_double` | the GC moves an object without updating a root the abstraction covers, or the new object is not the spec's | `TOIT_V2_VALIDATE=1` around every GC, untrusted suite, fuzzing |
| `raise::gc_allocate_exception` | the encoder reads a message word as an object after a GC point, or the exception is not `exception_obj2` (value field 0, trace field 1) | negative tests comparing traces with format 1 (untrusted suite), ASan |
| `step::gc_grow_stack` | records not copied (`Stack::v2_copy_to`) or the header not updated | deep-recursion tests (build/t/deep.toit, tests/sandbox), `TOIT_V2_VALIDATE` |
| `primitive::gc_call_primitive` | a C++ primitive breaks `prim_heap_ok` (e.g. writes a task's stack field, as before R5), returns a non-value, or disagrees with a precise contract of `prim_core` | fuzzing (found R5), vmverify differential, prim_diff.sh (C++ against the proven Rust ports, 10M calls); the Rust ports replace 106 of them for untrusted programs (S1) |
| `PrimitivePolicy::core_arities` (C++, read through `Env::core_arities`, a `Table<u8>`) | an entry is non-zero for a primitive the policy denies (the Rust port would run although the C++ entry is `primitive_denied`) | tests/sandbox (denied primitives fail with PERMISSION_DENIED), review of `initialize_core_arities` (compares the policy's function pointer with `Primitive::at`) |
| `ffi::Allocator` (`toit_v2_try_allocate_*`) | an allocation collects garbage (a Content view would dangle) or the object is not the stated builtin class and body | review (`ObjectHeap::allocate_*` without GC, `Process::allocate_string/byte_array`), prim_diff.sh, ASan fuzzing |
| `view::Content`, `Heap::{string_content, byte_array_content, content_at, content_set, content_copy, content_fill, array_copy, string_hash_field, set_string_hash_field}` | a view's pointer or length differs from the object's bytes (external strings, V5 byte arrays), or a view outlives a GC point | layout check, prim_diff.sh, ASan fuzzing; views never leave `prims::call`, which has no GC point |
| `prims/fp.rs` | a float operation differs from the C++ (NaN payloads, libm) | prim_diff.sh (bit-exact checksums) |
| `prims/index.rs` `TABLE` (plain Rust) | a primitive index or arity differs from src/primitive.h | layout check (`toit_vcore_prim_entry` against MODULE_CORE) |
| `ffi::toit_v2_run` `assume_new` (ap, cert, trusted) | the tables the core runs differ from those vmverify checked | vmverify differential (from_vm on the same `toit_v2_program`), the `Accepted` token ties the loop to the accepted table |
| `machine::run` `assume_new` (g) | the scheduler resumes a different state | tests/sandbox task tests, untrusted suite (tasks, channels) |
| `machine.rs` (plain-Rust file), `cold!` | the checked loop runs only programs not accepted; `cold!` (also used by the `*_raw` trampolines of the verified loop's leaf calls) passes the machine by reference to an out-of-line closure | runtime-hardening-test, the checked loop's run-time checks; review: the `*_raw` bodies only call the FFI |
| `ffi.rs` plain items (layout tables, `Context`, `ProgramTables`, extern decls) | a C struct field moved | layout check (every offset) |
| uninterp views (`objs`, `addrs`, `class_bits`, `view`, `hdr`) | none by themselves: they are related to memory only by the accessors' contracts | (the accessors' tests) |

## 8. Primitives (`src/prims`)

The allowed primitives the core runs in Rust (`prims::call`, from the
verified PRIMITIVE handler, section 2) are proven against the spec's
primitive protocol (verified/spec/src/v2/prim.rs: `prim_spec`, i.e.
`prim_default` (`prim_heap_ok` and a `good` result or a resource error)
refined by `prim_refined`, whose core-module branch is the per-primitive
`core_contract` of verified/spec/src/v2/prim_core.rs). The arguments are
the frame's parameters as the primitive sees them (a block reference as
the smi that encodes it, `primitive::norm_args`); the precise contracts
apply to arguments without block references (`prim::plain_args`).
Status, counts and measurements: PROGRESS.md, "Primitives". The heap
model is TRUSTED.md V5 (a byte array is `Body::Bytes` only when internal
or raw external; the primitives return `NotPorted` for the opaque ones).
What the proofs rest on:

| Item | Where | Assumption |
|---|---|---|
| Number and blob accessors | `Heap::double_bits`, `large_int`, `bytes_len` (section 1), `string_content`, `byte_array_content`, `string_hash_field`, `set_string_hash_field` | each reads (writes) the layout-checked words of the object `id` the model says has that body; `string_content`/`byte_array_content` return a `Content` whose length is the model's content length (inline, or the external address: for a byte array only a model byte array, V5); the tag facts come from `abs::obj_model_ok` (proven, no trusted lemma) |
| Content views | `Content`, `Heap::content_at/set/copy/fill` | a view stays valid for the whole primitive call: primitives never reach a GC point (allocation does not collect, below), so no object moves and no external memory is freed while a view is alive; the views never leave `prims::call`. Every access is bounds-checked by its precondition |
| Array memmove | `Heap::array_copy` | memmove of elements with the card mark of the destination, as C++ `array_replace` |
| Allocation without GC | `ffi::Allocator` (`toit_v2_try_allocate_*`) | appends exactly one object of the program's builtin class (`p.ap@.builtin[k]`) with the stated body at a fresh tagged address outside the program heap, keeping the model below 2^30 objects (`view::appended`), or changes nothing and returns 0. The class tag of each builtin class is checked at run time (`prims::builtin_with_tag`), not assumed |
| Float operations | `prims/fp.rs` (external_body, no contracts) | none: scalar IEEE-754 and libm operations with the C semantics; the contracts do not depend on float values. Compared bit for bit with the C++ by the differential test |
| The policy table | `Env::core_arities` (`PrimitivePolicy::core_arities`) | section 2: non-zero exactly where the policy resolves the VM's own primitive. Not used by the proof (the preconditions of `prims::call`, `heap_inv` and `args_ok`, are proven from `Machine::inv` in `primitive::lemma_rust_args`) |
| Out of memory | none | `NeedsGc` leaves the heap unchanged (`prims::prim_post`), so the handler calls the C++ primitive on the same state, which collects and retries (the C++ protocol; its result is the leaf contract's completion) |

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
| `time`, `time_info`, `seconds_since_epoch_local`, `get_real_time_clock`, `random`, `gc_count`, `process_current_id`, `process_system_id`, `word_size`, `platform`, `architecture`, `spawn_method` | `prim_default` (environment nondeterminism: any good result) | they read the clock, the PRNG, counters or constants and return smis, booleans, program roots, new strings or a new array of smis (`time_info`) |
| `main_arguments`, `spawn_arguments` | `prim_default` | decode the launch arguments with `MessageDecoder` (as `task_receive_message`) |
| `encode_error` | `prim_default` | encode into a malloced buffer (bounded since PR 3373/3374) and return a new byte array; read-only on the heap |
| `int_parse`, `float_parse`, `float_to_string`, `float_round`, `int64_to_string`, `uint64_to_string`, `printf_style_int64_to_string`, `smi_to_string_base_10`, `string_to_utf_16`, `utf_16_to_string`, `byte_array_convert_to_string`, `byte_array_is_valid_string_content`, `crc` | `prim_default` | read blobs through `Blob` (bounds-checked by the `ARGS` macros) and return smis, large integers, doubles, booleans, new strings or new byte arrays; never write existing objects |
| bitmap `blit`, `byte_zap` (src/primitive_bitmap.cc) | `prim_default`; only the bytes of the destination byte array change | write inside `MutableBlob` bounds; a byte array stays a byte array |

## 9. Trusted containers on the core (experiment, branch experiment/trusted-on-core)

Results and measurements: EXPERIMENT-trusted.md. Three items make trusted
programs (the system process, first-party code) run on the verified loop
fast. None of them is reachable by an untrusted program.

| Item | Where | Statement | Why it holds / what catches it |
|---|---|---|---|
| Trusted token | `ffi::Accepted::trusted_program` | a trusted program that the launch did not verify enters the verified loop: the loader's `assume_new` of the abstract program, certificate and mode (`trusted == true`) rests on the compiler (its output would be accepted under the trusted rules) | `Interpreter::run_v2` writes `TOIT_V2_TRUSTED` only for a process whose policy is not untrusted; debug builds and `-Xverify` verify trusted format-2 programs at launch (`V2MethodTable::verify_trusted_by_default`); the whole host suite runs with everything in format 2 on the verified loop |
| Epoch | `primitive::gc_call_primitive`, `alloc::gc_allocate_instance`, `alloc::gc_allocate_double` (third result), `Runtime::{call_primitive, allocate_instance, allocate_double}` | `ObjectHeap::v2_epoch_` changes at every collection of the process' heap (`ObjectHeap::gc`) and every task switch (`ObjectHeap::set_task`); epoch unchanged across a C++ call implies that no object moved and the current task and its stack object (and length) are the same, so the core keeps its stack view and machine fields (`primitive::unmoved`) and the state is the step's with a new heap | review: every collection of a process heap goes through `ObjectHeap::gc` (scavenge and full GC, also the ones messaging and the scheduler start), the stack object is replaced only by the core's own growth (`toit_v2_grow_stack`, not a C++ primitive) and task switches go through `set_task`; tests: the whole suite on the core (GC-heavy tests, task tests), `TOIT_V2_VALIDATE=1` |
| Unchecked field accesses | `step::trusted_field_accesses` (external_body proof fn), `Program2::unchecked`, `Program::unchecked`, `toit_v2_context::unchecked` | in the unchecked mode (trusted programs) no step reaches a failed field access (a receiver other than `this` that is not an instance with the field, a machine-owned task field, a store into the program heap): `unchecked_ok` | we trust the compiler for first-party code; `accepts` allows the mode only with `trusted == true` and `Interpreter::run_v2` sets it only for processes whose policy is not untrusted (TRUSTED: never for an untrusted process, `TOIT_V2_CHECKED_FIELDS=1` turns it off); the soundness theorem (`theorem_soundness`, `lemma_run_wf`) is stated for programs without the mode, i.e. for every untrusted program |
