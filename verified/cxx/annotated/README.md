# VeriFast for the C++ that stays C++

The C++ inside the sandbox's security boundary that is not ported to
Rust/Verus (the interpreter glue to the allocator and GC, the message
encoder and decoder, blob argument decoding, a few helpers) is verified
with VeriFast 26.10, unbounded, on 64-bit and 32-bit. The pilot
(verified/CXX-ANNOTATED-PILOT.md) proved this works on hand-written C
renderings of the C++; this directory makes the rendering mechanical, so
that it cannot drift from the sources.

Run: `run.sh` (the whole matrix, also part of
`verified/check.sh --tests`, which skips it with a message when VeriFast is
not installed). Tools: `install-tools.sh` (VeriFast 26.10 and its Rust
front end, under /home/flo/work/opentoit-sandbox-artifacts/annotated-cxx).
The tagged-integer equivalence checks use ESBMC. The UTF-8 validator uses
Frama-C/WP and Alt-Ergo. Install them with `verified/cxx/install-tools.sh esbmc framac`.
What a run writes (Clang's AST dumps, the 32-bit renderings, logs, the
mutants' copies) goes to a directory per checkout under `work/` there
(`ACXX_WORK`, env.sh), and a lock serializes the runs of one checkout:
the scratch directory was shared, and two checkouts rendering at once
wrote the same AST dump twice ("2 definitions of toit::Instance::at_put").
The checks run as parallel jobs: the LP64 proofs together with
`render.sh --check`, the ILP32 proofs and the mutants after it (about 40 s
wall on 16 cores).

## The rendering: generated, not hand-written

Decision: **a mechanical translator**, `verified/tools/cxx_render.toit`. For
every function a sidecar (`*.render`) names, it reads Clang's JSON AST of
the real source (`clang-ast.sh`, the build's standard and defines), prints
it as C by the fixed rules below, and weaves in the annotations of the
sidecar. A sidecar holds, per function, a copy of its C++ text with the
VeriFast annotations (`//@ ...`, `/*@ ... @*/`) inserted between
statements, exactly as they would be written in place:

```cpp
@render src/messaging.cc toit::MessageEncoder::encode_array
bool MessageEncoder::encode_array(Array* object, word from, word to)
//@ requires encoder(self, ?ids) &*& self->nesting_ |-> ?n &*& ... &*& [?f]heap(?objs, ?H) &*& ...;
//@ ensures encoder(self, ids) &*& self->nesting_ |-> n &*& [f]heap(objs, H);
{
  if (from < 0 || from > to || to > object->length()) return false;
  write_uint8(TAG_ARRAY);
  write_cardinal(to - from);
  for (word i = from; i < to; i++)
  //@ invariant encoder(self, ids) &*& self->nesting_ |-> n &*& [f]heap(objs, H) &*& from <= i &*& to <= o_len(H(object));
  {
    if (!encode_any(object->at(i))) return false;
  }
  return true;
}
```

The copy is compared **token by token** (comments and whitespace aside) with
the function in the current sources; any difference is a drift error that
names the file, line and token. An annotation is anchored at the token that
follows it. The generated C (`*.gen.c`, committed for review, and the
32-bit one under the artifacts directory) is what VeriFast verifies;
`render.sh --check` fails when it is not what the sources and sidecars give.

What else is checked mechanically, so that the C means what the C++ means:

* **Constants.** Every constant a rendering uses is in one table,
  `model/constants.h`. For every place of use the translator writes a
  `static_assert` that the C++ constant, looked up where the code uses it
  (a struct derived from the class, for an unqualified name), has the
  table's value and type (`*.gen.constants.cc`); `constants-check.sh`
  compiles them for x86_64 and i686 (80 checks today). The same headers
  are the reference of verified/layout_check.cc for the Rust side, so the
  two models' layouts are tied to one source. A wrong value fails (the
  error indices of `FAIL` were found that way).
* **Overloads.** One C name is one C++ function: the translator records the
  canonical parameter types of every call and definition of a C name
  across all units and fails on two (`@overloaded` puts the types into the
  name).
* **Both widths.** The rendering is made again from the i686 AST (the
  implicit conversions differ: `int` is a word there) and verified with
  `-target ILP32`.
* **Drift self-tests.** `run.sh` changes a rendered function in a copy of
  the source only (a bound off by one, a strict comparison made non-strict)
  and requires the drift error.

The rules (all in the translator's header; anything else is an error, the
tool never guesses):

| C++ | C rendering |
|---|---|
| `T C::m(args)`, `this` | `T C_m(C *self, args)`, `self`; field `f` of `this` is `self->f` |
| static member, constructor, destructor | `C_m(args)`, `C_ctor(C *self, ...)`, `C_dtor(C *self)` |
| `obj->m(a)` on static class C | `C_m(obj, a)`; `obj.m(a)` is `C_m(&obj, a)` |
| `C::N`; unqualified `N` in class C | `C_N`; `C_N` if in the table, else `N` (checked at the place of use) |
| implicit conversion | a cast, except lvalue-to-rvalue, no-op, decay, derived-to-base (all classes are one opaque struct) and an integer literal's conversion; to bool is `!= 0`; nullptr is `0` |
| `T&` parameter / `const T&` | `T *` (argument by address, use `(*p)`) / `T` |
| local of a `@raii` class | destructor call at every exit from its scope |
| `return e;` followed by annotations | `{ T r = e; annotations; destructors; return r; }` |
| local whose address is taken | declared at the start of its block, initialized in place |
| discarded `std::atomic<uword>::operator+=` or `operator-=` | A single atomic addition or subtraction on the selected counter. The proof contracts create or consume the charge for the exact byte count. |
| release `ASSERT(c)` (`while (false && (c)) {}`) | a comment (never evaluated) |
| `while (auto p = expression)` with a pointer condition variable | A fresh local is initialized and tested at the start of each iteration. A null pointer exits the loop before the body runs. |
| a reference spelled in a macro | named by its declaring class (Clang's declaration ids) |
| `@render ... trusted` | the prototype and contract only; the body is still compared with the source |
| nested class `A::B` | struct `A_B`, members `A_B_m`, constructor `A_B_ctor`; an unqualified constant of an enclosing class is `A_N` (checked as `A::N`) |
| `a = C(x)` with the implicit assignment operator (Clang's `isImplicit`) | `{ C tmp; C_ctor(&tmp, x); (a).f = tmp.f; ... }`: member-wise, what the implicit copy and move assignments do |
| `@expand-typedef T` | the typedef written as the type it stands for on the rendering's target (`uhalf_word`: unsigned int on LP64, unsigned short on ILP32) |
| Copy or move construction of a `Method` value | A C struct copy. Both ABI checks require a trivially copyable, standard-layout native type with its bytecode pointer at offset zero and the size of one pointer. |
| Subtraction of two unsigned-byte pointers | Subtraction of `char *` values with the same addresses. The spawn-method proof requires both pointers to belong to the same bytecode image and the difference to fit the result type. |
| a default argument (`CXXDefaultArgExpr`) | its value written out; literals only (the expression is spelled in the callee's file) |
| a call of an `@overloaded` member | named by the declared parameter types of the member it refers to (in its class or out of line), not by the argument types (which differ per target: a literal is `int` = `word` on ILP32) |
| `@render ... truncating` | an implicit word-to-int conversion is VeriFast's truncating cast (the modular conversion GCC and Clang define and C++20 standardizes); only for code that checks the round trip (the int arguments of ARGS). Also uword-to-word and uint64-to-int64 (the decoder's cardinals: `word length = read_cardinal()`, checked for the sign and against what is left), and uword-to-int (wave 4: decode_rpc_request_external's `*id = read_cardinal()`). For CRC, explicit casts between `int64` and `uint64` are modular, as is a `uint64` left shift by a literal in [0, 63]. For the process random generator, unsigned 64-bit addition also wraps modulo 2^64. Unsigned word subtraction wraps at the target word width in the scavenger’s address tests, as does unsigned word addition for the biased metadata addresses. Other shift counts retain the usual proof obligations. VeriFast knows nothing of the value of such a cast by itself; `truncate_signed_id` (model/truncate.gh, wave 4, proved with Z3) gives it for a value in the target's range |
| `switch (c) { case V: ... default: ... }` | written as is: the labels (values from the constant table), a label's statement and the statements up to the next label, fall-through, `break` |
| `a op= b` whose computation type is not a's (`cursor_ += sizeof(uint32)`: an unsigned long sum for a word) | `a = (A)((C)a op b)`: the conversions C++ makes, written; `a` must be a variable or a field chain (evaluated twice) |
| `@modular-arguments C::C` | the implicit integral conversion of a constructor argument to an unsigned parameter is VeriFast's truncating cast (the modular conversion C++ defines; HeapTagScope's custom tags are negative numbers in a uword) |
| Clang's `__size_t` (the type of sizeof) | `size_t` |
| `do S while (false)` (a macro's statement wrapper: INT64_VALUE_OR_WRONG_TYPE of ARGS) | `{ S }`; an error when a break or continue of S would leave the do |
| `@render ... truncating`, an explicit `static_cast` narrowing a signed integer (`static_cast<time_t>(int64)` on a 32-bit time_t; Clang's NoOp over an IntegralCast for a typedef) | VeriFast's truncating cast (for code that checks the round trip) |
| an object of a struct spelled with its tag (`struct tm tm;`, a C header's struct) | `struct tm tm; tm_ctor(&tm);` (the constructor named by the tag) |
| an embedded class object initialized by a constructor | calls that constructor on the field address in C++ initialization order |
| `type=A\|B` on a method template | selects the unique instantiated signature matching one alternative for the current target, including ABI-specific integer spellings |
| `@static-member C::field` | a reference to the enclosing class’s static storage uses the sidecar’s C global after checking the Clang declaration identity and storage class |
| a default member initializer (Clang's `CXXDefaultInitExpr`, wave 5: the decoder's `size_ = INT_MAX`, `status_ = DECODE_SUCCESS`) | `self->f = value;` written from the AST's values, never from source text (the expression is spelled in the class, another file): integer and boolean literals, null, enumerators of the constant table (checked in the class's scope); anything else is an error |
| a delegating constructor (`C(a) : C(a, K) {}`, wave 5) | the target constructor called on `self`: `C_ctor__T1_T2(self, a, K);` |
| an out-of-line constructor `C::C` (wave 5) | found although it is named like its class (the lookup took it for the class) |
| a loop whose body has no braces, with an invariant (wave 5: `for (...) deallocate();`) | the annotation anchored at the body's first token is the invariant, written before the added `{` |
| a lambda `[&]() -> R { body }` (wave 6: the closures of `v2_allocate`) | `struct F_lambdaK { T v; ... };` (F the enclosing function's C name, K its lambda's position) and `R F_lambdaK_call(struct F_lambdaK *closure)` with the body, a capture `v` being `closure->v`; where it is created, a local `struct F_lambdaK closureK;` (start of the block) gets the values (`closureK.v = v;`, just before the statement) and the lambda is `&closureK`. A capture by reference becomes a copy of the value, which is the same because the translator checks: the lambda only reads its captures (every use an lvalue-to-rvalue conversion), has no parameters, is not `mutable`, captures no `this` and no objects by copy; it is an argument of a call (it does not outlive the statement); the enclosing function never takes a captured variable's address or binds a reference to it, and the creating statement does not assign it. Annotations inside the lambda are its function's (the contract at its body's `{`) |
| `T* v = new (std::nothrow) T(args);` (the `_new` of src/top.h; wave 6) | `T *v = T_new_nothrow(); if (v != 0) { T_ctor...(v, args); }` (the allocation a function the sidecar declares); the arguments evaluated after a successful allocation (C++17's order; C++11 leaves it open), so they must not assign anything (checked); only as a local's initializer |
| `delete p` (not an array) | `T_delete(p)` for p's static class (destructor and deallocation: a contract the sidecar declares) |
| a non-virtual base-class constructor | Calls the selected base constructor on the sidecar's receiver representation, forwarding the constructor arguments with their conversions. The base body can be rendered, as in the callback node hierarchy. |
| a local that hides another (a nested block's `encoder`; VeriFast rejects hiding) | renamed with a suffix (`encoder_1`), references by the declaration's id; annotations use the rendered name |
| a call through a function-pointer local or parameter (`entry(process, args)`) | the C call through the pointer (its contract is the function type's) |
| a default member initializer `-N` | written out |
| a function template instance taking a closure (`@render FILE f lambda=ENCLOSING[#K]`) | the instance whose closure parameter has that lambda's type, as one C function `f__F_lambdaK`; the closure parameter is a pointer to the caller's struct (checked: the instance only calls it, `f()` being `F_lambdaK_call(f)`, so no copy escapes); the sidecar holds one copy of the template's text per instance |

Each rule added after the pilot has a self-test in `tests/rules.cc` and
`tests/rules.render` (rendered, compared with the committed
`rules.gen.c`, constants checked, verified on both widths).

### The other route: VeriFast's C++ front end in place

Tried (probes `probes/cxx_shim.cpp`, `cxx_shim2.cpp`). Routing the
integer-pointer conversions of `objects.h` through two functions is not
enough:

* the front end rejects **every pointer cast**, not only
  `reinterpret_cast`: `static_cast<uword*>(void*)` and C casts too ("Expression
  of kind 'CXXStaticCastExpr' / 'CStyleCastExpr' is not supported"); only
  integral `static_cast` passes. So one shim function per target pointer
  type (`uword*`, `Object**`, `uint8*`, `HeapObject*`, ...), and objects.h
  has 50 `reinterpret_cast`s and 12 pointer `static_cast`s to replace;
* a **template** shim (`template <T> T* vm_word_to_ptr(uword)`) does not
  parse: a contract cannot mention `T`;
* `static const` members (132 in objects.h) are **globals**, not constants
  ("No matching points-to chunk: ulong_integer(Object::HEAP_TAG, _)"); so are
  `static constexpr` ones;
* every member function needs `[_]C_bases_constructed(this)`: VeriFast
  models construction, and VM objects are never constructed;
* ghost casts to typedef'd pointer types do not parse (`(uword *)p`; only
  `(unsigned long *)p`).

In place, `objects.h` would need: `vm_ptr_to_word(const void*)` and one
`vm_word_to_X(uword)` per pointer type, used by every accessor instead of
the casts (bodies hidden from VeriFast under `#ifdef __VERIFAST__`); every
`static const` turned into an enumerator or a macro, or given a ghost
points-to fact; contracts carrying `[_]X_bases_constructed(this)` (from the
heap predicate); and the standard headers replaced (the pilot's `shim/`).
That is a rewrite of the header's idiom, with the risk in the C++ that
behaviour changes, for no more assurance than the generated rendering
gives. Not proposed; reporting the front end's missing casts upstream is.

## Status

`run.sh`: 40 sidecars (one the translator's self-test), 413 rendered functions (21 contract-only) and 4 closures, proved
for LP64 and ILP32; reverted-bug and contract mutants, including an ILP32-only
check, and 2 drift tests
(each proof 0.1-4 s, the encoder 8 s, the decoder 10-40 s and time_info
25-45 s on loaded cores). Lines: `metrics.sh` (C++ = the
rendered functions' lines; annotations among them; then the hand-written C
and annotations of the verbatim sections: trusted prototypes, predicates,
lemmas).

| Unit (sidecar) | Functions | Status | Assumptions | C++ / annot. / trusted C / annot. | Self-test |
|---|---|---|---|---|---|
| Object model (`model/objects.render`) | Process::program/on_program_heap, program_image_size, FlashAllocation::size_no_assets and Header::size, Program::root/class_id, Object::unmark, is_smi, is_heap_object, Smi::from/value/cast, HeapObject::cast/_raw/_raw_at (2)/_at/_word_at/_half_word_at/header/class_id/class_tag/has_class_tag, Instance::_offset_from/at/cast, Array::_offset_from/length/at/cast, String::_internal_length/content_on_heap/_external_length/_external_address/as_external/_as_utf8bytes/cast, String::Bytes (ctor, address, length), ByteArray::raw_length/has_external_address/external_tag/_offset_from/content (2)/_external_address/as_external (2)/cast (2), ByteArray::Bytes and ConstBytes (ctor, address, length), Double/LargeInteger::cast, LargeInteger::value/_initialize/_set_value, HeapObject::_int64_at/_int64_at_put, is_instance/array/byte_array/double/string/large_integer | verified | `Double::value` (contract only); `unsigned_cast` (a template: identity on `uint8*`); the heap predicate is the allocator/GC invariant (bridge `heap`): strings and byte arrays with internal or external content, an external byte array owning its bytes only when tagged RawByteTag | 422 / 486 / 73 / 936 | drift tests; the encoder's and byte_content's mutants exercise it |
| Spawn method (`prims/spawn_method.render`) | spawn_method, Process::spawn_method/group, ProcessGroup::v2_methods, Method::is_valid/header_bcp, Program::is_format2/absolute_bci_from_bcp, V2MethodTable::index_of_entry/entry_of | exact result for either image format, terminating binary search with in-bounds packed-record reads | loader supplies the image bytes, a valid method position and the sorted table for a format-2 lookup. The two const bytecode-list accessors and the trivial Method copy are checked against native types. | 54 / 50 / 9 / 61 | nonshrinking search interval, missing entry reported as zero, wrong format tag, wrong legacy sentinel |
| Finalizers (`prims/finalizers.render`) | add_finalizer, remove_finalizer, ObjectHeap::add_callable_finalizer/prepend_callable_finalizer/remove_callable_finalizer, all four callback-node constructors, the three finalizer nodes’ roots_do methods and RootCallback::do_root, HeapObject::has_active_finalizer/set_has_active_finalizer/clear_has_active_finalizer, _set_header, has_forwarding_address, forwarding_address | VeriFast checks argument decoding, the exact outcome on each path, the original argument slots, and the effect on the object header and callback registrations. Reading a forwarded header observes its destination. | VeriFast assumes successful allocation supplies fresh storage of the requested dynamic type, and assumes native deletion releases a detached node. VeriFast proves the ownership transfer on insertion and checks a hand-specialized removal loop for every finite queue. ESBMC compares the modeled link updates with native prepend on symbolic endpoints. The native unlink method and the removal proof body adapted to native types emit identical code in the two Clang -O1 checks. The header writes and preservation of the VM heap are verified separately. The shared process, program and heap contracts apply. | 120 / 96 / 33 / 160 | removes the read-only or instance guard, reverses the duplicate check, requests an ordinary callback for a weak map, changes the allocation error, skips the forwarding pointer, drops either header write, sets the wrong bit, allocates the wrong node kind, stores the key as the callback, overwrites the tail of a nonempty queue, skips tail repair on removal, reverses the removal key test |
| Blob decoding (`blob/byte_content.render`) | Object::byte_content (the recursive 5-argument one, the 4-argument one, the Blob one), Blob ctor, HeapObject::can_be_toit_finalized | verified: a successful result lies in the content of ONE live string or byte array (internal, or raw external: never a proxy's struct), a string for STRINGS_ONLY; recursion depth bounded by MAX_BYTE_CONTENT_DEPTH; heap read-only | the loaded image supplies a table of tagged class IDs that agree with its heap objects | 79 / 43 / 1 / 28 | 357d1127 (#3373): without the depth limit the recursive call fails at `depth + 1 <= 8`; without the slice's `to <= length`: the pointer leaves the blob |
| MutableBlob decoding (`blob/mutable_byte_content.render`) | Object::mutable_byte_content (5-argument, 4-argument, MutableBlob), MutableBlob ctor; model: Instance::at_put (with the heap update), HeapObject::_at_put, on_program_heap, heap growth and blob hole lemmas | verified: a successful result lies in the content of ONE live byte array (internal or raw external) outside the program heap; the heap only grows (the copy-on-write branch allocates, copies the immutable content with a legal memcpy and stores the new backing and `true`); recursion bounded | the allocator (`Process::allocate_byte_array`: a fresh byte array of the asked length outside the program heap, nothing else changed), `Process::on_program_heap` (an address range: `in_program_heap`), the true object is a heap object, the write barrier (card table outside the model), the error roots | 76 / 54 / 4 / 2 | 357d1127 reverted here too: the recursive call; without the program-heap check: `in_program_heap == false`; without the external tag check (both decoders): `blob_ok` |
| Message encoder (`encoder/`) | encode_any (all branches), encode_array, encode_list, encode_map, encode_copy (inline, out-of-line copy with its malloc and terminator), encode_byte_array (transfer, deduplication), reserve_external, is_too_large, size, total_size, encoding_for_size, encoding_tison, the writers write_uint8/cardinal/pointer/uint32/uint64, TisonEncoder::encode and payload_size, NestingTracker ctor/dtor; the cardinal's byte bound (`cardinal.c`, Z3) | verified: memory safety (reads inside objects, blob copies inside the blob found by the proven byte_content, writes inside the buffer, the tables copied_/transferred_ written below MESSAGING_ENCODING_MAX_EXTERNALS), no overflow or lossy conversion on either width (cursor_ + external_bytes_ stays below the limit plus ENC_SLACK = 32), heap read-only | **ONE assumption: `two_pass_room`** (below); contract only: `Process::policy`, `PrimitivePolicy::restricts_messaging`, HeapTagScope, `bit_cast`; the malloced copies are leaked into the table (ownership not modelled) | 334 / 230 / 51 / 116 | f708ad5d: count (underflow at `to - from`), read past the backing (loop bound), map past the backing; the 32-bit size fix weakened in encode_copy and in the transfer (the size bound fails; on ILP32 the sum overflows); one reservation too many (the table bound fails); the terminator read from the content (memcpy past the blob) |
| Message decoder (`decoder/`) | TisonDecoder::decode (tison_decode's untrusted input), MessageDecoder::decode (IPC), decode_any (the switch, every tag), decode_string, decode_byte_array (both inline: copies; out of line: IPC blocks), decode_array, decode_map, decode_double, decode_large_integer, decode_integer (wave 4: canonical integers), decode_external_data and decode_rpc_request_external (wave 4: the external message handlers; the data handed out is an out-of-line block of the message or a malloced copy, `ext_data`), read_uint8/cardinal/cardinal_64/uint32/uint64/pointer, register_external, success, decoding_tison, overflown, remaining, externals_count, mark_malformed, mark_allocation_failed, NestingTracker; the digits' bound (`radix.c`, Z3); model: Array::at_put, Instance::at_put(Smi*), Smi::zero, the allocator's contracts | verified: for any input bytes (TISON) every read is inside the input (past the end the readers return 0), the cursor stays below the length + 16 on both widths, every length is checked against what is left before the copy or the allocation of that size (`length <= cap - c`, asserted), the recursion is bounded (64), a cardinal fits 64 bits and a length the word, integers are canonical (a large integer only outside the smi range: the allocator contract requires it), the externals table is written below its bound (the FATAL), the heap only grows (new objects; the new array's elements and the map's fields written), a success is a good reference and TISON consumed its input exactly; a failure leaves a well-formed heap | TISON: none beyond the model and the allocator; IPC: **two named assumptions, `ipc_room` and `ipc_external`** (below); contract only: the allocator (CONTRACTS.toml, C++-only contracts), `bit_cast`, `fail`, `Array::max_length_in_process` | 587 / 619 / 70 / 694 | seventeen checks taken out, each rejected on both widths unless noted: the length checks before the inline string and byte-array copies, before the array and map allocations, the nesting limit (#3362), the fixed-size readers' bound (read_uint64; read_uint8 in the header), read_cardinal_64's size check (#3362) and digit check (wave 3), read_cardinal's word check (ILP32 only: dead on LP64), the two smi magnitude checks and decode_integer's smi range check, decode_external_data's two inline length checks (wave 4), the externals table bound |
| Receive path (`decoder/`, wave 5: the ownership of the out-of-line blocks) | the primitives task_receive_message, main_arguments, spawn_arguments (every path: finalizer to run, no message, monitor notification, system message decoded / allocation failure / malformed / allocation of the result array failed); MessageDecoder's three constructors (delegating, default member initializers), allocation_failed, malformed_input, register_external_allocations, remove_disposing_finalizers, deallocate (static, and the recursive walk); SystemMessage's destructor, free_data_and_externals, free_data_but_keep_externals, data/type/gid/pid; the decoder's out-of-line branches, read_pointer, register_external and mark_allocation_failed with ownership | verified: no leak and no double free of a message's buffer and blocks on every path. The message (`msg_whole`) owns its buffer and its blocks; read_pointer hands out block j of the message (in order), a decoder for a process lends it to the object it allocates (`finalized`: the VM finalizer frees it), keeps it when the allocation fails; on a failure remove_disposing_finalizers takes every lent block back (the message is whole again: retried or deleted), on a success every block was lent and only the buffer is freed; deallocate frees each block once and all of them. The primitive heap contract up to finalizer bits (`grows_class`: classes and lengths kept) | **the IPC assumptions, now seven narrow ones** (`ipc_begin`, `ipc_room`, `ipc_pointer`, `ipc_external`, `ipc_length`, `ipc_end`; none creates ownership) and the GC's `gc_owns` (CONTRACTS.toml); contract only: the mailbox and the arguments slots of a process (`mailbox`, `queued`, `dying`, `main_args`, `spawn_args`: a queued system message owns encoded data, its type, gid and pid are smis), `HeapObject::clear_has_active_finalizer` (gives the block back: the GC side, which 05159afd fixed), the allocator's external string and byte array, register_external_allocation, callback root validity, virtual callback dispatch, native node deletion, ObjectNotifier | (in the decoder's row) | receive-malformed-delivered and arguments-malformed-delivered (the 05159afd fix taken out: `st != MALFORMED` fails), receive-no-give-back, receive-give-back-bound (one finalizer bit left), arguments-drop-leak, receive-success-free-all (blocks freed under the objects), decoder-unregistered-block, deallocate-double-free, deallocate-leak |
| The Rust/C++ boundary (`ffi/interpreter_v2.render`, wave 6; stack growth since wave 1, formerly `grow/`) | toit_v2_grow_stack, Stack::v2_copy_to, Stack::v2_set_records; toit_v2_allocate_instance and toit_v2_allocate_double with their lambdas and the two instances of `v2_allocate` (closure rules); toit_v2_try_allocate_large_integer, _double, _array, _string, _byte_array; toit_v2_current_stack, ObjectHeap::task, Task::stack and Task::set_stack; toit_v2_primitive and v2_primitive_failed (the retry protocol), Primitive::unmark_from_error; v2_process | verified against both sides of CONTRACTS.toml's gc_grow_stack, gc_allocate_instance, gc_allocate_double, gc_call_primitive and allocator_* (contract_check.toit compares every conjunct): the VM state at a GC point is `vm(p, v, n)` (stack object, header fields, bytes, heap, epoch count), the GC's guarantee `gc_equiv`; at most three collections per call (the loop bounds), so an unchanged epoch word means nothing moved (the core keeps its views on that); a primitive runs only with its table arity on its frame's slots, the retry re-reads the current stack after each GC; the results are the allocator's objects (`alloc_post`) or the primitive's completion (`prim_done`) with the status and word the core gets | **three named assumptions** (`gc_equiv_trans`, `stack_copy_equiv`: the `stack` bridge as a lemma, `prim_retry`: a call that failed for want of memory has no visible effect); contract only: Scheduler::gc (at most one collection, `gc_equiv` or nothing), the allocator (the model's, plus Process::allocate_string(word)), allocate_stack, the policy table (`PrimitivePolicy::at`: an entry's arity is what its function reads), the primitives (function type `Primitive_Entry`: prim_out, at most PRIM_EPOCHS task switches, an out-of-memory failure leaves the stack alone), v2_validate (debug aid), the write barrier | 332 / 322 / 35 / 374 | grow-stack-unbounded, grow-stack-word-range; ffi-primitive-arity (the arity check: the primitive's precondition fails), ffi-primitive-stale-stack (the stack read before the GC: the arguments' address is not the current stack's), ffi-primitive-retries and ffi-allocate-retries (a loop bound: more collections than the epoch accounting allows) |
| Array initialization (`ffi/array_init.render`) | `Array::_initialize_no_write_barrier`, both slot writers and the length setter | from uninitialized storage, sets the length and initializes every slot to the supplied filler | allocation of the fresh object and its header | see metrics.sh | skip the last slot |
| The external handlers' sender side (`sender/external_send.render`, wave 6) | ExternalSystemMessageHandler::send_ (data and encoder), reply_rpc; the encoder they use: the one-argument constructor, the destructor, take_buffer, encode_bytes_external, encode_rpc_reply_external, reserve_external, write_uint8/cardinal/pointer, size, encoding_for_size/tison; SystemMessage's constructor from an encoder (with its base class) and free_data_but_keep_externals | verified: the encoded buffer is freed once or handed over inside the message, the caller's data (a malloced block) goes to the receiver with a sent message, is freed on a failure with free_on_failure and stays the caller's otherwise, on every path (no message allocated, no receiver, quota); the write pass fits the buffer the size pass measured (exact byte counts: `card_len`, `reply_size`; no assumption), memory safety, no overflow, both widths | contract only: the scheduler's send_message (queues the message, or deletes it with free_on_failure, or gives it back), the message's allocation and deletion (only without a buffer: its references are the caller's), the process and VM accessors, strnlen; an external handler's encoder transfers nothing (neuter: `requires false`) | 166 / 145 / 64 / 256 | sender-encoder-owns-buffer (the fix reverted), sender-free-callers-data, sender-delete-with-buffer |
| Primitive `string_write_to_byte_array` (`prims/`) | the primitive with the ARGS/FAIL expansion (Blob and MutableBlob decoding by the proven byte_content / mutable_byte_content, word arguments), Blob/MutableBlob constructors and accessors | verified: the primitive heap contract in VeriFast terms (the heap only grows, objects keep class, length and external address), the copy inside the two contents (source: a string or byte array; destination: a writable byte array outside the program heap; the source range survives the destination's copy-on-write), legal memmove | none beyond the model and blob units | 21 / 59 / 7 / 22 | af4ba7ab: memcpy fails at its precondition; verifies with the two byte arrays assumed distinct |
| Primitive `time_info` (`prims/time_info.render`, wave 4) | the primitive with the ARGS expansion (int64 and bool), floor_div, floor_mod, is_leap_year, days_from_civil, weekday_from_days, utc_fields, os_localtime, equivalent_year, local_fields, Smi::is_valid32; model: Array::at_put(Smi*) | verified: for every int64 timestamp no signed overflow and no lossy conversion (coarse bounds of every step, lemmas per step so that the proof sees bounds, not division equations), every stored field a smi, the primitive heap contract; not the correctness of the dates | the C library's `localtime_r` (fields in their C11 ranges), memset of the struct, the implicit constructors (do nothing), `Process::false_object`, `fail` (UNREACHABLE) | 135 / 72 / 32 / 109 | the red-team round 4 overflow reverted (`days * SECONDS_PER_DAY` underflows); local_fields without its year check (the shift overflows); the primitive without its year check (not a smi; on ILP32 the conversion to word) |
| Primitive bitmap `byte_zap` (`prims/byte_zap.render`) | the primitive with the ARGS expansion (MutableBlob by the proven decoder; the int argument with its round-trip check, `truncating`), MutableBlob ctor and accessors | verified: the primitive heap contract, the memset covers exactly the destination's range in a writable byte array, a smi result | the shared argument-error proof | 12 / 24 / 4 / 2 | one byte past the end: the memset fails |
| Integer argument failure (`prims/argument_error.render`) | `Primitive::return_not_a_smi` | exact tagged error for a large integer or another VM value; preserves the heap | object model | 8 / 7 / 1 / 14 | return the type error for a large integer |
| Primitive `byte_array_is_valid_string_content` | Blob and integer arguments, range check and validator call | the validator receives a readable slice; the heap and argument slots are preserved; the result is a live heap reference or a tagged error | boolean roots | 13 / 34 / 7 / 6 | omit the upper bound |
| Process IDs (`prims/process_ids.render`) | two primitives, ID assignment and three accessors | exact current and boot IDs, permanent exhaustion at the representable limit | live process ID, VM singleton and scheduler lock | 26 / 16 / 10 / 17 | restart after exhaustion, weaken upper bound, change current ID, change absent boot ID |
| Heap limits (`heap/limits.render`) | Chunk::size, Space::size, combined byte count, growth and cap, limit installation, promotion flag, external allocation check and status | Space::size terminates and sums every chunk’s end minus start, preserving the list and its bounds. The calling code computes the post-GC limit and remaining capacity for all word-sized readings, including a combined size above the signed or unsigned word range. A request must have a nonnegative size that fits the remaining capacity. | The allocator supplies stable finite lists ending at their own anchors, ordered chunk bounds, and a combined size that fits a word. The external reading uses the atomic accounting checked below | 77 / 68 / 15 / 58 | count half of each chunk, count the old space twice, overflow in addition or doubling, omitted cap, exact fit, promotion at equality, negative request, inverted status |
| Heap chunk iterator (`verified/cxx/harness/chunk_iterator.cc`) | the native `ChunkList` const iterator used by `Space::size` and mutable iterator used by the young-space scan | the empty list stops at its own anchor, dereferencing a nonempty cursor recovers its chunk, and advancing a copy follows the forward link while preserving the original cursor. Construction creates an empty circular list. Appending a detached chunk joins it to the old tail and preserves its bounds. An existing mutable tail cursor advances to the newly appended chunk and then to the original end cursor. Unlinking it restores both endpoints | valid chunk and anchor links at the step being checked. The heap-limit proof uses these iterator operations for arbitrarily long finite lists. | — | empty, singleton and distinct endpoints on both word widths |
| External memory accounting (`verified/cxx/harness/external_accounting.cc`) | `ObjectHeap::external_memory`, `register_external_allocation`, `unregister_external_allocation` | ESBMC checks the deployed C++ with arbitrary starting counters. A registration adds exactly the requested bytes to the current count and the lifetime count (modulo 2^64). A release subtracts only from the current count. The unsigned reading preserves the entire word. | nonnegative sizes, sufficient registered bytes for a release, room in the unsigned current count for a registration, and ESBMC's atomic operations. The single-operation proof starts from arbitrary counters and also checks the empty-heap constructor. A separate two-thread harness checks every modeled interleaving of one registration with one release, with enough initial bytes and remaining capacity for either order. | — | native signed-limit crossing and release (`tests/ctest/heap-limits-test.cc`); replacing the atomic addition with a load and store loses an update in the two-thread harness |
| GC counts (`prims/gc_count.render`) | primitive, two accessors, counter increment and collection accounting | exact counter selection, updates for each collection type, rollover | live process heap with valid counters and the collection type returned by the collector | 25 / 13 / 4 / 7 | skip rollover, omit compacting collections from the full count, return the wrong counter |
| Primitive `word_size` | complete body | the returned smi encodes the target word size in bytes | Smi::from | 4 / 2 / 1 / 0 | return bits |
| UTF-8 (`utf8/`) | Utils::utf_8_to_16, bytes_in_utf_8_sequence, payload_from_prefix | verified (Z3) | none | 57 / 45 / 1 / 169 | 07c24665: UB shift at payload_from_prefix; without the length check: the read past the input. Also checks sizing failure, surrogate width and initialization of the second output unit. |
| UTF-16 (`utf8/utf_16_to_8.render`) | Utils::utf_16_to_8, Utils::utf_16le_to_8, read_utf16le_unit | verified (Z3) | readable little-endian byte pairs and an optional writable byte buffer | 60 / 73 / 1 / 70 | byte order, four-byte lead, surrogate replacement, output capacity and write count |
| Rust raw memory (`rust/`) | view.rs: string_len, string_byte; trial: field, array_length, element | verified (VeriFast Rust, host) | predicates over the words (bridge `heap`) | — | `i <= len` fails at the read |

Not attempted, in order of exposure, with what blocks each:

| C++ | Blocker | Estimate |
|---|---|---|
| the two-pass assumption of the encoder, proved | a ghost encoding function (fixpoint over the heap and the encoder state: cursor, externals, transfers, the early stops) shown to be what both passes compute, the write pass ahead by TISON's payload cardinal | 5-7 days |
| take_buffer, the destructor, encode_bytes_external, encode_rpc_reply_external, encode_arguments, encode_bundles | trusted callers (C or the boot), not reachable with untrusted data; the copied_ table would need its ownership modelled (the malloced copies) | 1-2 days |
| the decoder's remaining callers and the rest of the sender side: tison_decode (the Blob argument is the content of a heap object, which the allocations must not touch: the allocator's contracts over `heap_holes`), ExternalSystemMessageHandler::run (the handed-out block: decode_external_data gets it from the message, wave 5), process_send and spawn (the encoder's copies of any object graph and its transfers: take_buffer neuters byte arrays, a heap change; the scheduler's send_message_from with its policy checks; the mailbox quota accounting of Process::_append_message and remove_first_message). Wave 6 did the external handlers' sender side (`sender/`): its encoder model (`ext_encoder`, copies owned in the table) is the start for the general encoder | the encoder unit's tables with ownership of the copies (enc_tables) and of the transferred bytes; the holes form of the allocator's contracts | 3-4 days |
| the IPC assumptions (`ipc_room`, `ipc_external`), proved | the encoder's ghost encoding (the two-pass assumption's) as the decoder's input: decoding it reads what the encoding wrote | with the two-pass proof, 3-4 days more |
| ProgramOrientedEncoder / EncodeVisitor (encode_error, encoder.cc) | Object traversal and the program and stack data used to produce a trace. The native output buffer has a separate LP64 and ILP32 proof. | 4-5 days |
| toit_v2_allocate_exception (Verus contract gc_allocate_exception), toit_v2_allocate_array (the checked loop only) | a word from Rust stored as an object reference (the exception's value or the checked loop's filler): in VeriFast's C model an integer-to-pointer cast has no provenance, the model's references are pointers with provenance; either an address-based `good` in the model or `-assume_no_provenance` for these functions alone (the exposed-provenance semantics the Rust side has, `IsExposed`); the exception also needs encode_error | 1-2 days (the provenance), 4-5 days with encode_error |
| the fields of a new instance (null), a double's bits, a byte array's zeros (Verus `new_instance`, `Body::Double(bits)`, `Body::Bytes(0...)`) | outside the VeriFast heap model (only the header of a double is modelled; blob contents unconstrained): the allocator's contract cannot say them | 1 day (payload words in the model) |
| the remaining C++ primitives of the untrusted set (see the coverage inventory below) | Task, message and timer primitives depend on scheduler contracts | 0.5-1 day each |

The C++ write guard checks membership in the half-open interval starting at the
loaded program's address. The process constructor caches the byte length from
the flash header's 16-bit page count. VeriFast proves that conversion, including
the zero length for an absent program, and the address comparison used by
mutable blob decoding. ESBMC checks the native packed-header read and compares
the guard with a wider-integer interval for arbitrary machine-word inputs on
both ABIs. The native harness also checks the address and length written by
`v2_program_tables` for Rust. The cross-language layout test checks both offsets.
The loader still supplies a live image of the declared length, and
the process invariant ties the cached length to that image.

CRC, time and decimal parsing share the proof of `Primitive::integer` in `prims/integer.render`.
A small result encodes its exact input and preserves the heap. Outside that
range the allocator either supplies a fresh large integer while preserving
all existing objects, or the primitive marks the allocation-failure root
and preserves the entire heap. The allocator contract supplies the new
object's class and payload. ESBMC checks the C++ allocation body given fresh
raw storage or exhaustion. It checks the requested size, class ID, tag and
full signed value. The initializer and getter copy eight bytes so a payload
can start at a four-byte boundary. VeriFast tracks those bytes through the
write and read and carries the payload equality to the Rust boundary and
primitive boxing helper. Raw space allocation and its relation to the
abstract heap remain trusted.
The CRC loop borrows each input slice for one read, so the data and byte
table may overlap. The list-table case checks the backing array and decodes
each selected entry. The primitive postcondition covers sandbox safety.
The CRC algorithm suites check the checksum values.

The encoder, decoder and blob validation primitive import the same generated
`Utils::is_valid_utf_8` declaration. VeriFast checks its C++ wrapper.
Frama-C/WP checks the implementation in `src/utf_8_validator.h` for each
word width. Given a readable slice of any nonnegative length, both ASCII
loops and the state-machine loop terminate, read within bounds and leave
caller memory unchanged. The word read uses the C library contract for
`memcpy`. The postcondition leaves the returned boolean unspecified.
Run `run.sh --quick utf8` for the validator and conversion proofs.

The object-model rendering imports contracts for `Smi::from`, both
`Smi::value` overloads and the signed 64-bit `Smi::is_valid` instantiation. VeriFast checks portable arithmetic definitions
in `model/smi.c` against the rendered declarations for each word width.
ESBMC compares the same definitions to the release C++ inline functions
in `src/objects.h`, for every in-range integer and every even tagged word.
The range test covers every signed 64-bit input on each target.
These operations have no loops or heap loads. The comparison
uses ESBMC's target semantics for pointer casts and signed shifts.
Run both checks with `run.sh --quick smi`.

The FFI rendering uses the release configuration with optional hardware profiling disabled.

### EC618 mailbox atomics

Run `run.sh --quick ec618-mailbox` for the source-level checks. To check the
Cortex-M3 code emitted for the event worker, pass the EC618 release build's
event-source object to the instruction checker:

```sh
python3 verified/cxx/annotated/heap/check_ec618_mailbox.py path/to/event_sources/uart_ec618.cc.o
```

After `make ec618-relocations EC618_BYTECODE_FORMAT=2`, check both final
links in the selected EC618 build directory. For the default directory run

```sh
python3 verified/cxx/annotated/heap/check_ec618_mailbox.py build/ec618/toit-slot-{a,b}.elf
```

In a linked image the checker verifies resolved branch destinations and
singleton addresses. The relocation build separately compares the
relocated canonical body with the independently linked slot B.

The checker uses ARM GNU objdump and Z3 and accepts explicit paths via
`--objdump` and `--z3`. It checks the two publish loops, UART exchange and
completion-bit clear, including retry branches, barriers and the position
of the generation store and load. The same gate follows startup, both producer
paths, worker dispatch and queue retirement. For a relocatable object it
checks the call relocation types, targets and branch addends. It binds each
singleton load or store to the same symbol at offset zero. Under the Cortex-M exclusive-monitor and
barrier semantics, each failed attempt preserves memory and retries, and each
successful attempt implements the specified word update. Eventual success
under contention is an additional hardware and scheduling assumption.

The scheduler and completion-semaphore checks can also run independently of
the historical allocator layout. Supply the same base ELF used for the slot
links. Both final format-2 slots passed against base fingerprint
`f0ae7c907be49d8af02ea2dbcfa6aecf`.

```sh
python3 verified/cxx/annotated/heap/check_ec618_threads.py path/to/base.elf build/ec618/toit-slot-{a,b}.elf
```

### EC618 firmware allocator checks

For current format-2 slots, check the GC range, metadata reservation request
and descriptor publication against the base used for linking. The same check
validates all six table placements, the initial page-type fill, and lookup
arithmetic. It follows the same metadata request through base heap registration
and first-fit page allocation under the page ownership and exclusion contracts.
It also follows normal object-memory teardown and both setup rollback paths
to metadata release, then checks the base allocator’s release of a live page run.
The linked chunk check covers admission, construction of the initial spare,
owned-chunk metadata fills, space insertion, object construction and collector size reads, scavenger spare
selection, copy capacity, copying and forwarding,
survivor and spare handoff, and page-type clearing before chunk release. The same command
checks small-block bucket selection, splitting and zeroing, all four
coalescing cases, boundary-tag repair, free-list updates, and
the return of a fully coalesced arena to the page allocator. It runs the
scheduler proof on the same base, including SysTick and PendSV setup, and
checks which task-tag table entries the linked allocator wrappers read and write.

```sh
python3 verified/cxx/annotated/heap/check_ec618_gc_range.py path/to/base.elf build/ec618/toit-slot-{a,b}.elf
```

Run the following check against the linked base ELF used by the device.
It requires ARM GNU objdump and Z3 on PATH. The script also accepts
`--objdump` and `--z3` paths.

```sh
python3 verified/cxx/annotated/heap/check_ec618_memmove.py build/ec618-base/base.elf
```

The checker matches the allocator call and the forward copy instructions,
then checks loop initialization, termination, bounds and byte preservation
for every lower destination and nonwrapping source range. A change in the
matched code requires reviewing the instruction model against the new ELF.

To check GC metadata fills, supply the base and the linked VM slot ELFs. The same gate checks the dynamic
completion semaphore constructor, initial queue fields, worker give, join
receive and deletion path. It checks the linked count arithmetic for both
possible token counts, including a second give to a full semaphore, and
follows the empty receive through its event-list calls and retry branches.
The linked timeout helper preserves an indefinite wait. For finite waits the
checker compares expiry and remaining ticks with a 33-bit elapsed-time model
across at most one wrap between samples. The linked wake and queue-unlock
checks cover ready and pending-ready insertion, the priority comparison and
the number of deferred wakes. For indefinite waits the checker also follows
event-list insertion and the transfer from the ready list to the suspended
list. Given a valid sorted list, it checks equal-key ordering and every
word changed by the insertion.
For a single worker and exclusive joiner the gate explores completion-token
publication, consumption and retirement, including preemption immediately
on critical-section exit. It checks the linked worker's remaining instructions
and the joiner's queue release, descriptor release and handle reset.
The checker follows the direct branches used by chunk initialization and
destruction to the base memset and proves the loop's byte effect for every
32-bit length. For page classification it also checks the compiled range
test and fill arguments against the slot's debug field layout. It symbolically
executes the chunk initializer and checks all four calls' byte values and
extents against their respective tables. For firmware setup it checks the
page-rounded reservation size, placement of all six tables, four commit calls,
page-type fill and five stored biases on the successful path. The supplied heap
range must be nonempty with a representable page-rounded end. The checker
traces the release statistics wrapper and verifies these properties for the
linker fallback and the registered range in the historical allocator ELF
(manifest fingerprint `b11a03ffa2790e3009abc87587810b4b`). It checks the
registration arithmetic, descriptor writes, both initial free-list fragment
insertions, bounds loads and statistics output stores. This assumes serialized initialization and preservation of
the live allocator header by subsequent heap operations. For either reported range the
checker follows the seven-page request into the base allocator, compares its
compiled search with first-fit for every occupancy pattern, and checks the
descriptor writes and zero-fill extent under exclusive ownership. It follows
metadata teardown through base `free` and checks the status changes and
counter deltas for every legal ordinary page extent and neighbor condition.
The base check also follows the heap lock through task suspension, the
application PendSV vector and suspended switch path, and the decrement on
unlock. For the outermost resume it checks the linked list operations, ready
queue selection, deferred tick replay count and PendSV request. The list
proof decodes both splice helpers and checks their exact memory effects,
including cursor repair and the embedded sentinel. On first task registration
the checker verifies initialization of all 61 list headers and publication
of the delayed-list pointers. It also checks the task constructor's item
owners, container fields and priority clamp. The task frame check covers
the dynamic creation path, initial register slots, saved stack pointer and
SVC restore layout for valid word-aligned stacks of 18 to 65,535 words.
The separate `ec618-thread-spawn` ILP32 gate extracts the current VM wrapper
and checks admission, publication and failure cleanup under modeled RTOS calls.
It also exercises synchronous entry, joining before or after completion,
and immediate resource reclamation when the worker signals. It runs the
production thread map through parent/worker switches, including worker
completion inside the modeled RTOS task creation call.
The `ec618-thread-map` gate checks lookup, insertion, replacement and
removal in the configured map, including cache publication at interrupt
mask restoration. This assumes
valid scheduler objects, priorities and sorted delay lists. The linked tick
check covers suspended tick accumulation, wraparound, removing the due prefix,
moving tasks to their ready queues and the resulting yield decision. Interrupt-side heap access remains a dependency. Supply
unstripped slot ELFs with DWARF and install pyelftools. The checker accepts
the same objdump and Z3 options.

```sh
python3 verified/cxx/annotated/heap/check_ec618_memset.py build/ec618-base/base.elf build/ec618/toit-slot-{a,b}.elf
```

The allocator ABI check uses Python with pyelftools and CBMC. It reads the
instructions, alignment literal and port entry addresses from the supplied
base ELF. Pass `--cbmc` to select the verifier executable.

```sh
python3 verified/cxx/annotated/heap/check_ec618_allocator_abi.py build/ec618-base/base.elf
```

The check follows the linked implementations of `aligned_alloc`, `malloc`,
`realloc` and `free` to their port entry points. It checks the arguments, the
original return address, balanced stack use and the early return for
`free(NULL)`. Unsupported instructions fail verification.

### The primitives of the untrusted set

The untrusted policy allows 141 core primitives, `bitmap.byte_zap`,
`bitmap.blit` and the 7 timer and events primitives
(docs/sandbox-primitive-audit.md). 106 core primitives run as proven Rust
ports for untrusted programs (verified/core/src/prims: **Rust-verified**).
The other 44 are C++. Their status here: **VeriFast-verified** (the
primitive's body, with its ARGS expansion, proved), **ESBMC-verified**
(the native primitive and argument macros model-checked on LP64 and ILP32), **partly** (the C++
it calls on untrusted data proved, the primitive's own glue contract
only), **contract-only** (only the primitive contract of TRUSTED.md
section 8, which the Rust proof assumes; reviewed and fuzzed by the
audit).

| Primitive (C++) | Status | What is proved |
|---|---|---|
| `task_receive_message` | VeriFast-verified (wave 5) | Message ownership on every path and the heap contract up to finalizer bits. A pending callback takes priority over the mailbox. The proof identifies its closure and the resulting runnable and registered lists. |
| `main_arguments`, `spawn_arguments` | VeriFast-verified (wave 5) | as task_receive_message |
| `task_has_messages` | VeriFast-verified | negative allocation allowance returns the exact marked allocation error. Otherwise the result is the process boolean for a runnable finalizer or a nonempty mailbox. The heap and mailbox are preserved. The rendered readiness accessor checks the runnable queue’s head. The allowance, mailbox peek and cached boolean accessors supply the other observations. |
| `random` | VeriFast-verified | returns the low 28 bits of the xorshift128+ output as a nonnegative Smi. The proof covers both state words, the exact seeded transition, and the modular sum. The seed-copy proof covers every buffer length, including partial words, and preserves the input. On the entropy-mixer path the first draw either fills the seed or triggers a full fallback fill. The entropy provider and the EC618 hardware path remain trusted. |
| `get_real_time_clock` | VeriFast-verified | a successful call returns a fresh two-element array containing the sampled seconds and nanoseconds in order, including boxed values. Covers array allocation failure, clock failure, and failure to box either integer. Assumes the OS clock and shared allocation contracts. The checked Linux ABIs use signed long for both fields. |
| `time_info` | VeriFast-verified (wave 4) | no overflow or lossy conversion for any int64, fields smis |
| `bitmap.byte_zap` | VeriFast-verified | the memset inside one writable byte array |
| `process_send` | ESBMC-verified | Checks argument errors, policy and boot-target checks, both encoding passes, quota and allocation failures, publication, mailbox charges and delivery results. The traversal contract assumes the same byte counts on both passes. General correspondence between the input graph, encoded bytes and transferred owners remains open. |
| `byte_array_is_valid_string_content` | VeriFast-verified | argument decoding, slice bounds, read-only validation and preserved heap |
| `platform`, `architecture` | VeriFast-verified | the Linux x86 and x86-64 providers return terminated literals. Each primitive allocates a fresh string of the provider's length or returns the marked allocation error. The shared copy checks the destination contains exactly the source bytes before restoring the heap invariant, for both internal and external strings. Allocation by length and the C library remain contracts. |
| `word_size` | VeriFast-verified | exact tagged result on both word widths |
| `byte_array_convert_to_string` | VeriFast-verified | checks arguments and bounds, runs the read-only UTF-8 validator on the slice, and copies only after it accepts. Success produces a fresh string of exactly `end - start` bytes. A marked error preserves the modeled heap. Allocation by length remains a contract. The model tracks the backing object and slice bounds across allocation. Byte-for-byte preservation by the allocator between validation and copying is still open. |
| `string_to_utf_16` | VeriFast-verified | Checks the string or slice, bounds the doubled allocation size, and returns a fresh byte array only if the destination is aligned and the writing pass reports exactly the measured number of units. The proof covers allocation failure and a write pass that needs fewer or more output units than the sizing pass predicted. Both passes read within a live source slice. The allocator contract preserves object identity and bounds. Preservation of the exact source payload across allocation remains open. |
| `crc` | VeriFast-verified | all six arguments, empty and invalid ranges, bounds for the data and either 256-entry table, checked shift counts, integer result or marked error |
| `time` | VeriFast-verified | boolean argument, either signed 64-bit clock reading and integer result or marked error. The platform clock implementations supply the readings |
| `add_finalizer` | VeriFast-verified | Rejects an ineligible key, accepts an eligible program-heap key without registering it, and reports an existing active finalizer. For a mutable eligible key the queue helper prepends the callback with the correct weak-map status or reports allocation failure. The body sets the header flag only after success. |
| `remove_finalizer` | VeriFast-verified | A non-heap argument gets the marked type error. Program-heap keys, non-instances and inactive instances return false and preserve the state. An active mutable instance returns true. The specialized loop removes every registration for the key and preserves survivor order. The native deletion contract and mapping of modeled fields to native subobjects remain trusted. The body then clears the flag, preserving every other header bit. |
| `spawn_method` | VeriFast-verified | An invalid method returns the tagged integer -1. A valid legacy method returns its bytecode offset. A valid format-2 method returns its index in the loaded table, or -1 when its entry is absent. The legacy offset must fit a tagged integer. |
| `task_new` | ESBMC-verified | Checks the argument and allocation errors, the sole initial code slot and empty frame state on format 2, and the legacy interpreter call order, dispatch entry and restoration of the calling task. Successful allocation supplies a fresh task with a valid stack. The legacy interpreter operations are modeled. Separate checks cover task ID representability and rejection before allocation on exhaustion, plus stack initialization for every supported stack length given a valid card mapping. |
| `task_transfer` | ESBMC-verified | Checks argument errors, self-transfer, the dead-target error, detachment, the active task and epoch, legacy save/load ordering and format-2 stack card writes. The first-transfer proof checks each destination word for every supported stack length, the two frame records, saved bci, preserved code and early rejections. The transfer assumes a saved running stack, valid task layouts and GC card mapping. Legacy interpreter operations are modeled. |
| `encode_error` | ESBMC-verified | The [primitive body](../harness/encode_error.cc) passes the original arguments and stored stack to the encoder, reloads the stack on both encoder outcomes, and returns the exact marked error or a fresh byte array containing the encoded bytes. Checks both internal and external result layouts and native-buffer release on every return. Traversal, interpreter stack operations, result allocation and libc supply contracts. |
| `process_current_id`, `process_system_id` | VeriFast-verified | A live process returns its tagged ID. The system ID is the boot ID observed under the scheduler mutex, or -1 when absent. ID assignment stops at the representable limit and exhaustion persists. The VM singleton, process lifetime and lock contracts remain assumptions. |
| `gc_count` | VeriFast-verified | Reads the process heap’s total collection count as an exact tagged integer. The update proof covers all three collection types and rollover at the representable limit. It assumes a live heap with valid counters and the collection type supplied by the collector. |
| `seconds_since_epoch_local` | VeriFast-verified on Linux | Checks six signed 32-bit calendar arguments in order, the wrapped year offset and the null/true/false DST flag passed to libc. A successful `mktime` result, including -1, goes through integer boxing. Failure returns the process null object. Linux libc supplies the calendar conversion and its weekday success indicator. The cached roots and allocator supply their shared contracts. |
| `array_new` | VeriFast-verified | Checks the length and its type, returns the shared empty array for zero, and delegates positive lengths to the verified primitive allocation wrapper. The [object-heap constructor check](../harness/process_array_allocation.cc) establishes the requested extent, builtin class, length, and every filler word on ILP32 and LP64. It uses the [verified initializer](ffi/array_init.render) at an arbitrary observed slot and checks that the reserved storage meets its preconditions. It follows the native two-space retry, charging the exact extent of an old-space array and marking its card before initialization. The individual space providers supply aligned reservations or exhaustion. The check assumes a valid program class table and card mapping. |
| `smi_divide`, `smi_mod`, `large_integer_divide`, `large_integer_mod` | VeriFast-verified | Exact signed quotient or remainder, including the minimum integer divided by −1, immediate or boxed zero divisors, wrong types and boxing. The native division-error accessor is checked by the division-error-root ESBMC harness. |
| `int_parse` | VeriFast-verified | Decodes all four arguments, checks the slice and the 18-byte limit, and boxes the signed value of its decimal digits. The parser terminates, preserves the bytes, and rejects invalid signs, bytes, and leading or trailing separators. Integer boxing uses the shared allocator contract. |
| `int64_to_string`, `uint64_to_string`, `printf_style_int64_to_string`, `smi_to_string_base_10` | VeriFast-verified | All four decode their arguments and select signed or unsigned formatting. For bases 2–36 the writer stays within 65 bytes, terminates and supplies the allocator with canonical lowercase digits and the required sign. The proof checks the exact argument and radix errors. String allocation uses the shared allocator contract. |
| `float_round` | VeriFast-verified | Checks both arguments and their exact type and precision errors. The decimal scale is exactly 10 raised to the requested precision for 0–15. Success preserves the receiver or allocates one fresh double. Marked errors preserve the heap. The double payload, binary64 arithmetic, libm and the underlying allocator remain trusted. |
| `float_parse` | VeriFast-verified | The entire selected slice must be consumed. Direct string suffixes use the string’s trailing NUL. Other inputs use a terminated copy which is freed on both parser outcomes. The proof covers argument and slice checks, the unsigned input to `isspace`, buffer bounds, embedded NUL rejection, and boxing or a marked error. Numeric conversion and character classification use libc contracts. The image loader checks the trailing NUL for internal and external strings. The allocator and GC supply this invariant for runtime strings. |
| `float_to_string` | VeriFast-verified | Checks the receiver, special values and precision branches. Fixed-precision formatting retries once and frees the temporary buffer on success and failure. The shortest writer checks Dragonbox’s returned components, extracts up to 17 digits and emits a terminated string within 26 bytes in every notation. Numerical conversion relies on Dragonbox and libc. The proof covers memory safety and result or error representation. |
| `utf_16_to_string` | VeriFast-verified | Checks the input byte slice and its even length, computes the UTF-8 size, and checks it fits a Smi before allocation. On LP64 the full possible expansion fits. On ILP32 an unrepresentable result length yields OUT_OF_BOUNDS. Success returns a fresh string containing exactly the encoding of the bytes read by the writing pass. Allocation failure and a changed output length produce marked errors. Preservation of the original input bytes across allocation remains open. |
| `bitmap.blit` | VeriFast-verified | Decodes all eleven arguments. Copy-on-write destination allocation preserves the remaining references. Each pixel borrows and returns its source, optional lookup and writable destination slices in order, allowing overlap. The loops terminate, stay within both buffers and reject excess work before the first pixel for either an uninterrupted-run quota or a total CPU quota. ESBMC also checks all six pixel results and preservation of unrelated bytes. The shared heap, allocator and live process-policy reference supply their contracts. |
| `events.register_monitor_notifier`, `events.unregister_monitor_notifier` | ESBMC-verified | The native bodies check proxy representation and tag, group membership and the event source. Registration rejects closed proxies and propagates monitor allocation failure. Unregistration accepts closed, correctly typed proxies without a callback. A live, matching pair calls the owning source exactly once with the original arguments. |
| Event monitor lifetime | ESBMC-verified | The native registration and cancellation bodies create a monitor and reusable message, replace the object, or roll back after either allocation fails. From an empty root list and mailbox, the gate checks exact root membership, immediate sends on nonzero resource state and cleanup before or after dequeue, with leak checking. Allocation uses symbolic failure and placement construction at a stable address. Cancellation runs under the source mutex, and the modeled scheduler publishes to a live receiver through the native mailbox. The separate monitor-scavenge gate verifies the callback used in the lifetime check for a two-word young object and space for one copy. The native visitor forwards its monitor and optional global alias. The native receive primitive, with no runnable finalizers, reads the surviving object or returns program null after cancellation. The monitor-scavenge checks use the native size calculation on a valid class table and cover successful promotion, young copying and failed promotion. They check preservation of an outstanding old-space GC request, creation of one on fallback, and each alias’s remembered-set flag. Source extent, allocation outcomes and root visitation order are assumed. |
| `events.read_state` | ESBMC-verified | Rejects invalid or closed proxies and mismatched groups before acquiring the mutex. The native read returns the sampled mask and clears the state inside the critical section. The primitive preserves both argument slots and returns the tagged bits of the sampled mask. Exact numeric representation requires the mask to fit a Smi on ILP32. |
| `timer.arm` | ESBMC-verified | Checks the timer proxy and decodes either a Smi or a boxed signed 64-bit deadline. Success passes the original timer and exact deadline to the singleton event source once and returns program null. Rejection leaves the queue operation uncalled. With zero to two sorted peers and an optionally linked target, the same gate runs the native queue update and unregistration callback. It checks exact forward and backward links, stable placement at equal deadlines, event-state preservation on a no-op, and the signal decision under the source mutex. The separate timer-dispatch gate checks the native timer thread, event state update and monitor notification decision. |
| Timer thread dispatch | ESBMC-verified | Starts with zero to two sorted timers, arbitrary signed deadlines, event masks and optional monitors. The check cuts at the next outer loop header. A live round dispatches exactly the due prefix, leaves the pending queue linked in both directions, and waits only when it dispatched nothing. A stopped thread skips the round. A modeled condition wake preserves the queue and may set the stop flag. Time comes from a nonnegative monotonic clock. EC618’s freertos-wait gate checks conversion to finite 1 kHz tick counts for every signed 64-bit delay. The scheduler-notify gate checks the scheduler's send under nested scheduler and mailbox locks, a second send with or without an intervening dequeue, unchanged quota charges, and the ready queue for every receiver state. It starts with a live notifier, at most one preceding message and one ready peer. The RTOS wait and worker wakeup use contracts. |
| `timer.init` | ESBMC-verified | Heap proxy allocation precedes the caller's group quota check. Only admission and successful native allocation construct and register a group with the caller and timer source, then publish its typed proxy. Each failure returns its own error. Heap allocation, admission, group-list insertion and nonthrowing allocation are modeled. |
| `timer.delete` | ESBMC-verified | Only an open timer in the supplied group reaches unregistration. Success closes its proxy and decrements a positive quota count once. Rejection preserves the proxy and quota, including on retry. Native list removal and destruction are assumed. |
| `timer.create` | ESBMC-verified | Checks the group proxy, exact errors, quota reservation and rollback on native allocation failure. Success registers the initialized timer before publishing its typed proxy. The harness models allocation and group-list insertion and assumes the live timers fit in the address space. |

Of the 150 allowed primitives, 106 have Rust ports with proofs, 33 have
VeriFast body proofs and 11 have ESBMC body proofs.
These counts classify primitive names. A port can still delegate a case
to C++, as `list_add` does for a large-array backing
(`verified/core/src/prims/array.rs`). Body proofs also rely on the
contracts of their callees, including the allocator.

`process-send-body` runs the production primitive and message constructors on
ILP32 and LP64. It checks the exact return value and which stages run for
each argument, policy, quota, allocation, encoder and scheduler outcome.
The scheduler observer checks the destination, sender identity, message type,
combined inline and external byte charge, and both mailbox limits. Allocation,
payload traversal, creation of encoder errors, ownership handoff and delivery
supply contracts. The modeled traversal permits any representable sum of
nonnegative byte counts and assumes an unchanged size between passes. The
separate ownership checks below cover encoder destruction and transfer.

`ipc-array-traversal` checks the native `encode_array` loop by induction
over every permitted slice length. It verifies the array tag, the declared
child count and the exact source slot passed at each recursive call. This
holds for arbitrary slot contents, including repeated references. Both passes
therefore select the same children in order on an unchanged array. Either
pass can fail at any child and stops there. Invalid slices emit no header.
The process-array length limit used for rejection is derived from the native
heap limit on each word size. The calls that encode each child still supply
their own contracts for bytes and ownership.

The same proof checks native `encode_list`. It validates the requested
interval against the logical list size and checks the backing before
delegating to the array loop with the original offsets. Rejected bounds
or an unsupported backing emit no header.
For a list slice, the native encoder reads the tagged endpoints and routes
the exact interval to a direct array or a list. The traversal proof covers
both routes, including an arbitrary child failure. It also checks that a
wrong instance backing reports its class ID and that other rejected inputs
preserve the diagnostic.

`ipc-map-traversal` checks the map tag, declared entry count and the
sequence of calls to encode each key and value. On success that sequence
is exactly the first declared number of live pairs in the original backing
array, in slot order. A deleted entry contributes neither slot. A list
backing restricts the scan to its declared length. An unmatched last slot
cannot supply a pair. If a child rejects, the trace ends at that key or
value. If the backing is readable and all visited children succeed, a
shortage of live pairs is detected after the last complete pair. Child
encoding still supplies its byte and ownership contracts.

`ipc-smi` follows a tagged integer through the native IPC sizing pass,
writing pass, and either decoding or disposal. For every Smi on each word
size and every permitted starting encoder depth, the writer fits an envelope
of exactly the measured length. The decoder recovers the original value,
including its sign, without allocating a boxed integer. Decoding and disposal
each consume the whole leaf. The harness checks that no external owner is
registered and no owned storage is released. Recursive container alternatives
have explicit unreachability assertions in this leaf proof.

`ipc-fixed-scalar` follows null, both booleans, doubles and boxed integers
through the same native passes. The roots occupy one wire byte and decode to
the corresponding root of the receiver's image. A double or boxed integer
occupies nine bytes. Integers in the receiver's Smi range become Smis.
For other integers and for doubles the proof checks the value passed to the
box allocator, the returned object and the allocation-failure status. Every
non-NaN double must preserve its bits, including the sign of zero. A NaN must
remain a NaN. The cleanup walk consumes each complete leaf without freeing
an external owner. The separate `boxed-allocation` check follows the native
constructors from a fresh raw reservation (or exhaustion) through the class
header and numeric payload.

`internal-string-allocation` checks the native string constructor for every
permitted internal length. It requests one word-aligned reservation containing
the header, payload and trailing NUL, propagates exhaustion, and initializes
the class, length, hash sentinel and terminator.

`external-blob-allocation` checks the native constructors used for external
IPC strings and raw byte arrays. It supplies the caller's block, including
the extra terminator byte for a string, and follows finalizer registration
through the native queue append and header flag update. It covers borrowed
and owned blocks, an empty queue or a queue with a prior node, and failure
of either the raw reservation or the nothrow finalizer allocation. The byte
array uses the decoder's `clear_content=false` path. A symbolic payload
index checks preservation of every input byte. These checks assume that raw
reservation returns fresh storage of the requested size or reports failure.

`ipc-tree-disposal` checks the native recursive disposal walk against a
description of one complete IPC value. Each child starts at the previous
child's end offset, and every external string or byte array carries exclusive
ownership of its allocation. VeriFast checks that the walk reaches the end
offset and consumes all those owners, for any finite tree satisfying the
description. It checks the concrete tag, fixed-width, pointer and cardinal
reads. For a cardinal, the proof reads the actual bytes, sums the seven-bit
digits at their base-128 positions and stops just after the terminal byte.

The native tag, cardinal, fixed-width and pointer writers now supply the
byte chunks for this description at any starting offset. The cardinal proof
uses exactly the required space, constructs the reader's digit predicate
with the original value, and gives the same final offset in sizing mode.
Scalar and external-leaf lemmas assemble cleanup nodes from those fields.
The external case also consumes the caller's ownership of the allocation.
The tagged-integer branch of `encode_any` calls the native `encode_smi`
writer. From any valid offset with room for its sign tag and magnitude,
its sizing and writing passes end at the same byte. The field readers
recover the original sign and magnitude, and the cleanup walk consumes
exactly that leaf. The proof leaves the rest of the envelope and existing
external ownership with the caller.

The native array loop writes its tag and length and joins the completed
children in slot order. Given the byte boundaries of successful child calls,
both modes reach the predicted final offset. The writing pass produces the
node the disposal walk consumes. Invalid slices leave the cursor and buffer
unchanged. If a child fails, the array proof returns the header, the complete
prefix with its external owners, and the failing child's state. This requires
a contract for each recursive call and enough space for the array header.
For an empty slice, the proof runs both native array passes and the disposal
walk from the same arbitrary offset, with no recursive-call assumption.
All three cursors advance exactly two bytes.
Deriving those contracts for arbitrary nested inputs and reclaiming partial
outputs on failure remain open. The enclosing buffer release is checked
separately.

`ipc-cardinal-wire` checks both passes of the native cardinal writer for
every unsigned machine word. It verifies the payload and continuation bit
of each byte, the absence of redundant leading zeros, and the exact extent
of the write. The native reader then recovers the word from that buffer.

`mailbox-delivery` checks the native system-message enqueue with symbolic
word-sized counters, sizes and limits on ILP32 and LP64. Its FIFO starts
empty or with one prior tail. Its reply grant set has capacity zero, one
or two and may require allocation. Rejection preserves the links, counters
and grant membership. Success publishes all three before releasing the
mailbox mutex.

`mailbox-removal` checks native peek, readiness and removal on ILP32 and
LP64. After the first successor, the outgoing link and cached tail are
symbolic. The proof checks that removing the head preserves both, so the
suffix can have any length. System messages refund the
exact encoded size and count, including the restricted sender's charges
when applicable. An owned notification returns to its notifier with its
queue flag cleared. An abandoned notification or a system message reaches
destruction after unlinking. The check observes the links and counters at
mutex release. It assumes valid starting charges and models the mutex and
system payload cleanup.

`scheduler-delivery` checks the direct and system routing bodies from
`scheduler.cc` with the native enqueue and grant code. It observes lookup,
wakeup, locking, termination decoding, shutdown and calls to delete through
contracts. Direct routes cover
present and absent destinations, old grants, same-group and boot-process
exceptions, and mailbox or grant refusal. System routes cover delivery to
the boot process, a full boot mailbox and consumption without a boot
process, including the decoded termination value. Every unqueued message
reaches one delete. Destruction of the encoded payload remains a separate
obligation at the scheduler boundary. The receive-path VeriFast proof
checks the destructor and deallocation walk given the IPC encoding and
block-ownership assumptions described below.

`byte-array-neuter` checks the concrete sender-side detach operation and
the heap's external-memory counters. Given an owned raw external array
whose length is charged to the process, the operation returns its data
pointer, clears the sender's address and length, and subtracts exactly
that length from current external memory. Lifetime allocation accounting
and the object header are preserved.

`byte-array-ownership` proves `ByteArray::has_owned_external_memory` from the
byte-array layout and finalizer flag. An external array is eligible for
transfer exactly when the active-finalizer bit is set. The shared flag
accessor also handles a forwarded header when given a valid destination.

`ipc-byte-array-visit` checks one visit to an owned external byte array
with any valid number of prior transfers and copies. The reference can be
absent from the transfer table or appear in any occupied slot. The sizing
and writing passes agree on the representation, reservation count, byte
charge and emitted length. A first visit records the original pointer.
A repeat copies up to 128 bytes inline, or records a fresh allocation for
a larger payload. The checks cover size and table limits, allocation failure,
preservation of prior entries and the sender's ownership before publication.
The blob-accessor proof supplies the original backing object, base address
and length for a direct byte array. Allocation and the two payload memcpy
sites supply contracts. The copy observer checks both addresses, the byte
count and an arbitrary byte. The visit proof checks the arguments and order
of the field writes. `ipc-array-fields` checks the native writers against
those operations and reads back the tag, length and pointer from a buffer
of exactly the specified extent. Publication and teardown are covered below.

`encoder-handoff` starts with the encoder's copy and transfer tables
populated with distinct owners, up to the native limit of eight entries in
total. It checks the message constructor, transfer order, finalizer-clear
calls and destruction of the writing encoder. Aborting releases the main
buffer and each copy. Publishing gives the message the buffer and leaves
the external blocks for the receiver. The table check observes detachment
and finalizer clearing at their call sites. `byte-array-neuter` checks both
operations on a concrete tagged byte array.

`ipc-transferred-array` follows one owned external byte array from its
size pass into a buffer of exactly the measured length. It checks the
native reader's tag, length, pointer and final cursor, then checks the
writer-abort and message-disposal paths. An assertion excludes recursive
array/map cleanup for this leaf. Native storage release and external-byte
refunds are observed through contracts. The heap accounting operation has
its own proof above. For general nested messages, connecting the traversal and
cleanup contracts to the bytes and owners produced by both passes remains open.

The `encode-error-body` target checks the host-configured primitive on LP64
and ILP32. Its traversal contract summarizes construction and encoding by
an arbitrary attempted output size and arbitrary contents. Success requires
the size to fit strictly below the native buffer capacity. For a successful
result allocation the harness checks the source, destination and length of
the libc copy and observes an arbitrary byte under the memcpy contract.
The symbolic allocator supplies disjoint storage. Recursive encoding and
legacy stack enumeration still need proofs.

The [native visitor dispatch proof](../harness/visitor_dispatch.cc) checks
every immediate integer and all 16 heap tag patterns. A supported tag
forwards the original reference to exactly one matching callback. GC and
reserved tags reach the VM fatal handler before any callback. Heap references
are assumed to point to a readable header. The [scalar encoder proof](../harness/encoder_scalar.cc)
follows the same dispatch through the actual scalar callbacks. It checks the
integer value, the full binary64 payload, and the byte markers for the three
distinct null and boolean roots at the writer boundary.

Frama-C/WP checks the [string prefix selector](../../../src/encoder_string_prefix.h)
on both word widths. Strings of up to 255 bytes keep their full length. For
longer inputs, the backwards scan stops at zero or the last non-continuation
byte at or before index 255. The proof covers malformed byte runs, read bounds
and termination. The visitor's payload emission is exercised by the host
object-encoder test.

The collection proof checks the native list-field validator and the shared
array/list traversal. The validator accepts exactly an array backing and a
tagged size from zero through the backing length. Given a validated size,
the traversal announces that size and passes at most ten original children
to the next level in order. The depth guard writes null at level 16 and
suppresses output when the buffer is already full. The harness checks the
arguments to the separately proved wire writers and models recursive child
dispatch as a read-only callback. The class dispatch and fallback in
`visit_instance` remain outside these checks.

The stack-frame callback proof uses induction on the number of frames delivered.
Its input is a stable count and a sequence numbered from zero. The
[format-2 walker proof](../harness/v2_frame_walk.cc) establishes that sequence
for a valid packed frame layout and a stable skip setting. A count-only call
reads the frame top. During enumeration each step advances the index by one,
reports the suspended instruction’s successor for a recognized opcode or reads
the corresponding saved return offset, and stops at the announced count.
The proof assumes a live stack, readable bytecode below the format-2 size
limit, and offsets representable in the callback's integer type. The legacy
walker still supplies its sequence by contract. The callback checks the emitted
count after each frame and the encoded index and bytecode offset. Long traces
retain the first 33 and last 67 frames on the host, or the first 13 and last
27 under the FreeRTOS policy. The latter check selects the production limit
in the ILP32 harness and uses host headers.

The notifier checks (`run.sh --quick event-notifiers`) assume that an open,
correctly tagged proxy points to a live native object of its declared type.
The harness models the outcomes of the event-source update and deletion
methods. Their locking, notifier lifetime and scheduler effects still need
proofs.

The read-state check includes the native `EventSource::read_state` and
the `Locker` constructor and destructor. It models mutex entry and exit,
allowing independent updates at both boundaries. On LP64 every uint32
mask fits in a Smi. On ILP32 an exact nonnegative result requires a mask
at most 0x3fffffff. The native timer constructor starts at zero and the
timer event callback sets only bit zero. The read proof covers arbitrary
32-bit masks in the release configuration and checks the numeric result
when representable.

The format-2 loader obtains the method table from the program's last
literal. ESBMC checks that `v2_last_table_literal` handles missing and
empty lists and selects the final slot only when it contains a heap object
with the byte-array tag. This assumes a readable literal list and valid
object headers. The object model verifies how `ByteArray::Bytes` obtains
the pointer and length of an inline or external payload.
`v2_read_table_literal` rejects lengths below 16 before reading memory.
Given the advertised bytes, it accepts exactly the TMT2 marker, matching
bytecode length, nonzero 24-bit count, and a size of 16 + 4 × count bytes.
It returns a view starting immediately after the 16-byte header.
Every accepted count fits a tagged integer and every current and lookahead
record used by the loop fits inside that literal. For each current record,
ESBMC checks `v2_check_header` against the five canonical kind bytes and
their sizes from format note 21. A successful check places the header at
the expected offset, leaves room for a body, and accepts exactly the receiver
intervals allowed by that kind. The proof covers rejection of invalid
positions, kind bytes and receiver intervals on LP64 and ILP32.
ESBMC also checks `v2_next_header` for an arbitrary four-byte record, header
kind and legal current entry and image length. Every successful call locates
the exact header strictly between the current and next entries. A rejected
pair has the corresponding bad-entry or empty-body result. The backing
memory must be readable for the advertised lengths.

Frama-C/WP verifies the same validation loop compiled by the VM
(`src/v2_validate_records.h`) against those helper contracts. For every
permitted count the loop terminates and accepts exactly the record
sequences specified in `loader/records.c`. The first header starts after
the four-byte tag. Each header is canonical and every method has at least
one body byte before the next header or the end of the image. This gives
strictly increasing entry offsets. Run `run.sh --quick v2-table` to
check the loop and its native helpers on both word sizes.

After validation, `V2MethodTable::install` borrows aligned records and
copies unaligned records into owned storage. ESBMC checks an arbitrary
byte of any permitted record count, the bytecode view, optional
allocation-failure reporting, and release of owned memory on failure or
destruction. The new table starts unverified. After `mark_verified`,
`runs_verified` admits an untrusted process only for a table accepted
under untrusted rules. The harness models libc's
`memcpy` at the observed byte and checks the copy extent and separation.
It models the null outcome of nonthrowing scalar allocation explicitly
and invokes the native destructor before releasing the table storage.
ESBMC also checks the body of `V2MethodTable::compute` against the
separately verified helper outcomes. The source image must pass the TBC2
tag and size checks before literal selection. The reader receives the
selected inline or external payload. Installation receives exactly the
image, record pointer and count passed to successful validation. The
caller gets the installation result, and only allocation failure sets
the optional out-of-memory flag. Diagnostic output is outside this proof.
The validity and lifetime of the program heap and its backing storage and
the allocator and libc contracts remain assumptions.

The object model reads built-in class IDs through the rendered body of
`Program::class_id`. ESBMC checks all 23 native named getters against their
indexed slots and checks the ten aliases used by the proof model against the
native getters on both word widths. The loader still supplies the invariant
that the table holds tagged class IDs consistent with the program's objects.

VeriFast also checks the C++ eligibility decision used by `add_finalizer`.
An object qualifies for an ordinary Toit finalizer exactly when it is an
instance, has a class ID different from the program's map class ID, and
cannot be decoded as a string or byte-array view. The decoder proof gives
the exact length on success and models failure for malformed views and
excessive nesting. Consequently, a malformed wrapper can pass this
eligibility check. The primitive handles maps separately for weak-map
registration.

For each writable, non-forwarded header in the heap model, VeriFast checks
the C++ store that sets or clears the flag. Both operations are idempotent.
The stored word changes by exactly 32 when the flag changes. The class ID,
tag, object fields and all other objects survive the update. Registration
changes the header only after the native queue helper reports success.
Removal first unlinks the registrations and then clears the header. The
queue helpers' contracts carry no permission to modify any VM object.

The native `finalizer-header` check exercises the C++ accessors on every
Smi-tagged header word. Reading the flag through a forwarding pointer gives
the flag of its destination. Setting or clearing the flag on the destination
preserves every other header bit and the forwarding pointer. The decoder
still assumes that clearing the flag returns ownership of an external block.
That obligation also depends on the finalizer queue and the collector.

Callback registration selects the weak-map or ordinary allocation and checks
for allocation failure before inserting a node. VeriFast follows the
derived and base constructors that store the key, closure and owning heap.
The native `finalizer-prepend` check covers the empty queue and a queue
with arbitrary existing endpoints. Insertion makes the new link the head,
points it to the previous head and changes the tail only when the queue was empty.
VeriFast proves that these updates transfer ownership of the detached node
to the process heap’s queue. The inductive list records the callback kind,
key and closure of each node. Insertion preserves the order and ownership
of every previous registration for any finite queue length. The process
accessor contract identifies the queue owner with its embedded object heap.

The native `finalizer-queue` check runs the C++ delivery and removal code
with the intrusive FIFO and both concrete callback kinds. Delivery consumes
the first runnable callback, returns its lambda, deletes an ordinary
callback, and puts a weak-map callback back at the head of the registered
list. The harness covers an optional runnable successor and an optional
existing registration. Removal checks every pattern of matching keys and
callback kinds in a three-node list, including duplicates. It checks which
destructors run, both keys' header words, the surviving order and an append
through the repaired tail or empty anchor.
The unwinding assertion checks that the native traversal finishes within
this bound. VeriFast separately proves termination of the specialized C
loop for any finite registration list. At each iteration the unvisited
suffix shrinks by one. A match hands the detached node to the delete
contract. Otherwise the link is restored. The resulting list contains
exactly the registrations whose key address differs, in their original
order, with the correct tail or empty anchor.

The `finalizer-unlink-code` check compiles the original `src/heap.cc` and
the VeriFast loop from each target’s generated C with Clang at `-O1`.
The adapter uses the native link type for traversal and converts the link
to its owning node for the key read and virtual deletion. The check
requires identical bytes for the entire unlink method and rejects
relocations in either function section. This comparison covers all loop
iterations on the i686 and x86-64 check builds. It relies on the adapter’s
type mapping and the compiler. Release binaries and other architectures
need their own evidence.

Both `task_has_messages` and `task_receive_message` use the rendered body
of `ObjectHeap::has_finalizer_to_run`. Its read permission is for the head
of the process heap’s runnable queue, and the result is true exactly when
that link is non-null. ESBMC compares the emptiness decision with the
native queue for a symbolic head.

The main and spawn argument primitives use the rendered getters and clear
operations from `src/process.h`. Each getter reads its own encoded-buffer
slot. Clearing a slot requires write permission for that slot alone. The
two pointer-taking setters in `src/process.cc` require an empty slot and
preserve ownership of the supplied encoded message and its external blocks.

The receive proof now calls the rendered `ObjectHeap::next_finalizer_to_run`
with ownership of both callback queues. From a nonempty queue it returns
the first closure and preserves the remaining runnable callbacks in order.
It prepends a weak-map node to the registered list or passes an ordinary
node to native deletion. A direct call on an empty queue reads the program
null root. The FIFO proof covers any finite suffix and restores the anchor
when the last node leaves. ESBMC compares the link updates and the
conversion back to the containing C++ node on both word sizes.
The receive precondition requires that queued closures are valid references
in the current VM heap. Establishing this across GC, dynamic dispatch of
`keep_after_callback`, native deletion and the program null root accessor
remain trust boundaries.

VeriFast checks the native `roots_do` bodies for ordinary, weak-map and VM
finalizers. Given a visitor that forwards a reference in place, each
callable node hands it the key slot and then the closure slot. A VM node
hands it only the key slot. The proof records slot addresses, so it also
checks the order and visit count when both fields hold the same reference.
The rendered `RootCallback::do_root` passes a length of one.

The native `finalizer-roots-test` CTest runs the heap’s traversal with up to
two callable nodes and one VM node. Either callback can be absent,
registered or runnable, and either kind can come first. The visitor checks
slot identity, writes distinct replacement values and checks that the
updates survive the traversal. A separate ESBMC attempt reported a null
dereference in the runnable iterator on ILP32. The compiled test passed
all 36 queue configurations on i686 and x86-64. The model-checker result
remains unresolved. The concrete collector’s forwarding map and traversal
of queues of arbitrary length also remain open.

The C++ primitive failure path also verifies its shared error decoding on
both word widths. An immediate selects a slot in the program root table.
An unused immediate selects `INVALID_ARGUMENT`. A marked heap pointer
recovers the original heap-tagged address. VeriFast checks the table read
against the loaded program's root array and carries this result through
the retry loop. ESBMC checks the native decoder for every marked word and
arbitrary root values, including the named error accessors. This still
assumes that the loader supplied a live program with initialized roots.

The encoding module (`tison_decode`: the decoder
verified, its glue not rendered) is denied to untrusted programs.

### Young-space allocation

The proof in `heap/semispace.render` covers the original C++ bodies of
`SemiSpace::try_allocate`, `SemiSpace::allocate`, `SemiSpace::flush` and
the end-sentinel helpers. Given ownership of the unused range of a
word-aligned chunk, a successful call hands out the requested prefix,
advances the allocation pointer by its exact byte length and stores a null
sentinel in the next word. The remaining words retain their contents.
An exact fit fails because the sentinel needs its own word. The fast path
leaves the range intact on failure. The ordinary allocator refreshes the
sentinel when its active chunk is nonempty.

The [raw allocation proof](heap/young_allocation.render) follows this ownership
through `TwoSpaceHeap::allocate` and `ObjectHeap::_allocate_raw`. For a
positive word-aligned request that fits with room for the sentinel, the
returned tagged pointer addresses exactly the prefix transferred to the
caller. The heap retains the sentinel and the remaining words. A miss
preserves the young allocation window. An ordinary miss returns null. On
a primitive retry the proof follows the production fallback into the
old-space allocator. A successful return transfers the old allocator’s
word permissions to the caller at the exact tagged address. Both paths
expose the same `raw_reservation` postcondition. A constructor can consume
the granted words while the allocator retains ownership of its cursor,
sentinel and metadata. The proof
retains the updated old-space window and the object-start byte or the
slow provider’s returned state. The proof now follows
`record_direct_old_allocation` through a relaxed atomic charge of the
requested size and a store of `NEW_SPACE_POINTERS` to the reserved object's
card. The address proof derives the byte offset from the published heap
base, extent, remembered-table base and installed bias. It assumes the
atomic operation’s semantics and ownership of that live byte. The [barrier proof](heap/remembered_card.render) checks the
native word-address writer and reader, including modular bias addition.
The reader preserves the byte and reports every nonzero value as dirty.

Given the unused words of a chunk, `update_base_and_limit` installs its
top and end, writes the sentinel and preserves the words above it.
For a fresh chunk inside the metadata range it also clears the object-start
table. `initialize_starts_for_chunk` verifies the exact byte count for
full and partial clears, including an empty suffix. The mapping from a
heap address to its metadata table and ownership of that table remain
assumptions. The proof also assumes that chunk-list emptiness agrees with the active range.
Establishing ownership of that range across chunk acquisition, collection
and reuse remains open.

For old space, the same sidecar proves that `OldSpace::use_whole_chunk`
reserves the last word for a null sentinel, charges exactly the usable bytes
to `used_`, and leaves the allocation range intact. With promotion tracking
enabled, it reserves the three-word header before handing out the remaining
range. The proof assumes ownership of the new chunk, enough room for the
accounting increment, and the contract of `PromotedTrack::initialize` for
the header and its card metadata. The `allocate_and_use_chunk` proof carries
that ownership through attachment and installation, assuming fresh pages,
a valid descriptor and the list attachment contract. The new list contains
the full chunk extent, including the sentinel, so the total reserved bytes
increase by the full page allocation. A page-provider failure
leaves the list, active window, charge and promotion track intact.
The [native installation check](../harness/old_chunk_install.cc) supplies one
page and runs the production list insertion, owner change, table initialization
and promotion-header writes on both word widths. A tracked installation must
return with the header’s start recorded and its card dirty. Clearing the
tables after installing the header erased both marks.

`OldSpace::allocate` transfers the requested aligned words from the active
range, including an exact fit, and leaves the remaining words intact. The
native `record_start` writes the low address byte to the object-start
table. When the range is too small, the proof checks the GC decision and
the order of the free-list and new-chunk calls. On the free-list path the
proof follows `allocate_from_free_list` through selection and installation.
Its input owns the free regions and supplies the relevant card metadata.
On success, the returned words come from the selected region. On a miss,
the active window is empty and the charged byte count reflects the flush.
The new-chunk provider still supplies a storage contract.

`old-space-retry` checks the release-build `TwoSpaceHeap::allocate` path
across a semispace miss. Only a primitive retry calls the old-space provider.
A successful retry charges the allocation once and writes the remembered-set
byte for the returned address. It preserves both neighboring card bytes.
The check includes failure of both providers and persistence of the
large-allocation-failed flag. It assumes the providers return aligned
reservations or zero and the remembered-set bias maps the candidate address
to valid card storage. The `process-array-allocation` check follows that
retry into array initialization. Removing the card mark fails at the initializer
entry. Passing an incorrect filler on either allocation path fails at the
returned array element.

`free-list-search` verifies the production old-space free-list insertion,
selection and flush for arbitrary chain lengths on both word widths. Insertion
prepends a chainable region to its size bucket and leaves the table intact for
short fillers. Selection detaches the first fit in the chosen bucket and
preserves the order of all surviving links. Flush relinquishes the unused
suffix, subtracts its exact extent from the charged bytes, clears the active
window and trims the active promotion record when present. The installer uses the same region predicate as the search. It owns every
word, including the header, size and successor. The native link accessor and
mutator read and write the third word. The provider passes the detached region to the installer,
which accounts for its full extent and calls the verified bump allocator. The returned reservation
and the remaining window are disjoint, including with a promotion header
and on an exact fit. The installer assumes room in the accounting counter
and valid card metadata. The native selection helper derives the accounting
bound from the incoming charged bytes plus the sum of every free region.
It proves the exact conservation equation across flush and search, including
the loss of a too-small suffix to walkable fillers and a search that finds
nothing. The selection contract identifies the exact region returned from the
post-flush buckets and the contents and order of every surviving chain. The
search starts at the highest nonempty bucket above the request’s bucket,
or takes the first fit in the request’s own bucket. Selection also establishes room for the payload and any promotion
header. The proof assumes
the active range is owned and accounted for and uses contracts for region
headers and promotion metadata. Mutations that drop a link or omit the
accounting decrement are rejected.

`free-list-region` exercises the native header constructor and link accessors
for symbolic word-aligned extents, including zero. It checks the tagged address,
the recorded size, the links and the boundary of writes to short filler regions.
`free-list-bucket` checks the native leading-zero calculation against all bucket
thresholds for every positive machine word.

`promotion-header` checks the production initializer with symbolic end and
predecessor, with valid table biases and every word position within a card.
It checks the class ID, tag, next pointer, end, dirty byte and object-start
byte. Recording the payload start updates that same byte or the adjacent
card, preserving neighboring metadata and the first payload word.

`gc-metadata-layout` checks non-embedded GC setup for arbitrary reported heap
bounds. Empty intervals and unrepresentable exclusive ends fail before
reservation. The OS model supplies a machine-word-aligned metadata reservation
or null, and can fail each commit. The bulk-fill
observer checks the destination, value and length. The layout proof establishes
the six table extents and their installed addressing biases. Using the mapping
published by setup, a write for any interior heap address sets the corresponding
remembered byte. An independently selected byte in any of the four committed
tables retains its value unless it is that byte.
`gc-metadata-access` checks the native word, card and overflow accessors for
every heap byte using those bounds and biases. The
[remembered-card check](../harness/gc_remembered_card.cc) follows a write
through a whole-chunk reset or a reset above a word-aligned live extent.
The raw-address and tagged array, instance and stack writers select the
same card. The last partially live card and cards outside the selected
interval retain their values. The C library fill is modeled at an arbitrary
observed byte after checking its entire destination interval. Setup must commit the four
eagerly mapped tables before initializing the page types and publishing the
singleton. Failed commits return the entire reservation. A duplicate setup
preserves the active mapping. Teardown withdraws all six table pointers,
preserves the heap heuristics setting, and releases the mapping once even
when called twice.

The EC618 and ESP32 variants follow native setup through chunk ownership
and destruction. They check each metadata slice for an arbitrary aligned
chunk of the published heap. ESP32 exercises all combinations of the heap
and metadata RAM flags, including the internal RAM prefix adjustment.

`gc-internal-ram-range` checks the production ESP32 internal RAM sizing
helper on ILP32 for every nonempty, representable interval of 4 KiB pages.
It checks the retained size in each metadata tier and the 108 KiB trim cap.

`gc-metadata-commit` checks the two lazy commits for a page-aligned chunk
within a covered heap. Given the reserved table layout, it checks both exact
2 MiB rounding intervals clipped to the reservation, including the mark
scanner's one-byte lookahead, and the fatal path on either commit failure.
`gc-page-type` checks classification for every machine word. A tagged address
inside the interval uses its page's recorded kind. Smis and outside addresses
return the unknown page type without reading the table. The OS reservation
and commit implementation and preservation
of table ownership across collections are separate obligations.

`gc-mark-roots` verifies the C++ marking visitor for arbitrary valid root
ranges. A previously unmarked heap reference enters the 128-slot stack or
is recorded for overflow recovery. The root slots retain their values.
The stack scanner filters the half-open bytecode address range, and the
weak-map rule uses the finalizer bit, instance tag and program map class.
The drain loop pops before enumeration and marks the object's post-visit
extent. Given a finite collection heap and returning enumeration and
mark-table operations, the drain terminates. Popping removes one queued
object, and pushing a newly discovered object consumes a previously
unmarked heap candidate. Every initially queued object has been scanned
when the drain returns. For an arbitrary finite path of enumerated strong
references from a marked root, if the marked objects on the path were
initially accounted for and previously scanned edges were marked, then
every object on the path has been scanned or the path contains an object
recorded for overflow recovery. Clearing the overflow flag preserves
those records. These statements concern the supplied roots and edges. `gc-object-roots` checks native enumeration for all ordinary
non-stack tags, including the exact array/instance slot range and the
active-finalizer callback.

`gc-stack-shrink` checks format-2 stack shrinking for arbitrary valid
nonempty stack storage on ILP32 and LP64, including an empty live slice.
It compares the native reserve calculation with wide arithmetic for every
signed method height, checks the source, destination and count of the move,
and checks the new length, top and unchanged execution metadata. Observing
an arbitrary word covers retained records, the unused gap, live slots and
every released word, including overlapping moves. This uses the libc
`memmove` contract and the pointer-word store contract proved by
`gc-stack-fill`, which proves termination for every valid fill count.
Using the native size dispatcher and sentinel test on the result, the shrink
harness checks the post-visit heap partition. The stack ends at the first
released word or its original successor. Each released word has a nonsentinel
header, advances the walker by one word and has no root callbacks. The
successor retains its original header, including a chunk-end sentinel.
The shrink harness also checks that the native scanner's base accessor points
to the first storage slot. Given that base and the retained bounds,
`gc-mark-roots` proves the scanner visits exactly the non-bytecode slots
in the half-open live range. `gc-stack-relocate` also checks visitors that
rewrite roots. For any supplied forwarding function, each visited slot
receives its forwarded value, bytecode pointers retain their original
values and the visitor sees the original references in order. The actual
copying collector must establish the forwarding callback contract.
The native `stack-gc-roots-test` checks the public scanner with a relocating
visitor. The `gc-stack-scan-entry` check follows the production
`Stack::roots_do` entry with a format-2 image. A damaged guard reaches
the fatal path before either shrinking or scanning. With an intact guard,
the entry passes the original top and image height to the shrinker and
dispatches the scanner on the resulting live slice. Its bytecode interval
equals the program table's half-open range and contains the frame marker.
This check assumes valid incoming stack storage and an aligned, readable
bytecode table.

For the host snapshot loader, `snapshot-image-layout` checks the image size
calculation for all signed header counts. Accepted sizes include all table
padding and program blocks. Each typed allocation from a valid aligned
cursor either fits in the external prefix or leaves the cursor unchanged.
`snapshot-bytecode-slice` runs the native byte-list reader and image
allocator with a symbolic input cursor, length and available capacity.
A successful result contains the exact payload and advances the input
past it. A truncated length, invalid payload length or exhausted image
produces an empty view and records failure. The copy uses the pointwise
libc contract.

`image-backing` checks the native aligned allocation for arbitrary sizes
and alignments, including rounding overflow and malloc failure. The aligned
payload and the last partially occupied page fit in the grant. The host
image retains the original owner and logical extent. Given an aligned
movable object outside the malloc grant, its tagged reference is outside
the published image. With a power-of-two POSIX page size and successful
protection calls, nonempty images request read-only access and restore write
access before releasing the original allocation. A second release of the
invalidated handle leaves it invalid. The debug targets also check both
fill ranges and the order of fill, protection and release. Process lifetime
and synchronization must keep the releasing handle alive while the image
is in use. Independent copies of a handle require a shared ownership
discipline at their callers.

`process-group-lifetime` checks the release decision with two exiting
members, an arbitrary representable prior teardown count and an optional
new member. `scheduler-teardown` exercises the native exit path with a
peer exiting while the lock is released. It checks that boot routing is
detached before destruction and the group survives through notification.
It runs the native GC wait before unlinking. The lock, condition variable
and destructor are modeled at their call boundaries.
`scheduler-spawn` exercises process quota and PID exhaustion, both
notification allocations, child allocation and notification rejection.
It runs the native encoder handoff and process setter with any permitted
copy count and up to one transferred external byte array. Its assertions
cover the sender's charge and finalizer flag, the child's argument slots,
and ownership of the encoder buffer on admission and refusal. The group
starts with zero or one peer. Child construction, notification delivery
and scheduling use contracts.

The format-2 boundary represents the current task and its stack as
mutable process state. After a collection the caller must read both
pointers again. The `grow-stack-stale-task` regression retains the task
pointer across that collection and fails when it tries to use it.

The format-2 boundary owns four concrete header words for each stack.
VeriFast checks the native reads of length, top, packed record bounds and
bytecode index, the write of top, and the slot address computed from a
primitive argument's position. It compares the header offsets and sizes
against the compiled C++ constants for both host word sizes. Record
packing on write uses the native `stack-records` check described below.

The stack-growth proof takes a fresh format-2 stack with an allocated
header and initialized slot storage. The two copies preserve the record
prefix and live suffix. The unused gap stays initialized, as required by
Rust's `StackMem` view, when the task publishes the destination.
The `grow-stack-missing-slots` regression removes the live-slot copy.
The `fresh-stack` check calls the C++ allocator for every length through
`Stack::max_length()` with a valid loaded class ID and a raw reservation
that can fail. It checks the slot range, header, guards and the address of
each primitive argument counted from the end of the array. It applies
the VeriFast fill contract at an arbitrary slot. The slot contains tagged
zero for format 2 and retains its incoming value for format 1. The `stack-records` check
packs and reads back every frame top, finally count and bytecode index
that fits such a stack, and checks all unaffected header words.

`initial-task-capacity` compares the process-group admission check with
the actual initial stack and task reservations for every class descriptor.
It covers both host word sizes and the smaller FreeRTOS page. The separate
`allocate-task` harness exercises native task and stack initialization
with two to six task fields, a symbolic task ID and a bounded young-space
window. It checks failure at either reservation, guard words, task fields,
the write barrier, the sentinel and when the ID advances.

`instance-allocation` checks every encoded instance size, a symbolic
class ID, and the exact-fit and insufficient-space paths. It checks the
arguments to `Utils::fill_words` and applies that function's VeriFast
postcondition at an arbitrary field. The native allocator writes the
class header and sentinel. An empty descriptor fails before reservation.
`task-all-fields` uses the same fill contract inside native task creation
for every representable task field count starting at two.

`scheduler-gc-barrier` checks native target selection for every process
state. It exercises two collectors with at most one cross-process barrier
owner and checks that their claims cannot overlap. It runs native FIFO
removal with an optional predecessor and successor, checks the repaired
tail and ready count, and runs the native wait with zero or one
spurious wakeup and an arbitrary nonnegative preemption count.
`scheduler-gc-scan` runs the native collection loop for a single registered
target and up to one running interpreter. It checks idle scans, an arriving
waiter, a barrier owned by a peer, and preemption with either acknowledgment
or timeout. A worker still running after a timeout must be skipped. The
production code claims and resumes idle and scheduled targets. Two wakeups
during the heap callback produce one ready entry on ordinary resumption.
The heap callback, OS calls and worker notification use observers.

`scheduler-gc-ownership` starts with the target owned by a collector,
an arbitrary requested and active priority, and an optional pending wake.
It checks each locked wakeup, priority change and competing claim preserves
the collector link. Release removes the link before queuing a runnable
process at its requested priority. A barrier waiter stays suspended.
These native checks supply the selected physical FIFO at the bucket lookup
and run the production FIFO operations. `scheduler-target-queue` separately
checks the actual scheduler array for symbolic priorities, including when
two priorities address the same bucket.

`scheduler-ready-dispatch` proves the dispatch loop for arbitrary finite
contents of all five priority queues. Given FIFO empty/pop contracts and an
initial count equal to the total length, dispatch returns the first process
in priority order, preserves the remaining FIFO order in each bucket and
updates the count. Empty dispatch returns null with a zero count.

`scheduler-gc-targets` proves queue construction for any finite registry.
It follows the group anchor and each group's null-ended membership list,
passes the barrier ownership flag to every claim and appends each admitted
process once in visitation order. It preserves the original membership
links. The input assumes a well-formed registry and a detached scheduler
link for each successful claim. Scanning calls the heap scan helper with the original
collection mode once per entry, returns the queue length and preserves the
links. Cleanup consumes the queue and calls resume in FIFO order for every
ordinary suspension. The proof assumes a well-formed claimed queue with a
representable length, a terminating scan that preserves its links, and
state observations under the scheduler lock. `scheduler-target-queue`
checks the native worker, group, member and queue iterators and FIFO
append and pop, including separation from the group membership link.

`scheduler-gc-workers` proves that the preemption loop visits every
worker in list order and sends one signal per interpreter bound to a
process other than the requester. Each pass replaces every worker's mark
with its membership in that request. Its returned count equals the number
of signals. Acknowledgment consumes the mark, decrements a positive count
once and wakes the collector when the count reaches zero. A late return
after timeout clears the mark with the count still at zero. The proof assumes
a stable finite worker list of at most `INT_MAX` entries, valid live process
pointers and a terminating signal operation that preserves the list and
interpreter bindings.

`scheduler-worker-handoff` follows one native worker-loop dispatch from
dequeue through return to the scheduler. Its interpreted process has the
untrusted policy. It also checks a trusted external runner. The fixture
includes a queued peer, an initial GC waiting for another interpreter, and
a collector requesting preemption during the unlocked execution callback.
One schedule runs the native cross-process collection to completion before
the dispatch returns. Its wait times out for a bound interpreter, and the
collector skips the running heap. At a dispatch barrier wait, the fixture
runs native target selection, scan and release over the subject's group.
The heap callback checks both worker bindings and the suspended state.
Assertions reject any call to ordinary GC suspension or resumption for this
worker-owned subject.
It checks publication and retirement of both worker bindings, elapsed CPU
time, skipped execution for pending signals, and routing of yields, kills,
termination and device halt requests. A previous dispatch leaves a method
pointer in the interpreter. Only a new run that returns preempted may read
the header for a sample. The fixture checks profiler activation bookkeeping
with no sampleable task. Interpreter and runner bodies, locks, condition
variables, profiler notification, ready notification and termination use
observers. The fixture stops the worker after that dispatch.

`gc-mark-queue` checks the native grey-mark, repeated-visit and overflow
operations with arbitrary existing mark bits and valid metadata storage.
It checks the one-bit change, the second mark bit on either side of a card
boundary, and the overflow recovery address. An overflow sets exactly one
card bit and records the earliest of the previous and newly queued object
starts, preserving adjacent bytes.

`gc-overflow-byte` checks the production bitmap scan with arbitrary starting
bits and arbitrary further overflows during each callback. It checks the
order and address of every selected card, immediate clearing before the
callback, same-pass handling of flags raised ahead of the scan, and
retention of flags raised on the current or an earlier card.
`gc-overflow-registration` connects the native overflow recorder to the
group scanner. Starting with any existing flags and valid recorded starts,
it registers two word-aligned objects in any order, including on the same
card. Both fall within the delivered scan intervals, every marked card is
delivered once, and its interval begins at the earliest recorded start.
The Frama-C target `gc-page-scan-wp` also proves by induction over a
sequence of arbitrary representable length that the production registration
update preserves every earlier discovery. For any of the eight cards,
its flag after the sequence is set exactly if it was set initially or an
event selected that card. Its start is the earliest of its initial valid
start and all offsets registered for it, including duplicates. The sequence
covers registrations between scans that clear flags.
This check observes intervals before object traversal. The per-card proof
supplies the traversal under its heap-partition assumptions.

`gc-overflow-card` checks the native per-card object walk. For any object
start in the scanned interval before the chunk sentinel, the walk inspects
that object and traces it and marks its post-visit extent exactly when it
is grey at inspection. Positive extents give the loop a decreasing
distance to the sentinel. The partition contract supplies a readable header
at each boundary, a zero header only at the sentinel, and sizes that
advance to a valid boundary without skipping an original object. Stack
visitation may shrink the current object. The chunk loop pairs each group
of eight cards with its metadata byte and drains the mark stack after
each group. `gc-mark-process` checks repeated passes over the actual
old- and young-space chunk lists. The proof nominates arbitrary chunks
in both spaces and permits deferred cards to exist while the overflow
flag is clear during a pass. The process returns with the queue empty,
the flag clear and no pending cards in the nominated chunks. Raising
the flag after a reset requires a first discovery, so another pass
decreases the number of unmarked candidates. This result assumes stable
chunk ownership, valid heap partitions, complete marking callbacks and
the correspondence between recorded work and physical bitmap bits.

`v2_gc` verifies the handoff from the format-2 interpreter to the scheduler.
Before collection it remembers the current task's stack and forwards the
malloc-failure and cross-process collection flags. Attempt three reports
allocation failure and preserves the VM state and epoch if reporting returns.
A primitive call consumes evidence that its argument stack was remembered.
The retry reloads the stack and runs the barrier again after collection.
The FFI proof reads the current task from the object heap and reads or
writes the task's stack pointer at the checked `Task::STACK_INDEX`.
The store that publishes a grown stack requires evidence that the task's
card was marked. The field accessors use the native `Instance::at` and
`at_put` bodies with permission for this one slot.
`gc-stack-barrier` checks the native barrier on both word widths for an
arbitrary aligned stack header and installed card mapping. Collector
semantics, scheduler synchronization, and OS reporting still use contracts.

`gc-process-roots` checks the addresses, lengths and ordering of the
ranges supplied by `ObjectHeap::iterate_roots`. Its callback visits
the task slot, the globals range (including length zero), and
each reachable external-root and notifier slot. The harness supplies
forward chains with up to two nodes of each type and a symbolic valid
global count. In `gc-current-task`, the callback writes a chosen task
address into the process root. The harness reloads that task and scans
its two fields through `HeapObject::roots_do`. Updating the stack reference preserves the ID,
and the native accessors return the selected task and stack whether
either, both, or neither moved. The harness supplies the forwarding addresses.
`gc-root-iterator` checks the mutable C++ cursors and the
local link updates that prepend a head or remove a registered node at any
position for both node types.
`gc-process-root-lists` proves that the production enumeration terminates
and delivers those same ranges, in order, for arbitrary finite forward
chains on ILP32 and LP64. The callback may update slot values while the
proof retains ownership of the list links. The global-count getter uses
the contract checked by the native harness. Establishing that all live
references have been registered at collection time remains open.

`gc-process-epoch` checks the production `Process::gc`, `ObjectHeap::gc`
and `set_task` on LP64 and ILP32. For an arbitrary starting epoch, each
completed collection increments the exported word once under the heap lock,
including wraparound. The check covers collection kind, counters, retry
state, full-collection limits and task publication. Lock primitives, the
two-space collection and space-size measurements use contracts.
The FFI predicate owns the exported epoch word and tracks its unbounded
count. VeriFast checks the native increment at every starting count,
including wraparound, and checks that publishing a task advances the
count exactly once. Both GC and task publication use this increment.

`gc-scavenge-clone` verifies both native specializations of
`ScavengeVisitor::clone_into_space`. Given a valid object size that fits
an int, aligned to a word, initialized source bytes, a valid allocation
window and the libc copy contract, the destination retains the original header and payload.
The original header then points to the destination, its payload remains
intact, and allocation failure preserves the entire original object. The
clone calls import the generated allocator contracts from `heap/semispace.gen.h`.
The young allocator leaves a sentinel after the copy. The old-space fast path
records the start, and the slow path retains the free-list or new-chunk
provider's outcome.
`gc-scavenge-roots` proves the native range loop terminates and visits every
reference slot in order, including empty ranges and repeated references.
The proof includes the single-slot helper. A reference outside from-space stays
unchanged. A forwarded object reuses its installed destination. A first visit
copies or promotes the object, falling back to young space when promotion fails.
The card byte and old-space collection request retain their initial values
unless a young reference or a failed promotion respectively requires an update.
For a distinct inventory of source objects and valid root values, the proof
owns each object's header word. It follows the native tag test and header
load. Both clone bodies establish the same tagged forwarding pointer that the
visitor consumes. Installing one entry preserves the other headers, so a
later alias reads the installed destination. For a chunk whose extent fits in the
address space, both native membership checks implement a half-open interval,
including when unsigned subtraction wraps below the start. The source test
also rejects every tagged integer. The relocation map records the address
returned by each first successful copy. The final array equals the result
of applying that map to every original slot. Exclusive ownership of each
copied header prevents distinct copied sources from acquiring the same
destination. Collection entry still supplies the source inventory and valid
chunk descriptors. The native visitor constructor derives both cached intervals
from those descriptors. For a borrowed destination chunk, the embedded semispace
constructor establishes the empty allocation window, writes its first sentinel
and preserves the remaining words. The empty source-list case is excluded by
the single-chunk lookup contract. The native owner setter publishes the supplied owner,
uses its page type, and invokes all four initializers. Given the table mappings,
the native fills reset overflow bits, remembered cards and object starts over
their exact slices. Clearing the owner preserves that metadata. For mapped chunks the page table receives one classification byte per page.
The two host targets both use the 32 KiB page size checked against the VM headers.
The native clear zeros one mark byte per eight heap words. The remembered-card
and overflow accessors derive their addresses from the published biases.
These proofs require aligned chunks and mapped storage with the expected
extent. The semispace proof uses the native object-start accessor for both bulk
initialization and single-byte allocation records. Its address-range test includes
the upper endpoint. The setup harness checks interior addresses against the
committed tables and checks lookup at their logical end. The native space constructor initializes the program, page
type and zero allocation bounds. The native semispace append sets ownership and
links the destination chunk. The same sidecar proves removal for an empty or
single-chunk space, including reclassification of the full page range. It also
proves that survivor transfer rebinds the descriptor, transfers the allocation
window, and clears the temporary space's bounds. The underlying list operations, the LivenessOracle
base constructor, and ownership of mapped memory still supply contracts. The allocator supplies storage, the placement of successful
copies in the requested space, and enough young-space capacity.
`gc-scavenge-alias` exercises the native root visitor on a three-word
object with repeated references. It checks promotion, fallback when old
space refuses allocation, and direct copying to the destination semispace.
A later alias in a different root range must reuse the forwarded object
and record a young destination on that range's card. The harness assumes
to-space can accept the survivor.

`gc-promotion-capacity` checks the production page calculation used by
`OldSpace::allocate_in_new_chunk`. For every request, preferred size, signed
expansion limit and tracking mode, it verifies exact admission and the chosen
page count. A successful request fits its object, the sentinel and, when
tracking, the three-word promotion header.

`old-chunk-expansion` checks the native expansion decision together with
the process quota calculation. It includes both space reservations and
external memory, even when their mathematical sum exceeds a machine word.
A stopped promotion or insufficient budget requests no pages. A provider
failure sets the malloc-failure flag. Success installs the admitted page
count and retries the original payload size exactly once. For a bounded
process the remaining allowance drops by the size of the entire linked
chunk. The check uses the space-size, installation and bump-allocation
contracts and assumes stable quota inputs during the call.

`gc-scavenge-drain` proves termination of the loop that alternates scans
of the destination semispace and promoted objects in old space. Either
scan can enqueue work in either space. The proof includes
`OldSpace::complete_scavenge` and its per-track walk. After flushing, it
detaches the original chain, selects the object's card before each visit,
advances by the post-visit size, and retires every detached header. New
promotions remain on the live chain for a later pass. Empty tracks report
no work. The old pass imports the generated `free_list.gen.h` contract for
`OldSpace::flush`, opens the concrete end word of the current header, and
recovers the trimmed range and the free-list update. The budget includes
occupied old payloads, unused bump space, free-list regions and retained
short fillers. Starting a scavenge flushes the untracked allocation window
before enabling tracking and preserves its capacity. The drain exits with
the physical track head null, satisfying the tracking exit condition. The old pass deducts each detached nonempty extent. A root
visit can transfer capacity to another region subject to the combined bound. The same proof includes the young-space pass over
a finite chain of chunks. Each empty chunk shortens the remaining walk. A
nonempty chunk advances its scan pointer and can append chunks. Remaining
young capacity is the sum of chunk ends minus scan pointers. The loop combines
this capacity with the old-space and external reserves. The iterator
reads its successor after the visit. A visited chunk stays drained and
the pass reports work if any visited chunk contained objects. The per-chunk
interface assumes the pending suffix survives allocation, visited chunks
stay drained, and the number of remaining chunks fits in an address word.
Providers must charge appended capacity against the available reserve. The native `gc-promoted-track` check covers track initialization,
card metadata, trimming the end, and replacing exactly the three header
words with single-word fillers. `gc-scavenge-chunk`
verifies the inner walk of a destination chunk. The queue can grow at
each call to the object's root enumerator. For an arbitrary object
address initially pending or newly enqueued, the walk visits it exactly once before
publishing the final sentinel as the next scan position. Progress follows
from positive object sizes within the chunk limit. The allocator derives a finite,
duplicate-free list of aligned addresses from its window and splits that list
at each successful reservation. Given coverage of the current chunk, the scan
removes visited addresses without relying on the callback for membership.
For every address in a duplicate-free input pool, membership in the returned
pool is equivalent to having remained unvisited. Object layouts and the
enumerator's preservation of the pending suffix supply contracts.

`gc-collection-phases` checks the production full-collection entry on both
word sizes. Strong roots, callback finalizers and VM finalizers feed three
marking waves before the collector computes destinations. Sweeping publishes
the survivor size and clears young marks. Compaction uses old-space marks
to select live young objects, updates ordinary and finalizer roots before
clearing marks, and restores chunk ends. The harness checks the selected
mode, callback identities, ordering and byte accounting. Enumeration,
object movement, finalizer behavior and bitmap operations supply contracts
at these call sites.

`tests/gc-mark-overflow-test.toit` exercises the untrusted
runtime with a cyclic graph of 320 live children, checking their payloads
and links after allocation pressure. A host run instrumented at the card
walker confirmed that overflow recovery ran for this test's snapshot UUID.

`gc-object-size` checks the production size dispatcher for all twelve tags
with valid class metadata and representable layout fields on both word
sizes. It also checks the overflow walker's one-word exception. For a
discovered object whose native size is one word, the mark covers the
whole extent and the native root enumerator delivers no reference slots,
even with weak-map skipping disabled. For a larger object, the grey test
reads the second mark inside the object, including across a card boundary.
The size coverage includes single-word fillers, free regions, promoted tracks,
internal and external byte arrays and strings, boxed numbers, and stacks.
The harness materializes the header and class entry and checks that the
reported extent matches the represented layout. Actual allocation of that
extent, construction of a complete partition, discovery of all roots and
preservation of the reachable graph across marking, movement and sweeping
remain separate obligations.

The Frama-C target `gc-page-scan-wp` checks the card traversal and filler helpers used directly by
`OldSpace::sweep` on both word sizes. The empty-card scan clears the
object-start entries of the empty run, stops at the first nonempty card or
the chunk end, and permits whole-chunk release only for an entirely empty
mark map scanned from its start. For every 32-bit card pattern and every
starting word from zero through 32, the filler loop writes its marker to
each unmarked word in the selected suffix and preserves the prefix and
every marked word. The caller supplies aligned card storage and the mark
map.

`gc-sweep-free-region` checks the production calculation of the interval
passed to free-list insertion. For an aligned run of one or more empty
cards it admits arbitrary nonzero neighboring mark words or a chunk
boundary. The preceding suffix and following prefix end exactly at the
nearest marks. At the chunk end the extent excludes the sentinel. Each
interval has room for the native header, and skipping filler writes in a
following card implies that every word after the prefix is marked. This
check takes the empty run and neighboring marks from the production card step.
Frama-C checks that the step reads the exact adjacent mark words, substitutes
the boundary values only at the chunk edges for an empty run, and advances
past the following marked card. An induction from card zero proves that
repeated steps terminate and select each nonempty card exactly once for any
valid number of cards. Intervening heap and free-list writes must preserve
the mark map.
The header constructor and insertion have separate proofs (`free-list-region`
and `free-list-search`).

For whole-object marking, `gc-mark-all` checks the native fast path and
selection of the slow path with both aligned and unaligned access on both
word widths. `gc-mark-range` checks the production slow marker, including
machine-width object sizes, against an arbitrary bit inside or outside the
requested interval. Its bulk-fill observer uses the contract of the native
32-bit word loop. `gc-bitmap-fill` proves that loop by induction over its
element count. These checks require a valid object extent and writable,
mark-table storage aligned for a 32-bit word. The harness varies the offset
of the table relative to the heap page's mark bytes. The C++ build of the fast path
with unaligned access uses little-endian words.

### The externals' ownership (wave 5, done)

A message (`msg_whole(b)`) owns its malloced buffer and its out-of-line
blocks `ps` (the order of their pointers; `encoded(b, cap, ps)` is the
abstract fact that the encoder wrote it). The decoder's predicate `dec`
holds, for IPC, the blocks after the j pointers read (`ipc_pos`), and for
a decoder with a process the `lent` tokens of the first k (one per entry
of the externals table: `finalized(o, p)`, from allocate_external_*), and
block k when its allocation failed (status ALLOCATION_FAILED).
read_pointer hands block j to its caller (`ipc_pointer`: the j-th pointer
is the j-th block; ownership is never created, only moved), so the walk
of MessageDecoder::deallocate frees each block once, and a decoder for a
process holds it out (`dec_out`) until register_external records the
token or mark_allocation_failed takes it back (`dec_af`).
remove_disposing_finalizers turns every token back into its block
(`clear_has_active_finalizer`) and gives the whole message back
(`dec_back`); on a success `ipc_end` says every block was read, hence
lent, and the tokens go to the GC (`gc_owns`). The "reads stop at the
first failure" fact is the condition `not_failed` on the decoder's reads
and marks (a decoder for a process reads no pointer after an allocation
failure). The finalizer bit is in the header word, so the receive
primitives keep `grows_class` (classes, lengths and aux words), not
`grows`. The malformed path of the three primitives fails the proof
without the drop (mutants *-malformed-delivered); the drop is applied
(05159afd). Modelling clear_has_active_finalizer's contract ("gives the
block back") exposed the double free of "Findings".

### The two-pass assumption

Every caller of the encoder (process_send, spawn, the program registry's
spawn, tison_encode) runs it twice on the same heap: a size pass without a
buffer, then a write pass into a buffer of the size the size pass
returned. The encoder never checks a write against the buffer: a write is
in bounds only because the size pass counted it. This is the encoder's one
assumption, the bodiless lemma `two_pass_room` (encoder/message_encoder,
CONTRACTS.toml `[[assumption]]`, checked by contract_check.toit: listed,
bodiless, its contract as written; an unlisted bodiless lemma of a
rendering fails the check): at a write of n bytes at cursor c in the write
pass, `c + n <= cap`. Why it holds: both passes decide the same way (the
heap, the policy and the encoder's inputs are the same; between the
passes the callers only allocate the buffer); the write pass can stop
earlier, never later (its only extra failure is a failed malloc; TISON
writes the payload's cardinal before the payload instead of after, so the
write pass's sizes are ahead by at most that cardinal and its size checks
fire first); so it writes a prefix of what the size pass counted. To prove
it: a ghost encoding function over the heap and the encoder state (the
early stops depend on the cursor, the externals and the transfers),
shown equal for both passes (5-7 days). Everything else about the buffer
is proved: the writers keep `cursor_ + external_bytes_` below the limit
plus ENC_SLACK on both widths (the predicate `enc_out`), and every write
goes to `uchars_(buffer, cap)` at the cursor.

### The decoder's assumptions

The untrusted path, TISON (`tison_decode`: the bytes of a blob, `size_` its
length), needs none: every reader checks the cursor against `size_`. The
inter-process path decodes a message the encoder wrote, with `size_` set
to INT_MAX: the readers' checks do not bound the reads by the message.
Bodiless lemmas (CONTRACTS.toml `[[assumption]]`, checked by
contract_check.toit like `two_pass_room`) state what that path relies on
(wave 5 split the old `ipc_external`, which created a block's ownership
out of nothing, into narrower facts; ownership now comes from the message,
"The externals' ownership"):

* `ipc_begin(d, b)`: a decoder constructed over an encoded message reads it
  from the start (names the message, `[_]ipc_msg(d, b, cap, ps)`, and
  starts the pointer count `ipc_pos(d, 0)`).
* `ipc_room(d, n)`: a read of n bytes at the cursor lies in the message.
  Used at each read of the IPC path, with the read's size.
* `ipc_pointer(d, p)`: the j-th pointer read is the j-th block.
* `ipc_external(d, length)`: the length before a pointer is a content
  length, below MESSAGING_ENCODING_MAX_SIZE.
* `ipc_length(d, n)`: a length the deallocation walk reads is that of what
  follows (a byte per element at least).
* `ipc_end(d)`: after the message's value (a process's decoder: with
  success; the walk: always) every pointer was read.

and the GC's `gc_owns` (an object with an active finalizer owns its block).

Why they hold: the encoder writes the message, the decoder reads it in the
same VM with the same tags and limits (nesting 8 against 64, the smi
range, array and map lengths: since this branch the encoder refuses arrays
and maps longer than a process heap holds, "Findings"), so it reads
exactly what was written; each out-of-line block is written once, after
reserve_external (at most 8). Proving them takes the encoder's ghost
encoding (the two-pass assumption's) as the decoder's input. Like
`two_pass_room`, each is used only at the reads it describes (an
assumption with a large `n` would give false: review the calls, they are
in the reader functions and the two out-of-line branches).

The proof's model of the input is a chunk separate from the heap. For
tison_decode the bytes are the content of a heap object (Blob): the
allocations must leave it alone, which the allocator does (it only adds
objects) but which the contracts state over `heap(objs, H)` as a whole;
the primitive's glue is not rendered yet ("Not attempted").

Past bugs of the upstream series #3361-#3382 in the covered code are
mutants (byte_content depth 357d1127, the encoder bounds f708ad5d, the
UTF-8 bounds 07c24665, the string_write memmove af4ba7ab, the decoder's
nesting and cardinal shift of #3362); those in the units not attempted
(encoder recursion and buffer overflow of #3373/#3374 are in the encoder
proof's checks but have no mutant of their own, encoding size truncation
of #3378, malformed system messages of #3381) become mutants with them.


## Findings

Wave 6 (the external handlers' sender side, `sender/`):

* **MessageEncoder's one-argument constructor did not take its buffer: the
  external message handlers leaked it whenever the message could not be
  allocated** (FIXED here, src/messaging.h). The class says it takes
  ownership of the buffer and frees it in the destructor unless
  take_buffer() gave it to a message; ExternalSystemMessageHandler::send_
  (behind toit_msg_notify and ExternalSystemMessageHandler::send) and
  reply_rpc (toit_msg_request_reply) rely on it: when `_new SystemMessage`
  fails they return MESSAGE_OOM "since the destructor of the encoder
  already takes care of" the buffer. But `MessageEncoder(uint8* buffer)`
  left take_ownership_of_buffer_ at false, so each such failure leaked the
  encoded buffer (the data itself was handled right). Reachable from
  native services under memory pressure (the C API), not from Toit code.
  Found when the destructor's contract had to give the buffer back in
  send_'s out-of-memory path. Fix: the constructor sets the flag (its
  other users, Process::set_main_arguments and set_spawn_arguments, always
  call take_buffer). Reproducer and regression test:
  tests/ctest/message-encoder-ownership-test.cc (a 1 MB buffer, mallinfo2:
  fails without the fix). Mutant sender-encoder-owns-buffer. Upstream
  master: the same constructor and the same two callers.
* No other ownership bug on the external handlers' sender side: the data
  is freed exactly when free_on_failure says so, the buffer exactly once.
  RPC reply ids must be non-negative (write_cardinal of an int as a uword):
  the Toit side wraps its ids below 2^30 (lib/rpc/rpc.toit).

Wave 6 (the Rust/C++ boundary, `ffi/`):

* **The trusted GC contract of waves 1-5 was false: it said the stack's
  used slots were byte for byte the same after a collection** (FIXED in
  the model; no C++ change). v2_gc's contract (grow_stack's, wave 1)
  ensured `same_abstraction`, i.e. `drop(top * W, bs2) == drop(top * W,
  bs)`: a moving GC rewrites every reference slot to the moved object, so
  the claim was false whenever a slot held a moved object, and the proof of
  stack growth rested on it. It now says what the GC does: the VM state
  after it (stack, heap, epoch) is `gc_equiv` to the one before (the
  abstraction is the same, an uninterpreted relation the `stack` and `heap`
  bridges interpret), and stack growth, the allocations and the primitive
  call are proved over that, with `stack_copy_equiv` (the old `stack`
  bridge, now a named assumption) for the copied stack.
* **An assumption of the Verus side the C++ wrapper does not establish:
  the retry of a primitive after an out-of-memory failure completes the
  original step** (`prim_retry`, CONTRACTS.toml). gc_call_primitive says
  the whole C++ call is a completion of the PRIMITIVE step; the C++ calls
  the primitive up to four times, each time on the state the failed call
  left (after a GC). That is a completion of the original step only if a
  call that fails for want of memory changes nothing the spec sees: a
  property of every primitive (allocate before changing anything), not of
  the wrapper, and stated nowhere before (TRUSTED.md section 8 lists
  prim_default only). Reviewed for the untrusted set's C++ primitives
  (process_send neuters transferred byte arrays only after the message is
  allocated; the receive primitives give the blocks back on an allocation
  failure, wave 5); not checked for the others.
* **The epoch the core relies on is sound only because the retry loops are
  bounded** (verified; no bug). The core keeps its stack view when the
  epoch word is unchanged (TRUSTED.md, Epoch). The word wraps; the proof
  shows at most three collections and four primitive calls per C++ call,
  so an unchanged word is an unchanged count. The mutants ffi-*-retries
  take a bound out: the proof fails.
* The string allocator now rejects `INTPTR_MAX` before adding its terminator.
  The native `process-blob-allocation` check covers both FFI entries and the
  process allocators across the full input word. The `byte-array-initialization`
  check follows each byte-array constructor to the libc fill and checks its
  destination, extent, and value for internal and external storage.
* The VeriFast model is narrower than the C++ in three places, listed as
  gaps in CONTRACTS.toml: class ids below 1024 (`header_ok`), blob lengths through 2^30 − 1 on ILP32 and INT_MAX on LP64
  (the allocation precondition; TRUSTED.md allows lengths below 2^62 on LP64), and incomplete allocator payload contracts (a new instance's null
  fields, a double's bits, a byte array's zeros are the allocator's, not
  stated). The exception wrapper still converts its value from a word to a
  pointer. The no-GC array wrapper takes the tagged filler as a pointer;
  Rust reconstructs it with exposed provenance at the trusted heap boundary.
  Its caller proves the filler is encodable and denotes a smi or live object.
  The wrapper checks the length and passes the filler through. Given writable
  storage for a fresh array, the initializer sets the length and fills every
  slot. The allocator contract still supplies the storage, sets the class,
  and connects the initialized object to the heap model.
* The model's large-integer allocator no longer requires a value outside
  the smi range (the C++ takes any value, and the Rust allocator's
  contract has no such precondition); decode_integer's postcondition
  keeps the decoder canonical (mutant decoder-integer-canonical).
* Build: test snapshots did not depend on the compiler (f3f44dde: they do
  now, through the toit.compile target).

Wave 5:

* **Double free of a message's out-of-line data when a receiver dies
  after a failed decode** (FIXED here, src/heap_roots.h; 05159afd).
  Reachable by any process, sandboxed included, against the VM's malloc
  heap. A failed decode gives the blocks back to the message by clearing
  the finalizer bits of the external strings and byte arrays it made
  (remove_disposing_finalizers); their VM finalizer nodes stay until the
  next GC, which unlinks them. VmFinalizerNode::heap_dying freed the
  memory of every node without looking at the bit. So a process that
  fails to decode a message twice (an allocation failure, and again on
  the retry after the GC: task_receive_message throws) and then ends
  (uncaught exception: no GC in between) frees each such block twice: the
  message frees it when the process deletes its mailbox, the dying heap
  again. A receiver controls both its heap limit (set-max-heap-size) and
  its end, and any sender can make the message (a byte array over 128
  bytes, then lists). glibc aborts the VM ("free(): double free detected
  in tcache 2"); without its check, heap corruption. The same with
  main_arguments and spawn_arguments. Found while writing the contract of
  clear_has_active_finalizer ("gives the block back") for the receive
  proof: the GC side did not honour it at heap death. Fix: heap_dying, like
  weak_processing, frees only when the bit is set. Reproducers and
  regression tests: tests/message-receive-oom-test-compiler.toit (end to
  end from Toit code: aborts without the fix) and
  tests/ctest/message-receive-ownership-test.cc (through main_arguments,
  also host32). Upstream master: the same heap_dying and the same callers.
* **The malformed-message leak of wave 3: fixed and proved** (05159afd;
  the wave-4 draft applied). task_receive_message, main_arguments and
  spawn_arguments drop a message the decoder rejects (after giving the
  blocks back) and free all of it; before, it was delivered as decoded
  and the blocks after the error leaked. Unreachable from this branch's
  encoder (b609da9f), reproduced with a hand-made message
  (message-receive-ownership-test.cc: 1 MB leaked without the fix). The
  drop alone would have introduced the double free above (the dropped
  message frees the blocks the decoded objects' nodes still name): both
  are needed. Upstream master: delivers malformed messages as decoded.
* **encode_error read a proxy byte array as bytes** (FIXED here,
  src/encoder_visitor.h EncodeVisitor::visit_byte_array; reported by the
  coordinator from the core fuzzer on the assertion-enabled sanitizer
  build: `objects.h:591 external_tag() == RawByteTag || ...` 3 times).
  The exception and trace encoder (encode_error: any object as the error's
  message, and the stack) built ByteArray::Bytes over any byte array; for a
  proxy (an external byte array whose address is a C++ struct: a timer, a
  resource group, tagged with the struct's type) that calls as_external,
  whose assertion forbids it. The code is wrong, not the assertion: it
  treats a struct pointer as bytes. Release builds read the proxy's
  external length, 0 for every proxy the VM makes, so nothing was read
  (no memory-safety impact in release; assertion builds stopped). Fix: a
  non-raw external byte array is encoded as empty. Regression test:
  tests/encode-error-proxy-test.toit (stops the asan build without the
  fix). The byte-array writer now has a native
  ESBMC proof for both word widths. The message encoder uses the separately
  proved byte_content, which refuses proxies.
* No other bug in the receive path: on every path (no message, a monitor
  notification, a finalizer to run, the result array not allocated, an
  allocation failure, a malformed message, success) the message's buffer
  and blocks are freed exactly once (or kept whole for the retry), and
  the walk of MessageDecoder::deallocate frees every block once (under
  the IPC assumptions).

Wave 4:

* **TISON integers were not portable between 64 and 32 bits** (wave 3's
  finding 3, FIXED here, src/messaging.cc; 1d19379a). A 64-bit VM writes
  smi tags up to 2^62, which a 32-bit VM rejected above 2^30
  (WRONG_OBJECT_TYPE: a millisecond timestamp in an asset), and a 32-bit
  VM writes large integers that a 64-bit VM decoded as non-canonical large
  integers in its smi range (equal, not identical, encoded again as large
  integers). Fix: the smi tags' magnitude is read with 64 bits on both
  widths (read_cardinal_64; read_cardinal checks that a length fits the
  word) and decode_integer makes every integer canonical: a smi whenever
  the value is in this VM's smi range, else a large integer (int.MIN only
  with the large-integer tag). Proof: decode_integer's postcondition (a
  smi for a value in the smi range; until wave 6 also the allocator's
  `canonical` clause), mutant decoder-integer-canonical. Tests:
  tests/tison-integer-width-test.toit (host and host32: fails without the
  fix on both), tests/tison-test.toit updated (2^62 with a smi tag is now
  an integer). Upstream master: the same decoder (smi tags read as words,
  large integers allocated as they are).
* **decode_process_message decoded any message without a process** (wave
  3's finding 4, made SAFE here; 1d19379a). Not provably unreachable (any
  unrestricted process can send a TERMINATED system message with any
  content; the window, no boot process, is empty in practice), so it now
  reads only an integer in the range of `int` and refuses everything else
  before decoding it. Reproducer and regression test:
  tests/ctest/message-process-message-test.cc (crashes without the fix:
  null, strings, arrays and large integers dereferenced the missing process
  or program). Upstream master: the same code (`decoder.decode()` with a
  null process, "TODO(kasper): Make this more robust").
* **time_info: signed overflow near INT64_MIN** (red-team round 4, FIXED
  and PROVED here, src/primitive_core.cc utc_fields). The seconds of the
  day were `timestamp - days * SECONDS_PER_DAY` with `days` rounded down:
  for the timestamps of the last partial day above INT64_MIN the product is
  below INT64_MIN (undefined behaviour, UBSan flags it; release builds
  wrapped and then threw OUT_OF_RANGE for the year). Reachable by an
  untrusted program calling the primitive directly. Fix: floor_mod. The
  primitive and its whole calendar are now proved free of overflow and
  lossy conversion for every int64 on both widths (`prims/time_info`); the
  proof found no other overflow (local_fields' year check is what keeps its
  shift in range: mutant time-info-local-year). Regression test:
  tests/time-info-range-test.toit (the window's timestamps; meaningful
  under UBSan, the proof is the guard in release builds). Upstream master:
  not affected (utc_fields is this branch's, 431ceaf8; upstream's time_info
  calls gmtime_r/localtime_r and returns uninitialized fields when they fail,
  fixed here by 637498d3). If 431ceaf8 goes upstream, the fix goes with it.
* **decode_external_data: the inline length was unchecked** (hardened here,
  src/messaging.cc; latent). The external message handlers' decoder read
  the length of inline byte arrays and strings into an `int` without a
  check: a cardinal above INT_MAX became a negative int, `malloc(max(1,
  n))` one byte and `memcpy(copy, ..., n)` a copy of almost SIZE_MAX bytes
  (heap overflow), and a length of INT_MAX overflowed `encoded_length + 1`
  (undefined behaviour). Unreachable from the encoder (it writes inline
  only small contents; the proof's `ipc_room` assumption covers it), so not
  a reachable bug; the check (`length < 0 || length > remaining()`, as in
  decode_byte_array) makes the proof independent of the assumption for
  these two values. Mutants decoder-external-inline-length and
  -string-length. Also: an RPC request's id and name are cardinals
  converted to `int` (modular: an id above INT_MAX is truncated; the reply
  goes to the truncated id; functional only). Upstream master: the same
  code.

Wave 3 (the decoder):

* **The encoders sent arrays the receiver cannot decode, and the receiver
  then leaked the message's out-of-line data** (FIXED here, src/messaging.cc
  encode_array, encode_map; b609da9f). An array of a program heap can be
  longer than a process heap holds (format-2 images bound an array only by
  the image; the format-1 snapshot reader by the program heap's blocks,
  4092 against 4082 elements on 64-bit, 1020 against 998 on 32-bit). The
  IPC decoder rejects such an array (`length > max_length_in_process()`)
  as malformed, and task_receive_message (likewise main_arguments,
  spawn_arguments) only distinguishes allocation failures: a malformed
  message is delivered as decoded, its value 0 (the decoder's null is the
  smi 0), and free_data_but_keep_externals frees the buffer but not the
  out-of-line blocks after the array (malloced copies, transferred
  external byte arrays: up to 8 per message, within the sender's message
  quota). So a crafted sandboxed program could make the system process
  leak memory with every message. Fix: the encoders refuse an array (list,
  slice) longer than `Array::max_length_in_process()` and a map of more
  than half that, so everything they produce decodes (which the decoder's
  IPC assumption needs). Reproducer: tests/ctest/message-oversized-array-
  test.cc (an over-long array built outside the heap; fails without the
  fix). Not reproduced end to end: making such a literal needs an image
  editor that grows program-heap blocks (tools/heapcraft.toit keeps block
  counts). Upstream master: the same encoder, the same decoder check and
  the same primitive (reachable there only with a crafted snapshot, as
  upstream runs no untrusted programs). The primitive's treatment of a
  malformed message stays (now unreachable from the encoder): a draft below.
* **read_cardinal dropped the bits of a digit beyond the word** (FIXED
  here, src/messaging.cc; 965bff66). #3362 bounded the number of digits
  (shift < WORD_BIT_SIZE) but not their bits: the last digit at shift 63
  (28 on 32-bit) was shifted out, so the TISON cardinal 2^64 + 5 decoded
  as 5 and 2^64 as an array length of 0 (silently, as a valid message).
  VeriFast refuses the unsigned overflow of `digit << shift`; the fix
  checks `digit > (UINTPTR_MAX >> shift)` (malformed), and the proof shows
  the sum then stays in the word (`radix.c`). Not memory-unsafe (every
  length is checked afterwards) but a second encoding of every value.
  Regression test: tests/tison-cardinal-overflow-test.toit (both widths).
  Upstream master: worse, no bound at all (`result += ... << shift` with a
  shift up to the input's length: undefined behaviour), as before #3362.
* **TISON smis are not portable from 64 to 32 bits** (FIXED in wave 4, above; a
  functional bug, not a memory-safety one). The encoder writes every smi
  as TAG_POSITIVE_SMI/TAG_NEGATIVE_SMI; on a 64-bit VM that is any value
  below 2^62. A 32-bit VM rejects one above its smi range (2^30) as
  malformed, and read_cardinal cannot even read one above 2^32. So TISON
  made on a 64-bit host (assets of host tools) with an integer such as a
  millisecond timestamp (1.7 * 10^12) fails to decode on an ESP32 with
  WRONG_OBJECT_TYPE. Fix proposal: decode an out-of-range smi tag as a
  large integer (a 64-bit cardinal reader for the two smi tags), or encode
  values outside the 32-bit smi range as TAG_LARGE_INTEGER. Upstream
  master has it too (with the undefined shift).
* **TISON large integers in the smi range are not canonical** (FIXED in wave 4, above;
  minor). TAG_LARGE_INTEGER with the value 5 decodes to a LargeInteger 5:
  `==`, hashing and maps treat it as 5, `identical x 5` is false (reproducer
  /home/flo/work/opentoit-sandbox-artifacts/annotated-cxx/repro/tison-large-
  integer-small.toit). The encoder never writes one; a fix would return a
  smi when the value fits.
* **MessageDecoder::decode_process_message decodes without a process**
  (latent; made safe in wave 4, above). The scheduler decodes a TERMINATED system message
  itself when there is no boot process, with `MessageDecoder(null,
  buffer)`: for anything but a smi the decoder dereferences the missing
  process or program (the proof's contracts require both). Any
  unrestricted process can send TERMINATED to -1 with any content, but the
  window is empty in practice: when the boot process terminates, its own
  TERMINATED message makes the scheduler terminate the VM (tried: a child
  outliving the boot program never runs again). Fix proposal (draft): check
  the first byte for a smi tag before decoding.
* No other bug in the decoder: every TISON read is bounded, every length
  is checked before the copy or allocation of that size, the half-built
  map's fields are null so a failure leaves the heap well-formed, the
  externals table is bounded (FATAL beyond 8, as the encoder reserves at
  most 8).

Waves 1-2:

* **The Verus contract of `gc_grow_stack` lacked a bound on `needed`**
  (found by both pilots; FIXED by `core/trusted-integration`, merged).
  Without a bound the C++ overflowed at `static_cast<word>(needed)` and at
  `(length - free) + needed`. Now the C++ returns STACK_OVERFLOW for
  `needed > Stack::max_length()` and verifies without any precondition on
  `needed`; the Verus contract requires `needed < GROW_STACK_MAX_NEEDED`
  (CONTRACTS.toml: a Verus-only clause, sound because the C++ precondition
  is weaker). The mutants `grow-stack-unbounded`, `grow-stack-word-range`
  take the new check out again and fail at the cast and at the sum.
* **The encoders' size limit was dead on 32-bit: heap overflow in
  `tison.encode` on the ESP32** (FIXED here, src/messaging.h and
  messaging.cc). a4d19ec2 stopped the encoders at
  `cursor_ > MESSAGING_ENCODING_MAX_SIZE` (0x7fffffff), which a 32-bit
  `word` can never exceed: the size pass of a shared object graph
  overflowed the cursor (signed overflow; it wraps), returned a small
  size, and the write pass wrote gigabytes past the byte array allocated
  for it. Reproduced on the host32 build with 100 x 100 x 43 references to
  one 10 KB string (segfault; the 64-bit VM throws OUT_OF_RANGE), and
  reachable by untrusted code with a few KB of memory (`tison.encode`;
  `process_send` and `spawn` of unrestricted senders too). The external
  byte counter could overflow the same way (8 out-of-line copies of one
  blob). Fix: the limit is 0x3fffffff and covers the out-of-line data
  (`is_too_large` checks `total_size()`), and `encode_copy` and
  `encode_byte_array` check a blob's length against what is left before
  adding it, so `cursor_ + external_bytes_` stays below the limit plus the
  few bytes written between two checks (`ENC_SLACK`). The VeriFast proof of
  the encoder needs exactly this (mutant `encoder-size-limit`). Full ctest
  green; tests/message-encoding-size-test.toit passes on both widths.
* **The out-of-line copy of a string read one byte past its content**
  (FIXED here, src/messaging.cc encode_copy). It copied `length + 1`
  bytes from the content byte_content returned, for the terminator. A
  string slice's content is not followed by a '\0' (the receiver's
  allocate_external_string repaired that), and byte_content with
  STRINGS_OR_BYTE_ARRAYS lets a crafted string slice wrap a byte array:
  for an external byte array (its own malloc block of exactly `length`
  bytes) ending at the slice's end, the copy read one byte past the block.
  Fix: copy `length` bytes and write the '\0'. The mutant
  `encoder-copy-terminator` reverts it (memcpy's precondition fails).
  Also made `TISON_VERSION` a `static const` (it was a mutable static
  global, never written).
* No bug or missing check in the newly covered code: the real
  `encode_any` (including the byte-array/string class branches, the double
  and large-integer reads and the printf of an unencodable class tag), the
  write barrier added to `toit_v2_grow_stack`, the ARGS expansion of the
  primitive, and the NestingTracker verify as they are.
* The pilot's hand copy of the encoder had the message tags off by one
  (`TAG_POSITIVE_SMI` is 1); the constant table, checked against the C++,
  has the real ones. Hand renderings do drift; generated ones cannot.
* **byte_content / mutable_byte_content: no bug** in the decoding of
  attacker-controlled slices and copy-on-write byte arrays (bounds, depth,
  the external tag, the program heap; a source range stays valid when the
  destination's copy-on-write replaces a backing in the same primitive).
  One dead check: `if (content == null) return inner_success;` in the
  slice branch of `mutable_byte_content` compares the out-parameter
  (the address of a local of the wrapper, never null) instead of
  `*content`; VeriFast proves it dead (run with `-allow_dead_code`). It
  has no effect; were it live, it would return the whole backing instead
  of the slice, still inside one writable byte array. Not changed (no
  behaviour difference); a cleanup for upstream.
* VeriFast 26.10's Rust front end does not support `>>` ("Todo:
  BinOp::Shr"): six external_body bodies of view.rs use it.

## Upstream candidates

Drafts, not filed (no issue or PR has been opened).

* Wave 6: `explicit MessageEncoder(uint8* buffer)` (src/messaging.h,
  upstream messaging.h:168) must take ownership of the buffer
  (`take_ownership_of_buffer_(true)`): ExternalSystemMessageHandler::send_
  and reply_rpc leak the encoded buffer when allocating the SystemMessage
  fails ("Findings"). One line; tests/ctest/message-encoder-ownership-test.cc
  goes with it.

* Wave 5: VmFinalizerNode::heap_dying must not free the memory of an
  object whose finalizer bit is clear (src/heap_roots.h, upstream
  heap_roots.h:94): the double free of "Findings", reachable upstream by
  any process that fails to decode a message twice and then ends. One
  line; the regression tests of 05159afd go with it. With it, the drop of
  malformed messages (task_receive_message, main_arguments,
  spawn_arguments: 05159afd) can go too.

* `mutable_byte_content` (src/objects_runtime.cc, the byte-array slice
  branch; upstream master has the same line, objects_runtime.cc:80):
  `if (content == null) return inner_success;` tests the out-parameter,
  which is never null, so the check is dead (VeriFast proves it, see
  "Findings"). The comment means `*content`: an inner success with a null
  content (a failed allocation does not give one: it returns false with
  the error set; a neutered external byte array does, address null and
  length 0). But `if (*content == null) return inner_success;` would
  return the whole (empty) backing for ANY slice bounds of a neutered
  array, where today bounds other than [0, 0] fail. Proposed one-line fix:
  delete the line (behaviour unchanged, as it is dead); the `*content`
  variant is safe (length 0) but accepts bogus bounds.
* The encoders' sizes on 32-bit: upstream master still returns the size
  as `unsigned` (messaging.h:175) and has no size limit, so the
  truncation of a4d19ec2 applies there on every width; the fix of this
  branch (a limit of 0x3fffffff including out-of-line data, blobs checked
  against what is left) is the one to propose, together with a4d19ec2.
* encode_copy's `memcpy(data, source, length + extra)` (upstream
  messaging.cc:461): the one-byte over-read for a string slice over a
  byte array ("Findings"); the fix is two lines.
* VeriFast (drafts for its issue tracker): the C++ front end rejects every
  pointer cast ("The other route" above); ghost code cannot take the
  address of a parameter before the real code does ("Taking the address
  of this expression is not supported"), so a conversion of a parameter's
  chunk before its first `&` in the code is impossible; the prelude has no
  `u_llong_integer`-to-`chars` auto lemma (model/llong.gh adds it);
  `lemma_auto` with a body is a parse error in a .c file (fine in a .gh).
  Wave 3: with the default prover (Redux) `is_smi_w(0)` (a fixpoint
  `w % 2 == 0`) is not provable, with Z3 it is (the decoder runs with
  Z3); a truncating cast has no known value even in range
  (`/*@truncating@*/(word)u` with `u <= INTPTR_MAX` is not known to be
  `u`; `truncate_signed_def` with a Z gives single values, e.g. 0); the
  elements of a `uchars` chunk are not known to be bytes (a lemma per
  read, `uchars_nth_limits`).

Wave 3 (the decoder; upstream master's messaging.cc has all of them):

* The encoders' arrays and maps longer than a process heap holds
  (b609da9f): the two checks in encode_array and encode_map ("Findings");
  upstream reaches it only with a crafted snapshot. With them, the
  task_receive_message/main_arguments/spawn_arguments handling of a
  malformed message (delivered as decoded, the externals after the error
  leaked) is unreachable; a defensive fix would drop such a message with
  `remove_disposing_finalizers()` and the message's own deallocation.
  Wave 4 draft (applied and proved in wave 5, 05159afd, together with
  the heap_dying fix it needs): in task_receive_message, after the
  allocation-failure branch, `if (decoder.malformed_input()) {
  decoder.remove_disposing_finalizers(); process->remove_first_message();
  return process->null_object(); }` (the library skips a null message);
  in main_arguments and spawn_arguments the same with
  `clear_main_arguments()` / `clear_spawn_arguments()`,
  `MessageDecoder::deallocate(arguments)` and `FAIL(INVALID_ARGUMENT)`.
* decode_external_data's inline lengths (wave 4, "Findings"): the two
  checks.
* read_cardinal (965bff66 here): upstream shifts by any amount (undefined
  behaviour for long cardinals) and drops high bits; #3362's digit count
  check plus this branch's digit check.
* TISON smis between 2^30 and 2^62 written on 64-bit fail to decode on
  32-bit (and 32-bit large integers in the 64-bit smi range decode as
  non-canonical large integers on 64-bit): fixed in wave 4 (1d19379a:
  read_cardinal_64, decode_integer, and the tests); the fix to propose.
* decode_process_message without a process: fixed in wave 4 (1d19379a:
  reads only an int-sized integer; tests/ctest/message-process-message-
  test.cc); upstream has the same code and the same TODO.

## One contract, two renderings

verified/CONTRACTS.toml writes each leaf contract (gc_grow_stack,
gc_allocate_instance, gc_allocate_double, gc_allocate_exception,
gc_call_primitive) once, clause by clause: name, Verus text, VeriFast
text, bridge, note. verified/tools/contract_check.toit (in check.sh)
compares the clauses with the Verus external_body function and the
conjuncts with the contract of the generated rendering; a change on either
side fails until the table, and the other side, follow. "MISSING" marks a
clause one side lacks and is reported. The bridges between the views,
`stack` (the machine's reloaded views against the VM state `vm(p, v, n)`
and `vm_equiv`), `heap` (the abstract heap against VeriFast's
`heap(objs, H)` at `(uword)o - 1`) and `primitive` (a primitive's
`prim_out` against the spec's `prim_call_post`), are written there once:
**the remaining reviewed assumption** of the seam, with the three
named lemmas of `ffi/` (gc_equiv_trans, stack_copy_equiv, prim_retry).
Since wave 6 both sides are checked for every leaf contract the verified
loop uses except gc_allocate_exception (gc_grow_stack, gc_allocate_instance,
gc_allocate_double, gc_call_primitive) and for the Rust primitives'
allocator (allocator_large_integer, _double, _array, _string, _byte_array). A clause whose Verus text is
empty is a VeriFast conjunct the Verus side states by a type (the views of
a `&mut Heap`). Contracts between two pieces of C++ (the allocator's,
Array::at_put, used by the decoder) are in the table too, with no Verus
function: only the VeriFast prototype (model/objects.gen.h) is compared.
contract_check also requires every bodiless lemma of a rendering and, since
wave 6, of a ghost header (`.gh`) to be a listed assumption.

## One layout table

verified/LAYOUT.toml lists the layout facts both heap models rely on, once,
per object kind (tagging, header bits, class tags, instance, task, array,
double, large integer, byte array internal/external with the RawByteTag,
string internal/external with the sentinel and half words): value on
64-bit and on 32-bit, the C++ expression, the Verus constant of
verified/core/src/layout.rs and the VeriFast macro of `model/constants.h`.
verified/tools/layout_table.toit (in check.sh) compares every Verus name
with layout.rs on both widths and generates
`model/layout.gen.constants.cc`, static assertions of every C++ expression
and every VeriFast macro against the table, compiled for x86_64 and i686 by
`constants-check.sh` (74 checks). The model's predicates use the
`LAYOUT_*` macros (word indices of the length, element, external address
and tag words, byte offsets of the half words and of the content), so a
fact changed on either side fails until the table and the other side
follow. The later Verus raw-pointer work can import the same rows (the
names are layout.rs's).

## The Rust raw-memory layer

Trusted items of crate core (verified/TRUSTED.toml, `rust/census.sh`): 93
external_body, 66 unsafe (159), of which 58 are view.rs accessor bodies (27
with integer-to-pointer casts, 6 with `>>`) and 19 the FFI wrappers of
ffi.rs (15 call C++: contracts, not bodies).

Like for like, on the same five accessors (class_id, class_tag, field,
array_length, element):

| | VeriFast (Rust front end) | Verus with vstd::raw_ptr |
|---|---|---|
| bodies | verbatim (copy-out is textual: the sidecar mechanism without a translation) | rewritten: no integer-to-pointer cast in Verus; `with_exposed_provenance` + `ptr_ref` |
| result | 3 of 5 (class_id, class_tag: `>>` unsupported) | 5 of 5, 11 obligations, < 1 s |
| annotations | 3 predicates + 2-6 ghost lines per accessor | a permission map per object + one assert per accessor; callers must thread `Tracked` permissions |
| what stays trusted | VeriFast, the copy (tool-checked), the bridge from words to the abstract heap (`heap`) | vstd's raw_ptr axioms, and an external_body that hands out fresh permissions after every GC point (the same bridge, but stated in Verus) |

Verdict: VeriFast is cheaper now (no change to verified/core, bodies
verbatim; with the shift supported about 90% of the view.rs bodies would
go through as they are). Verus with permissions leaves less trusted in the
end: the accessors' abstract meaning (`r == objs()[id].class_id`) becomes
provable inside the one proof, and the trusted part shrinks to the
permission hand-out at the FFI returns. But it changes every accessor and
its callers (a `Tracked` heap-permission invariant through the machine),
an estimated 3-4 weeks against 1 week for VeriFast on all view.rs bodies.
Recommended: VeriFast now for the bodies (automating the copy-out with the
sidecar check), Verus permissions as the long-term step when the heap
model is revised.

## What remains trusted in the C++

* VeriFast itself; Clang's AST (the translator prints what Clang parsed);
  the translator's rules (small, documented, each an error when not
  applicable).
* The bridges `stack` and `heap` (CONTRACTS.toml): that the predicates are
  what the allocator and GC establish (TRUSTED.md V2).
* The contract-only functions: `Double::value`,
  `unsigned_cast`, `Scheduler::gc`, `v2_report_allocation_failure`, the allocator (`allocate_stack`,
  `allocate_byte_array`, and for the decoder `allocate_string`,
  `allocate_array`, `allocate_instance`, `allocate_double`,
  `allocate_large_integer`, the external string and byte array over a
  message's block: CONTRACTS.toml),
  `Array::max_length_in_process`, `Process::true_object`,
  the write barrier and the error roots, the named
  assumptions (CONTRACTS.toml `[[assumption]]`: the encoder's
  `two_pass_room`, the decoder's `ipc_begin`, `ipc_room`, `ipc_pointer`,
  `ipc_external`, `ipc_length`, `ipc_end` for inter-process messages only,
  the GC's `gc_owns`, and at the boundary `gc_equiv_trans`, `stack_copy_equiv`,
  `prim_retry`), the boundary's model (Scheduler::gc, the policy table, each
  primitive's contract `Primitive_Entry`), the receive side's model (a process's mailbox and
  arguments slots, `HeapObject::clear_has_active_finalizer` giving a block
  back, the finalizer queue), the
  policy reads, HeapTagScope, the
  program roots, `fail`. Each is still compared with its source when it is
  a `@render ... trusted`; the others are plain prototypes.
* Everything not attempted (table above).

## Files

* `model/`: the object model (`objects.render`, generated `objects.gen.h/.c`),
  the constant table, `arith.gh` (shift and mask lemmas), `model.cfg`.
* `encoder/`, `decoder/`, `ffi/`, `prims/`, `utf8/`: the targets (sidecar
  and generated files); `encoder/cardinal.h`/`.c` (the cardinal's byte
  bound, proved with Z3 so that the encoder verifies with the default
  prover), `model/llong.gh` (a prelude conversion VeriFast lacks),
  `decoder/radix.h`/`.c` (read_cardinal's digit bound, Z3).
* `rust/`: the Rust accessors (VeriFast), the Verus permission trial, the
  census.
* `render.sh` (translator, both widths), `prefetch-ast.sh` (Clang dumps in
  parallel), `clang-ast.sh`, `constants-check.sh`, `mutant.sh`, `run.sh`,
  `metrics.sh`, `vf.sh`.
* `probes/`, `shim/`, `fcshim/`, `framac.sh`, `cn.sh`, `cxx-ast.sh`: the
  pilot's probes of other tools and of the C++ front end.
