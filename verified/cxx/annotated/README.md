# VeriFast for the C++ that stays C++

The C++ inside the sandbox's security boundary that is not ported to
Rust/Verus (the interpreter glue to the allocator and GC, the message
encoder and decoder, blob argument decoding, a few helpers) is verified
with VeriFast 26.10, unbounded, on 64-bit and 32-bit. The pilot
(verified/CXX-ANNOTATED-PILOT.md) proved this works on hand-written C
renderings of the C++; this directory makes the rendering mechanical, so
that it cannot drift from the sources.

Run: `run.sh` (the whole matrix, about 30 s; also part of
`verified/check.sh --tests`, which skips it with a message when VeriFast is
not installed). Tools: `install-tools.sh` (VeriFast 26.10 and its Rust
front end, under /home/flo/work/opentoit-sandbox-artifacts/annotated-cxx).
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
| release `ASSERT(c)` (`while (false && (c)) {}`) | a comment (never evaluated) |
| a reference spelled in a macro | named by its declaring class (Clang's declaration ids) |
| `@render ... trusted` | the prototype and contract only; the body is still compared with the source |
| nested class `A::B` | struct `A_B`, members `A_B_m`, constructor `A_B_ctor`; an unqualified constant of an enclosing class is `A_N` (checked as `A::N`) |
| `a = C(x)` with the implicit assignment operator (Clang's `isImplicit`) | `{ C tmp; C_ctor(&tmp, x); (a).f = tmp.f; ... }`: member-wise, what the implicit copy and move assignments do |
| `@expand-typedef T` | the typedef written as the type it stands for on the rendering's target (`uhalf_word`: unsigned int on LP64, unsigned short on ILP32) |
| a default argument (`CXXDefaultArgExpr`) | its value written out; literals only (the expression is spelled in the callee's file) |
| a call of an `@overloaded` member | named by the declared parameter types of the member it refers to (in its class or out of line), not by the argument types (which differ per target: a literal is `int` = `word` on ILP32) |
| `@render ... truncating` | an implicit word-to-int conversion is VeriFast's truncating cast (the modular conversion GCC and Clang define and C++20 standardizes); only for code that checks the round trip (the int arguments of ARGS). Also uword-to-word and uint64-to-int64 (the decoder's cardinals: `word length = read_cardinal()`, checked for the sign and against what is left), and uword-to-int (wave 4: decode_rpc_request_external's `*id = read_cardinal()`). VeriFast knows nothing of the value of such a cast by itself; `truncate_signed_id` (model/truncate.gh, wave 4, proved with Z3) gives it for a value in the target's range |
| `switch (c) { case V: ... default: ... }` | written as is: the labels (values from the constant table), a label's statement and the statements up to the next label, fall-through, `break` |
| `a op= b` whose computation type is not a's (`cursor_ += sizeof(uint32)`: an unsigned long sum for a word) | `a = (A)((C)a op b)`: the conversions C++ makes, written; `a` must be a variable or a field chain (evaluated twice) |
| `@modular-arguments C::C` | the implicit integral conversion of a constructor argument to an unsigned parameter is VeriFast's truncating cast (the modular conversion C++ defines; HeapTagScope's custom tags are negative numbers in a uword) |
| Clang's `__size_t` (the type of sizeof) | `size_t` |
| `do S while (false)` (a macro's statement wrapper: INT64_VALUE_OR_WRONG_TYPE of ARGS) | `{ S }`; an error when a break or continue of S would leave the do |
| `@render ... truncating`, an explicit `static_cast` narrowing a signed integer (`static_cast<time_t>(int64)` on a 32-bit time_t; Clang's NoOp over an IntegralCast for a typedef) | VeriFast's truncating cast (for code that checks the round trip) |
| an object of a struct spelled with its tag (`struct tm tm;`, a C header's struct) | `struct tm tm; tm_ctor(&tm);` (the constructor named by the tag) |
| a default member initializer (Clang's `CXXDefaultInitExpr`, wave 5: the decoder's `size_ = INT_MAX`, `status_ = DECODE_SUCCESS`) | `self->f = value;` written from the AST's values, never from source text (the expression is spelled in the class, another file): integer and boolean literals, null, enumerators of the constant table (checked in the class's scope); anything else is an error |
| a delegating constructor (`C(a) : C(a, K) {}`, wave 5) | the target constructor called on `self`: `C_ctor__T1_T2(self, a, K);` |
| an out-of-line constructor `C::C` (wave 5) | found although it is named like its class (the lookup took it for the class) |
| a loop whose body has no braces, with an invariant (wave 5: `for (...) deallocate();`) | the annotation anchored at the body's first token is the invariant, written before the added `{` |
| a lambda `[&]() -> R { body }` (wave 6: the closures of `v2_allocate`) | `struct F_lambdaK { T v; ... };` (F the enclosing function's C name, K its lambda's position) and `R F_lambdaK_call(struct F_lambdaK *closure)` with the body, a capture `v` being `closure->v`; where it is created, a local `struct F_lambdaK closureK;` (start of the block) gets the values (`closureK.v = v;`, just before the statement) and the lambda is `&closureK`. A capture by reference becomes a copy of the value, which is the same because the translator checks: the lambda only reads its captures (every use an lvalue-to-rvalue conversion), has no parameters, is not `mutable`, captures no `this` and no objects by copy; it is an argument of a call (it does not outlive the statement); the enclosing function never takes a captured variable's address or binds a reference to it, and the creating statement does not assign it. Annotations inside the lambda are its function's (the contract at its body's `{`) |
| `T* v = new (std::nothrow) T(args);` (the `_new` of src/top.h; wave 6) | `T *v = T_new_nothrow(); if (v != 0) { T_ctor...(v, args); }` (the allocation a function the sidecar declares); the arguments evaluated after a successful allocation (C++17's order; C++11 leaves it open), so they must not assign anything (checked); only as a local's initializer |
| `delete p` (not an array) | `T_delete(p)` for p's static class (destructor and deallocation: a contract the sidecar declares) |
| a constructor's implicit base-class initializer (no arguments) | `Base_ctor(self);` (a contract the sidecar declares: the vtable, the base's members) |
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

`run.sh`: 12 sidecars (one the translator's self-test), 246 rendered functions (22 contract-only) and 4 closures, proved
for LP64 and ILP32 (wave 7: blobs up to 2^62 - 1 and class ids up to 2^31 on LP64); 49 reverted-bug or contract mutants (one of them
ILP32 only, its check dead on LP64) and 2 drift tests; about 150 checks
(each proof 0.1-4 s, the encoder 8 s, the decoder 10-40 s and time_info
25-45 s on loaded cores). Lines: `metrics.sh` (C++ = the
rendered functions' lines; annotations among them; then the hand-written C
and annotations of the verbatim sections: trusted prototypes, predicates,
lemmas).

| Unit (sidecar) | Functions | Status | Assumptions | C++ / annot. / trusted C / annot. | Self-test |
|---|---|---|---|---|---|
| Object model (`model/objects.render`) | is_smi, is_heap_object, Smi::from/cast, HeapObject::cast/_raw/_raw_at (2)/_at/_word_at/_half_word_at/header/class_id/class_tag/has_class_tag, Instance::_offset_from/at/cast, Array::_offset_from/length/at/cast, String::_internal_length/content_on_heap/_external_length/_external_address/as_external/_as_utf8bytes/cast, String::Bytes (ctor, address, length), ByteArray::has_external_address/external_tag/_offset_from/content (2)/_external_address/as_external (2)/cast (2), ByteArray::Bytes and ConstBytes (ctor, address, length), Double/LargeInteger::cast, is_instance/array/byte_array/double/string/large_integer | verified | `Smi::value` (2 overloads) and `ByteArray::raw_length` (implementation-defined uword-to-word conversion, contract only); `Double::value`, `LargeInteger::value` (contract only); `unsigned_cast` (a template: identity on `uint8*`); the heap predicate is the allocator/GC invariant (bridge `heap`): strings and byte arrays with internal or external content, an external byte array owning its bytes only when tagged RawByteTag | 263 / 225 / 47 / 551 | drift tests; the encoder's and byte_content's mutants exercise it |
| Blob decoding (`blob/byte_content.render`) | Object::byte_content (the recursive 5-argument one, the 4-argument one, the Blob one), Blob ctor | verified: a successful result lies in the content of ONE live string or byte array (internal, or raw external: never a proxy's struct), a string for STRINGS_ONLY; recursion depth bounded by MAX_BYTE_CONTENT_DEPTH; heap read-only | the program's class-id roots (contract only) | 65 / 30 / 1 / 0 | 357d1127 (#3373): without the depth limit the recursive call fails at `depth + 1 <= 8`; without the slice's `to <= length`: the pointer leaves the blob |
| MutableBlob decoding (`blob/mutable_byte_content.render`) | Object::mutable_byte_content (5-argument, 4-argument, MutableBlob), MutableBlob ctor; model: Instance::at_put (with the heap update), HeapObject::_at_put, on_program_heap, heap growth and blob hole lemmas | verified: a successful result lies in the content of ONE live byte array (internal or raw external) outside the program heap; the heap only grows (the copy-on-write branch allocates, copies the immutable content with a legal memcpy and stores the new backing and `true`); recursion bounded | the allocator (`Process::allocate_byte_array`: a fresh byte array of the asked length outside the program heap, nothing else changed), `Process::on_program_heap` (an address range: `in_program_heap`), the true object is a heap object, the write barrier (card table outside the model), Error::from and the error roots | 76 / 54 / 4 / 2 | 357d1127 reverted here too: the recursive call; without the program-heap check: `in_program_heap == false`; without the external tag check (both decoders): `blob_ok` |
| Message encoder (`encoder/`) | encode_any (all branches), encode_array, encode_list, encode_map, encode_copy (inline, out-of-line copy with its malloc and terminator), encode_byte_array (transfer, deduplication), reserve_external, is_too_large, size, total_size, encoding_for_size, encoding_tison, the writers write_uint8/cardinal/pointer/uint32/uint64, TisonEncoder::encode and payload_size, NestingTracker ctor/dtor; the cardinal's byte bound (`cardinal.c`, Z3) | verified: memory safety (reads inside objects, blob copies inside the blob found by the proven byte_content, writes inside the buffer, the tables copied_/transferred_ written below MESSAGING_ENCODING_MAX_EXTERNALS), no overflow or lossy conversion on either width (cursor_ + external_bytes_ stays below the limit plus ENC_SLACK = 32), heap read-only | **ONE assumption: `two_pass_room`** (below); contract only: `Utils::is_valid_utf_8` (reads the bytes given), `Process::policy`, `PrimitivePolicy::restricts_messaging`, HeapTagScope, `ByteArray::has_owned_external_memory` (trusted rendering), the program's class-id roots, `bit_cast`; the malloced copies are leaked into the table (ownership not modelled) | 334 / 230 / 51 / 116 | f708ad5d: count (underflow at `to - from`), read past the backing (loop bound), map past the backing; the 32-bit size fix weakened in encode_copy and in the transfer (the size bound fails; on ILP32 the sum overflows); one reservation too many (the table bound fails); the terminator read from the content (memcpy past the blob) |
| Message decoder (`decoder/`) | TisonDecoder::decode (tison_decode's untrusted input), MessageDecoder::decode (IPC), decode_any (the switch, every tag), decode_string, decode_byte_array (both inline: copies; out of line: IPC blocks), decode_array, decode_map, decode_double, decode_large_integer, decode_integer (wave 4: canonical integers), decode_external_data and decode_rpc_request_external (wave 4: the external message handlers; the data handed out is an out-of-line block of the message or a malloced copy, `ext_data`), read_uint8/cardinal/cardinal_64/uint32/uint64/pointer, register_external, success, decoding_tison, overflown, remaining, externals_count, mark_malformed, mark_allocation_failed, NestingTracker; the digits' bound (`radix.c`, Z3); model: Array::at_put, Instance::at_put(Smi*), Smi::zero, the allocator's contracts | verified: for any input bytes (TISON) every read is inside the input (past the end the readers return 0), the cursor stays below the length + 16 on both widths, every length is checked against what is left before the copy or the allocation of that size (`length <= cap - c`, asserted), the recursion is bounded (64), a cardinal fits 64 bits and a length the word, integers are canonical (a large integer only outside the smi range: the allocator contract requires it), the externals table is written below its bound (the FATAL), the heap only grows (new objects; the new array's elements and the map's fields written), a success is a good reference and TISON consumed its input exactly; a failure leaves a well-formed heap | TISON: none beyond the model and the allocator; IPC: **two named assumptions, `ipc_room` and `ipc_external`** (below); contract only: the allocator (CONTRACTS.toml, C++-only contracts), `Utils::is_valid_utf_8`, `bit_cast`, `fail`, `Array::max_length_in_process`, `Smi::from` (now trusted: the modular shift of a negative value), `Smi::is_valid` (a template: contract only) | 360 / 322 / 35 / 149 | seventeen checks taken out, each rejected on both widths unless noted: the length checks before the inline string and byte-array copies, before the array and map allocations, the nesting limit (#3362), the fixed-size readers' bound (read_uint64; read_uint8 in the header), read_cardinal_64's size check (#3362) and digit check (wave 3), read_cardinal's word check (ILP32 only: dead on LP64), the two smi magnitude checks and decode_integer's smi range check, decode_external_data's two inline length checks (wave 4), the externals table bound |
| Receive path (`decoder/`, wave 5: the ownership of the out-of-line blocks) | the primitives task_receive_message, main_arguments, spawn_arguments (every path: finalizer to run, no message, monitor notification, system message decoded / allocation failure / malformed / allocation of the result array failed); MessageDecoder's three constructors (delegating, default member initializers), allocation_failed, malformed_input, register_external_allocations, remove_disposing_finalizers, deallocate (static, and the recursive walk); SystemMessage's destructor, free_data_and_externals, free_data_but_keep_externals, data/type/gid/pid; the decoder's out-of-line branches, read_pointer, register_external and mark_allocation_failed with ownership | verified: no leak and no double free of a message's buffer and blocks on every path. The message (`msg_whole`) owns its buffer and its blocks; read_pointer hands out block j of the message (in order), a decoder for a process lends it to the object it allocates (`finalized`: the VM finalizer frees it), keeps it when the allocation fails; on a failure remove_disposing_finalizers takes every lent block back (the message is whole again: retried or deleted), on a success every block was lent and only the buffer is freed; deallocate frees each block once and all of them. The primitive heap contract up to finalizer bits (`grows_class`: classes and lengths kept) | **the IPC assumptions, now seven narrow ones** (`ipc_begin`, `ipc_room`, `ipc_pointer`, `ipc_external`, `ipc_length`, `ipc_end`; none creates ownership) and the GC's `gc_owns` (CONTRACTS.toml); contract only: the mailbox and the arguments slots of a process (`mailbox`, `queued`, `dying`, `main_args`, `spawn_args`: a queued system message owns encoded data, its type, gid and pid are smis), `HeapObject::clear_has_active_finalizer` (gives the block back: the GC side, which 05159afd fixed), the allocator's external string and byte array, register_external_allocation, the finalizer queue, ObjectNotifier | (in the decoder's row) | receive-malformed-delivered and arguments-malformed-delivered (the 05159afd fix taken out: `st != MALFORMED` fails), receive-no-give-back, receive-give-back-bound (one finalizer bit left), arguments-drop-leak, receive-success-free-all (blocks freed under the objects), decoder-unregistered-block, deallocate-double-free, deallocate-leak |
| The Rust/C++ boundary (`ffi/interpreter_v2.render`, wave 6; stack growth since wave 1, formerly `grow/`) | toit_v2_grow_stack, Stack::v2_copy_to; toit_v2_allocate_instance and toit_v2_allocate_double with their lambdas and the two instances of `v2_allocate` (closure rules); toit_v2_try_allocate_large_integer, _double, _string, _byte_array; toit_v2_current_stack; toit_v2_primitive and v2_primitive_failed (the retry protocol); v2_process | verified against both sides of CONTRACTS.toml's gc_grow_stack, gc_allocate_instance, gc_allocate_double, gc_call_primitive and allocator_* (contract_check.toit compares every conjunct): the VM state at a GC point is `vm(p, v, n)` (stack object, header fields, bytes, heap, epoch count), the GC's guarantee `gc_equiv`; at most three collections per call (the loop bounds), so an unchanged epoch word means nothing moved (the core keeps its views on that); a primitive runs only with its table arity on its frame's slots, the retry re-reads the current stack after each GC; the results are the allocator's objects (`alloc_post`) or the primitive's completion (`prim_done`) with the status and word the core gets | **three named assumptions** (`gc_equiv_trans`, `stack_copy_equiv`: the `stack` bridge as a lemma, `prim_retry`: a call that failed for want of memory has no visible effect); contract only: v2_gc (at most one collection, `gc_equiv` or nothing), the allocator (the model's, plus Process::allocate_string(word)), allocate_stack, the policy table (`PrimitivePolicy::at`: an entry's arity is what its function reads), the primitives (function type `Primitive_Entry`: prim_out, at most PRIM_EPOCHS task switches, an out-of-memory failure leaves the stack alone), is_error/unmark_from_error, the Stack header and Task accessors, v2_validate (debug aid), the write barrier | 249 / 233 / 30 / 320 | grow-stack-unbounded, grow-stack-word-range; ffi-primitive-arity (the arity check: the primitive's precondition fails), ffi-primitive-stale-stack (the stack read before the GC: the arguments' address is not the current stack's), ffi-primitive-retries and ffi-allocate-retries (a loop bound: more collections than the epoch accounting allows); wave 7: ffi-allocate-string-bound (the allocation entry points without their V2_MAX_BLOB_LENGTH check: the allocator's bound fails), and no length precondition on the allocators any more |
| The external handlers' sender side (`sender/external_send.render`, wave 6) | ExternalSystemMessageHandler::send_ (data and encoder), reply_rpc; the encoder they use: the one-argument constructor, the destructor, take_buffer, encode_bytes_external, encode_rpc_reply_external, reserve_external, write_uint8/cardinal/pointer, size, encoding_for_size/tison; SystemMessage's constructor from an encoder (with its base class) and free_data_but_keep_externals | verified: the encoded buffer is freed once or handed over inside the message, the caller's data (a malloced block) goes to the receiver with a sent message, is freed on a failure with free_on_failure and stays the caller's otherwise, on every path (no message allocated, no receiver, quota); the write pass fits the buffer the size pass measured (exact byte counts: `card_len`, `reply_size`; no assumption), memory safety, no overflow, both widths | contract only: the scheduler's send_message (queues the message, or deletes it with free_on_failure, or gives it back), the message's allocation and deletion (only without a buffer: its references are the caller's), the process and VM accessors, strnlen; an external handler's encoder transfers nothing (neuter: `requires false`) | 166 / 145 / 64 / 256 | sender-encoder-owns-buffer (the fix reverted), sender-free-callers-data, sender-delete-with-buffer |
| Primitive `string_write_to_byte_array` (`prims/`) | the primitive with the ARGS/FAIL expansion (Blob and MutableBlob decoding by the proven byte_content / mutable_byte_content, word arguments), Blob/MutableBlob constructors and accessors | verified: the primitive heap contract in VeriFast terms (the heap only grows, objects keep class, length and external address), the copy inside the two contents (source: a string or byte array; destination: a writable byte array outside the program heap; the source range survives the destination's copy-on-write), legal memmove | none beyond the model and blob units | 21 / 59 / 7 / 22 | af4ba7ab: memcpy fails at its precondition; verifies with the two byte arrays assumed distinct |
| Primitive `time_info` (`prims/time_info.render`, wave 4) | the primitive with the ARGS expansion (int64 and bool), floor_div, floor_mod, is_leap_year, days_from_civil, weekday_from_days, utc_fields, os_localtime, equivalent_year, local_fields, Smi::is_valid32; model: Array::at_put(Smi*) | verified: for every int64 timestamp no signed overflow and no lossy conversion (coarse bounds of every step, lemmas per step so that the proof sees bounds, not division equations), every stored field a smi, the primitive heap contract; not the correctness of the dates | the C library's `localtime_r` (fields in their C11 ranges), memset of the struct, the implicit constructors (do nothing), `Process::false_object`, `fail` (UNREACHABLE) | 135 / 72 / 32 / 109 | the red-team round 4 overflow reverted (`days * SECONDS_PER_DAY` underflows); local_fields without its year check (the shift overflows); the primitive without its year check (not a smi; on ILP32 the conversion to word) |
| Primitive bitmap `byte_zap` (`prims/byte_zap.render`) | the primitive with the ARGS expansion (MutableBlob by the proven decoder; the int argument with its round-trip check, `truncating`), MutableBlob ctor and accessors | verified: the primitive heap contract, the memset covers exactly the destination's range in a writable byte array, a smi result | `Primitive::return_not_a_smi` (an error value) | 11 / 18 / 7 / 3 | one byte past the end: the memset fails |
| UTF-8 (`utf8/`) | Utils::utf_8_to_16, bytes_in_utf_8_sequence, payload_from_prefix | verified (Z3) | none | 57 / 26 / 1 / 84 | 07c24665: UB shift at payload_from_prefix; without the length check: the read past the input |
| Rust raw memory (`rust/`) | view.rs: string_len, string_byte; trial: field, array_length, element | verified (VeriFast Rust, host) | predicates over the words (bridge `heap`) | — | `i <= len` fails at the read |

Not attempted, in order of exposure, with what blocks each:

| C++ | Blocker | Estimate |
|---|---|---|
| the two-pass assumption of the encoder, proved | a ghost encoding function (fixpoint over the heap and the encoder state: cursor, externals, transfers, the early stops) shown to be what both passes compute, the write pass ahead by TISON's payload cardinal | 5-7 days |
| take_buffer, the destructor, encode_bytes_external, encode_rpc_reply_external, encode_arguments, encode_bundles | trusted callers (C or the boot), not reachable with untrusted data; the copied_ table would need its ownership modelled (the malloced copies) | 1-2 days |
| the decoder's remaining callers and the rest of the sender side: tison_decode (the Blob argument is the content of a heap object, which the allocations must not touch: the allocator's contracts over `heap_holes`), ExternalSystemMessageHandler::run (the handed-out block: decode_external_data gets it from the message, wave 5), process_send and spawn (the encoder's copies of any object graph and its transfers: take_buffer neuters byte arrays, a heap change; the scheduler's send_message_from with its policy checks; the mailbox quota accounting of Process::_append_message and remove_first_message). Wave 6 did the external handlers' sender side (`sender/`): its encoder model (`ext_encoder`, copies owned in the table) is the start for the general encoder | the encoder unit's tables with ownership of the copies (enc_tables) and of the transferred bytes; the holes form of the allocator's contracts. Wave 7: reviewed (the mailbox quota accounting, ExternalSystemMessageHandler::run, process_send's failure paths with the allocation-failure test): no bug; not proved | 3-4 days |
| the IPC assumptions (`ipc_room`, `ipc_external`), proved | the encoder's ghost encoding (the two-pass assumption's) as the decoder's input: decoding it reads what the encoding wrote | with the two-pass proof, 3-4 days more |
| ProgramOrientedEncoder / EncodeVisitor (encode_error, encoder.cc) | the object encoder's buffer (bounded, no two-pass), the program model (class names, method tables) for the trace | 4-5 days |
| toit_v2_allocate_exception, toit_v2_try_allocate_array (Verus contracts gc_allocate_exception, allocator_array), toit_v2_allocate_array (the checked loop only) | a word from Rust stored as an object reference (`reinterpret_cast<Object*>(filler)`, the exception's value): in VeriFast's C model an integer-to-pointer cast has no provenance, the model's references are pointers with provenance; either an address-based `good` in the model or `-assume_no_provenance` for these functions alone (the exposed-provenance semantics the Rust side has, `IsExposed`); the exception also needs encode_error. Wave 7: VeriFast 26.10 documents `-assume_no_provenance` as unsound even at -O0, so the route is a translator rule rendering `reinterpret_cast<Object*>(w)` as a contract-only conversion (`requires` the word encodes a member of objs or a smi, `ensures good(objs, result) && (uword)result == w`: the exposed-provenance step, one named assumption) | 1-2 days (the provenance), 4-5 days with encode_error |
| the fields of a new instance (null), a double's bits, a byte array's zeros (Verus `new_instance`, `Body::Double(bits)`, `Body::Bytes(0...)`) | outside the VeriFast heap model (a double's and a large integer's bodies are their headers; blob contents unconstrained): the allocator's contract cannot say them. Why it is harmless (wave 7): the Verus side's payload clauses are claims about the allocator (src/heap.cc writes the null object into every field before the header, `_initialize(value)` the double, `_initialize_no_write_barrier(length, filler)` the elements, the byte arrays are cleared), which is GC-class trusted code like the `heap` bridge itself; no rendered C++ reads a payload it did not write, so no VeriFast proof depends on them. Stating them makes the bridge smaller, not the proofs stronger | 1 day (payload words in the model) |
| Utils::is_valid_utf_8 (contract only in the encoder and the decoder; reads the bytes given) | per-target code (`#ifdef BUILD_64`: a 64-bit state machine over a 2 KB table, else two tables and an int32 state): constants with per-target types in the one constant table; the tables are mutable globals (VeriFast global array chunks); the word-at-a-time load from a byte range (`*reinterpret_cast<const uword*>`: uchars to an integer chunk) and the pointer alignment (`is_aligned`, a template on a pointer). Wave 7: exhaustively compared with a strict validator on both widths (every sequence of up to 3 bytes, every 4-byte one from 0xf0-0xf7): no difference | 1 day |
| the other C++ primitives of the untrusted set (35 core + bitmap blit + timers/events; docs/sandbox-primitive-audit.md) | blob-only ones (crc, string_to_utf_16, utf_16_to_string, byte_array_convert_to_string): ARGS is proven, an allocation contract per result kind (strings, byte arrays); task/message/timer ones: the scheduler calls get stated contracts | 0.5-1 day each |

### The primitives of the untrusted set

The untrusted policy allows 141 core primitives, `bitmap.byte_zap`,
`bitmap.blit` and the 7 timer and events primitives
(docs/sandbox-primitive-audit.md). 106 core primitives run as proven Rust
ports for untrusted programs (verified/core/src/prims: **Rust-verified**).
The other 44 are C++. Their status here: **VeriFast-verified** (the
primitive's body, with its ARGS expansion, proved), **partly** (the C++
it calls on untrusted data proved, the primitive's own glue contract
only), **contract-only** (only the primitive contract of TRUSTED.md
section 8, which the Rust proof assumes; reviewed and fuzzed by the
audit).

| Primitive (C++) | Status | What is proved |
|---|---|---|
| `task_receive_message` | VeriFast-verified (wave 5) | every path: the message's ownership (no leak, no double free), the heap contract up to finalizer bits |
| `main_arguments`, `spawn_arguments` | VeriFast-verified (wave 5) | as task_receive_message |
| `time_info` | VeriFast-verified (wave 4) | no overflow or lossy conversion for any int64, fields smis |
| `bitmap.byte_zap` | VeriFast-verified | the memset inside one writable byte array |
| `process_send` | partly | the encoder (memory safety, size limits; `two_pass_room`); the scheduler's delivery contract only |
| `byte_array_convert_to_string`, `byte_array_is_valid_string_content` | partly | the Blob decoding (byte_content); `Utils::is_valid_utf_8` contract only |
| `string_to_utf_16` | partly | `Utils::utf_8_to_16` and the Blob decoding |
| `crc` | partly | the Blob decoding |
| `task_new`, `task_transfer`, `task_has_messages`, `add_finalizer`, `remove_finalizer`, `spawn_method`, `encode_error` | contract-only | |
| `time`, `seconds_since_epoch_local`, `get_real_time_clock`, `random`, `gc_count`, `process_current_id`, `process_system_id`, `word_size`, `platform`, `architecture` | contract-only | |
| `int_parse`, `float_parse`, `float_to_string`, `float_round`, `int64_to_string`, `uint64_to_string`, `printf_style_int64_to_string`, `smi_to_string_base_10`, `utf_16_to_string` | contract-only | |
| `bitmap.blit` | contract-only | |
| `timer.init`, `timer.create`, `timer.arm`, `timer.delete`, `events.read_state`, `events.register_monitor_notifier`, `events.unregister_monitor_notifier` | contract-only | |

Totals: 106 Rust-verified, 5 VeriFast-verified, 5 partly, 34
contract-only (of 150). The encoding module (`tison_decode`: the decoder
verified, its glue not rendered) is denied to untrusted programs.

Since wave 7 every one of the 150 also has its retry classification
(CONTRACTS.toml `[prim_retry]`, "The retry obligation"), the 106
Rust-verified ones for their C++ primitive, which runs when the port
declines: that C++ is reachable by untrusted programs too (the
concat_strings overflow of "Findings" was in it). Their C++ bodies are
otherwise contract-only.

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

### The retry obligation (wave 7)

The core's contract for a call of a C++ primitive (gc_call_primitive)
takes the whole C++ call as ONE step, including the calls after a GC when
the primitive failed for want of memory (MALLOC_FAILED, ALLOCATION_FAILED,
CROSS_PROCESS_GC; v2_primitive_failed, at most four calls). That is a
completion of the original step only if a failed call has no visible
effect: no existing object written, no message sent or consumed, no
resource, timer, notifier or finalizer registered, no malloced memory kept
or freed. New objects that nothing references are garbage (the GC before
the retry removes them), and so is a VM finalizer node whose object gave
its memory back (a failed decode). The ffi proof states this as the
assumption `prim_retry`; this wave discharges it per primitive.

Reach: every C++ primitive of the untrusted policy, 150. The 35 core, 2
bitmap and 7 timer and events primitives that stay C++ are called
directly; the 106 core primitives ported to Rust call their C++ primitive
when the port declines (NeedsGc: an allocation did not fit; NotPorted:
proxies, copy-on-write byte arrays not yet copied, sums above
MAX_BLOB_LENGTH, ...). The Rust side cannot decline after an effect: Verus
proves `NeedsGc`/`NotPorted` leave the heap equal (`prims::prim_post`) and
the machine unchanged (`rarrays::rust_primitive_r`, `res is None ==>
*final(m) == *old(m)`).

Classification (CONTRACTS.toml `[prim_retry]`, checked by
contract_check.toit: the untrusted set is read from src/primitive_policy.cc
and src/primitive.h; a primitive missing, classified twice or not in the
set fails the gate, so a new primitive in the untrusted set must be
classified):

| Class | Count | Evidence |
|---|---|---|
| (a) cannot fail for want of memory | 62 | the primitive's body (or its macro) has no allocation, allocating argument kind (MutableBlob, cstring) or out-of-memory error: checked by contract_check.toit (a tripwire for helpers that allocate; reviewed) |
| (b) fails for want of memory only before any visible effect | 88 | 86 by tests/ctest/prim-retry-test.cc (below); 2 reviewed (task_new: a format-1 path needs an interpreter; encode_error: needs a scheduler thread), the arguments in the table |
| (c) violates it | 0 | |

tests/ctest/prim-retry-test.cc makes every allocation of a call fail in
turn, the k-th and all after it, for every k up to the number a successful
call makes (the linker wraps malloc, calloc, realloc, free and
TwoSpaceHeap::allocate, through which every heap object but instances is
allocated; libstdc++ is static, so `new` is wrapped too). For each failure
reported as out-of-memory it compares the arguments (deeply: fields,
elements, bytes, finalizer bits, string hash codes), the process
(mailbox, main and spawn arguments, timers, resource groups, object
notifiers, external memory, finalizers to run) and the malloc balance with
the state before the call, then the retry with a call that never failed.
task_has_messages fails for want of memory by the process's limit, not an
allocation: the test sets the limit. 86 primitives, host and host32; a
mutant that drops timer.create's `remove_timer()` on a failed malloc fails
it (the timer quota counter leaks). Limits: instance allocation
(ObjectHeap::allocate_instance, inline allocate_new_space) is not wrapped
(the receive path's maps; their allocation failure is in the wave-5
VeriFast proof); the process is format 1, so task_new's format-2 path and
encode_error are reviewed.

Not proved with VeriFast for the rendered primitives (string_write,
byte_zap, time_info, the receive primitives): their contracts say the heap
only grows, not "unchanged on an out-of-memory error". Stating it needs
the error words' identity in the model (FAIL's index form against
Error::from's pointer form, and that the roots are distinct); the test
covers their failure points (the copy-on-write copy, the result array, the
decoder's allocations). Estimate 1 day.

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
  length, below MAX_BLOB.
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

Wave 7 (the retry obligation, the C++ behind the Rust primitives' declines,
the model gaps):

* **concat_strings summed the lengths of its parts without a bound: on
  32-bit an untrusted program overflows the VM's heap** (FIXED here,
  src/primitive_core.cc; ccde26f7). The primitive adds the lengths of the
  strings of an array in a `word`; 257 references to one 16 MB string sum
  to 2^32 + 16 MB, which wraps to 16 MB: a 16 MB string is allocated and
  the copy of all parts writes 4 GB past it (segfault on host32, heap
  corruption otherwise). Reachable by untrusted programs although the
  primitive is ported to Rust: the port declines sums above its
  MAX_BLOB_LENGTH (2^30 on 32-bit) and leaves them to the C++ primitive.
  On an ESP32 (128 KB untrusted heap) the parts can be a large string
  literal of the program (flash, not heap) and an array of a few thousand
  references to it. string_add (two parts) had the same unchecked sum
  (reachable only by trusted programs with a 1 GB string). Found by the
  retry audit, which followed every Rust decline to its C++ primitive.
  Fix: both check each part against what is left of the core's bound
  (MAX_CONCATENATION_LENGTH, 2^30 or 2^62) and fail with OUT_OF_RANGE.
  Reproducer and regression test: tests/concat-strings-overflow-test.toit
  (host32: segfaults without the fix, also `toit.run --untrusted`).
  Upstream master: the same concat_strings (sum unchecked), reachable by
  any program on a 32-bit VM.
* **The retry obligation holds for every C++ primitive of the untrusted
  set** (no violation): 62 cannot fail for want of memory, 88 fail only
  before any visible effect ("The retry obligation"). Close calls, all
  correct: timer.create takes the timer quota before its malloc and gives
  it back when the malloc fails; process_send neuters transferred byte
  arrays only after the message is allocated; register_monitor_notifier
  deletes the notifier when its message cannot be allocated; a failed
  decode leaves VM finalizer nodes for the GC that precedes the retry.
* **The core's allocation entry points let INTPTR_MAX through to
  Process::allocate_string's `length + 1`** (latent, wave 6; FIXED here,
  src/interpreter_v2.cc). toit_v2_try_allocate_string and _byte_array now
  return 0 above V2_MAX_BLOB_LENGTH (2^62 - 1 / 2^30 - 1, the heap models'
  bound): the core's port then declines and the C++ primitive allocates.
  With it the VeriFast contracts of allocator_string/_byte_array have no
  length precondition, as the Verus ones (the "MISSING" clauses are gone).
  Mutant ffi-allocate-string-bound. Branch-only code (not upstream).
* **Two model gaps closed by widening the model, not the C++**: blob
  lengths (MAX_BLOB) are now per width as the Verus heap model's (2^62 - 1
  on LP64, was 2^30 - 1), and class ids below 2^31 on LP64 and every smi
  header on ILP32 (was 1024; CLASS_ID_BIT_SIZE = 10 is declared but unused,
  the C++ takes any class id). Every proof and mutant verifies unchanged
  with both, except the encoder at one place: `problematic_class_id_` is an
  `int` (a class id of 2^31 would truncate; it needs a 4 GB class table),
  hence the 2^31 cap on LP64.
* No bug in the mailbox quota accounting (Process::_append_message and
  remove_first_message under the process mutex, the scheduler's lock
  around both; sizes and the restricted flag are set before the message is
  queued and never change; every queued system message is counted and
  uncounted once), nor in ExternalSystemMessageHandler::run (a failed
  decode deletes the whole message; an allocation failure keeps it for
  on_failed_allocation's retry).
* Latent, not changed (not a unit proved here): blob_index_of's SSE2 loop
  (x86_64 hosts only) counts with an `int` (`for (int i = from -
  last_bits; i < to; i += 16)`, `int answer`): a search past 2^31 bytes
  overflows the index (undefined behaviour; in practice a read before the
  blob). Byte arrays made by Toit code are below 2^31 bytes
  (byte_array_new takes an `int`) and a 2 GB string failed to allocate on
  the host (the process's memory limit), so not reproduced
  (repro/blob-index-of-large.toit). For upstream: `word i`, `word answer`
  (the same code there).
* Utils::is_valid_utf_8 agrees with a strict RFC 3629 validator on every
  sequence of 1 to 3 bytes and every 4-byte sequence starting 0xf0-0xf7, on
  both widths (the 64-bit and 32-bit state machines differ; 19.1 M
  sequences each; /home/flo/work/opentoit-sandbox-artifacts/annotated-cxx/
  repro/utf8-validator-exhaustive.toit).

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
  failure, wave 5); not checked for the others. (Wave 7: checked for all 150, "The retry obligation".)
* **The epoch the core relies on is sound only because the retry loops are
  bounded** (verified; no bug). The core keeps its stack view when the
  epoch word is unchanged (TRUSTED.md, Epoch). The word wraps; the proof
  shows at most three collections and four primitive calls per C++ call,
  so an unchanged word is an unchanged count. The mutants ffi-*-retries
  take a bound out: the proof fails.
* Latent, not reachable: toit_v2_try_allocate_string lets lengths up to
  INTPTR_MAX through (`static_cast<word>(length) < 0`), and
  Process::allocate_string(word) computes `length + 1` for an external
  string: signed overflow at INTPTR_MAX. The Rust callers pass at most
  twice the largest blob (prims/blob.rs string_add, concat), far below.
  Not changed then; fixed in wave 7 (V2_MAX_BLOB_LENGTH).
* The VeriFast model is narrower than the C++ in three places, listed as
  gaps in CONTRACTS.toml: class ids below 1024 (`header_ok`), blobs below
  2^30 on both widths (the allocators' length precondition; TRUSTED.md
  allows 2^62 on 64-bit), and no payload words (a new instance's null
  fields, a double's bits, a byte array's zeros are the allocator's, not
  stated). Words from Rust stored as object references
  (try_allocate_array's filler, allocate_exception's value) have no
  provenance in VeriFast's C model: those two are not rendered.
  (Wave 7: the class-id and blob bounds closed, "Findings, Wave 7"; the
  payload words and the provenance stay, "Not attempted".)
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
  src/encoder.cc EncodeVisitor::visit_byte_array; reported by the
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
  fix). Upstream master: the same visitor. Not in the proved code
  (encode_error is "Not attempted"; the message encoder's own byte arrays
  go through the proved byte_content, which refuses proxies).
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

* Wave 7: `concat_strings` (src/primitive_core.cc, upstream
  primitive_core.cc:1767) must bound the sum of its parts' lengths (on a
  32-bit VM the sum wraps and the copy overflows the result: "Findings");
  the same for string_add's helper (`len_a + len_b`). The fix of ccde26f7
  (OUT_OF_RANGE above 2^30 / 2^62) and tests/concat-strings-overflow-test.toit
  go with it.

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
  `u_llong_integer`-to-`chars` auto lemma (encoder/llong.gh adds it);
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
allocator (allocator_large_integer, _double, _string, _byte_array;
allocator_array has its Verus side only). A clause whose Verus text is
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
* The contract-only functions: `Smi::value` and `ByteArray::raw_length`
  (implementation-defined conversions), `Double::value`,
  `LargeInteger::value`, `unsigned_cast`, the Stack header and Task
  accessors, `v2_gc`, the allocator (`allocate_stack`,
  `allocate_byte_array`, and for the decoder `allocate_string`,
  `allocate_array`, `allocate_instance`, `allocate_double`,
  `allocate_large_integer`, the external string and byte array over a
  message's block: CONTRACTS.toml), `Smi::from` (the modular shift),
  `Array::max_length_in_process`, `Process::on_program_heap`/`true_object`,
  the write barrier, `Error::from` and the error roots, the named
  assumptions (CONTRACTS.toml `[[assumption]]`: the encoder's
  `two_pass_room`, the decoder's `ipc_begin`, `ipc_room`, `ipc_pointer`,
  `ipc_external`, `ipc_length`, `ipc_end` for inter-process messages only,
  the GC's `gc_owns`, and at the boundary `gc_equiv_trans`, `stack_copy_equiv`,
  `prim_retry`), the boundary's model (v2_gc, the policy table, each
  primitive's contract `Primitive_Entry`), the receive side's model (a process's mailbox and
  arguments slots, `HeapObject::clear_has_active_finalizer` giving a block
  back, the finalizer queue), `Utils::is_valid_utf_8`, the
  policy reads, HeapTagScope, `ByteArray::has_owned_external_memory`, the
  program roots, `fail`. Each is still compared with its source when it is
  a `@render ... trusted`; the others are plain prototypes.
* Everything not attempted (table above).

## Files

* `model/`: the object model (`objects.render`, generated `objects.gen.h/.c`),
  the constant table, `arith.gh` (shift and mask lemmas), `model.cfg`.
* `encoder/`, `decoder/`, `ffi/`, `prims/`, `utf8/`: the targets (sidecar
  and generated files); `encoder/cardinal.h`/`.c` (the cardinal's byte
  bound, proved with Z3 so that the encoder verifies with the default
  prover), `encoder/llong.gh` (a prelude conversion VeriFast lacks),
  `decoder/radix.h`/`.c` (read_cardinal's digit bound, Z3).
* `rust/`: the Rust accessors (VeriFast), the Verus permission trial, the
  census.
* `render.sh` (translator, both widths), `prefetch-ast.sh` (Clang dumps in
  parallel), `clang-ast.sh`, `constants-check.sh`, `mutant.sh`, `run.sh`,
  `metrics.sh`, `vf.sh`.
* `probes/`, `shim/`, `fcshim/`, `framac.sh`, `cn.sh`, `cxx-ast.sh`: the
  pilot's probes of other tools and of the C++ front end.
