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
| `@render ... truncating` | an implicit word-to-int conversion is VeriFast's truncating cast (the modular conversion GCC and Clang define and C++20 standardizes); only for code that checks the round trip (the int arguments of ARGS) |
| `a op= b` whose computation type is not a's (`cursor_ += sizeof(uint32)`: an unsigned long sum for a word) | `a = (A)((C)a op b)`: the conversions C++ makes, written; `a` must be a variable or a field chain (evaluated twice) |
| `@modular-arguments C::C` | the implicit integral conversion of a constructor argument to an unsigned parameter is VeriFast's truncating cast (the modular conversion C++ defines; HeapTagScope's custom tags are negative numbers in a uword) |
| Clang's `__size_t` (the type of sizeof) | `size_t` |

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

`run.sh`: 9 sidecars (one the translator's self-test), 140 rendered functions (18 contract-only), proved
for LP64 and ILP32; 20 reverted-bug or contract mutants and 2 drift tests;
87 checks, about 350 CPU-seconds (30 s wall on 16 idle cores, 80 s on the
loaded machine; each proof 0.1-4 s, the encoder 10 s). Lines: `metrics.sh` (C++ = the
rendered functions' lines; annotations among them; then the hand-written C
and annotations of the verbatim sections: trusted prototypes, predicates,
lemmas).

| Unit (sidecar) | Functions | Status | Assumptions | C++ / annot. / trusted C / annot. | Self-test |
|---|---|---|---|---|---|
| Object model (`model/objects.render`) | is_smi, is_heap_object, Smi::from/cast, HeapObject::cast/_raw/_raw_at (2)/_at/_word_at/_half_word_at/header/class_id/class_tag/has_class_tag, Instance::_offset_from/at/cast, Array::_offset_from/length/at/cast, String::_internal_length/content_on_heap/_external_length/_external_address/as_external/_as_utf8bytes/cast, String::Bytes (ctor, address, length), ByteArray::has_external_address/external_tag/_offset_from/content (2)/_external_address/as_external (2)/cast (2), ByteArray::Bytes and ConstBytes (ctor, address, length), Double/LargeInteger::cast, is_instance/array/byte_array/double/string/large_integer | verified | `Smi::value` (2 overloads) and `ByteArray::raw_length` (implementation-defined uword-to-word conversion, contract only); `Double::value`, `LargeInteger::value` (contract only); `unsigned_cast` (a template: identity on `uint8*`); the heap predicate is the allocator/GC invariant (bridge `heap`): strings and byte arrays with internal or external content, an external byte array owning its bytes only when tagged RawByteTag | 263 / 225 / 47 / 551 | drift tests; the encoder's and byte_content's mutants exercise it |
| Blob decoding (`blob/byte_content.render`) | Object::byte_content (the recursive 5-argument one, the 4-argument one, the Blob one), Blob ctor | verified: a successful result lies in the content of ONE live string or byte array (internal, or raw external: never a proxy's struct), a string for STRINGS_ONLY; recursion depth bounded by MAX_BYTE_CONTENT_DEPTH; heap read-only | the program's class-id roots (contract only) | 65 / 30 / 1 / 0 | 357d1127 (#3373): without the depth limit the recursive call fails at `depth + 1 <= 8`; without the slice's `to <= length`: the pointer leaves the blob |
| MutableBlob decoding (`blob/mutable_byte_content.render`) | Object::mutable_byte_content (5-argument, 4-argument, MutableBlob), MutableBlob ctor; model: Instance::at_put (with the heap update), HeapObject::_at_put, on_program_heap, heap growth and blob hole lemmas | verified: a successful result lies in the content of ONE live byte array (internal or raw external) outside the program heap; the heap only grows (the copy-on-write branch allocates, copies the immutable content with a legal memcpy and stores the new backing and `true`); recursion bounded | the allocator (`Process::allocate_byte_array`: a fresh byte array of the asked length outside the program heap, nothing else changed), `Process::on_program_heap` (an address range: `in_program_heap`), the true object is a heap object, the write barrier (card table outside the model), Error::from and the error roots | 76 / 54 / 4 / 2 | 357d1127 reverted here too: the recursive call; without the program-heap check: `in_program_heap == false`; without the external tag check (both decoders): `blob_ok` |
| Message encoder (`encoder/`) | encode_any (all branches), encode_array, encode_list, encode_map, encode_copy (inline, out-of-line copy with its malloc and terminator), encode_byte_array (transfer, deduplication), reserve_external, is_too_large, size, total_size, encoding_for_size, encoding_tison, the writers write_uint8/cardinal/pointer/uint32/uint64, TisonEncoder::encode and payload_size, NestingTracker ctor/dtor; the cardinal's byte bound (`cardinal.c`, Z3) | verified: memory safety (reads inside objects, blob copies inside the blob found by the proven byte_content, writes inside the buffer, the tables copied_/transferred_ written below MESSAGING_ENCODING_MAX_EXTERNALS), no overflow or lossy conversion on either width (cursor_ + external_bytes_ stays below the limit plus ENC_SLACK = 32), heap read-only | **ONE assumption: `two_pass_room`** (below); contract only: `Utils::is_valid_utf_8` (reads the bytes given), `Process::policy`, `PrimitivePolicy::restricts_messaging`, HeapTagScope, `ByteArray::has_owned_external_memory` (trusted rendering), the program's class-id roots, `bit_cast`; the malloced copies are leaked into the table (ownership not modelled) | 334 / 230 / 51 / 116 | f708ad5d: count (underflow at `to - from`), read past the backing (loop bound), map past the backing; the 32-bit size fix weakened in encode_copy and in the transfer (the size bound fails; on ILP32 the sum overflows); one reservation too many (the table bound fails); the terminator read from the content (memcpy past the blob) |
| Stack growth (`grow/`) | toit_v2_grow_stack, v2_process, Stack::v2_copy_to | verified against gc_grow_stack (no precondition on `needed`: the C++ checks it) | v2_gc (preserves the abstraction), allocate_stack, Stack header accessors, Task::stack/set_stack, max_length (contract only) | 93 / 72 / 17 / 86 | the bound check taken out: fails at the cast; with the cast exact: at the sum |
| Primitive `string_write_to_byte_array` (`prims/`) | the primitive with the ARGS/FAIL expansion (Blob and MutableBlob decoding by the proven byte_content / mutable_byte_content, word arguments), Blob/MutableBlob constructors and accessors | verified: the primitive heap contract in VeriFast terms (the heap only grows, objects keep class, length and external address), the copy inside the two contents (source: a string or byte array; destination: a writable byte array outside the program heap; the source range survives the destination's copy-on-write), legal memmove | none beyond the model and blob units | 21 / 59 / 7 / 22 | af4ba7ab: memcpy fails at its precondition; verifies with the two byte arrays assumed distinct |
| Primitive bitmap `byte_zap` (`prims/byte_zap.render`) | the primitive with the ARGS expansion (MutableBlob by the proven decoder; the int argument with its round-trip check, `truncating`), MutableBlob ctor and accessors | verified: the primitive heap contract, the memset covers exactly the destination's range in a writable byte array, a smi result | `Primitive::return_not_a_smi` (an error value) | 11 / 18 / 7 / 3 | one byte past the end: the memset fails |
| UTF-8 (`utf8/`) | Utils::utf_8_to_16, bytes_in_utf_8_sequence, payload_from_prefix | verified (Z3) | none | 57 / 26 / 1 / 84 | 07c24665: UB shift at payload_from_prefix; without the length check: the read past the input |
| Rust raw memory (`rust/`) | view.rs: string_len, string_byte; trial: field, array_length, element | verified (VeriFast Rust, host) | predicates over the words (bridge `heap`) | — | `i <= len` fails at the read |

Not attempted, in order of exposure, with what blocks each:

| C++ | Blocker | Estimate |
|---|---|---|
| the two-pass assumption of the encoder, proved | a ghost encoding function (fixpoint over the heap and the encoder state: cursor, externals, transfers, the early stops) shown to be what both passes compute, the write pass ahead by TISON's payload cardinal | 5-7 days |
| take_buffer, the destructor, encode_bytes_external, encode_rpc_reply_external, encode_arguments, encode_bundles | trusted callers (C or the boot), not reachable with untrusted data; the copied_ table would need its ownership modelled (the malloced copies) | 1-2 days |
| MessageDecoder (messaging.cc) | heap extension while decoding (the allocator's contract exists now: `Process::allocate_byte_array`; strings, arrays, doubles, large integers, lists and maps to add), every read against `size_`, the external table | 6-8 days |
| ProgramOrientedEncoder / EncodeVisitor (encode_error, encoder.cc) | the object encoder's buffer (bounded, no two-pass), the program model (class names, method tables) for the trace | 4-5 days |
| toit_v2_allocate_instance/double/array/exception (interpreter_v2.cc), the epoch | `v2_allocate` takes a lambda: a rendering rule for closures (a struct of the captures and a function); the clauses are in CONTRACTS.toml, Verus side checked | 2-3 days |
| toit_v2_call_primitive, toit_v2_lookup_primitive (after core/trusted-integration's leaner call) | non-constant globals (`Flags::primitives`), the policy table, the retry loop around the GC | 2-3 days |
| the other C++ primitives of the untrusted set (35 core + bitmap blit + timers/events; docs/sandbox-primitive-audit.md) | blob-only ones (crc, string_to_utf_16, utf_16_to_string, byte_array_convert_to_string): ARGS is proven, an allocation contract per result kind (strings, byte arrays); task/message/timer ones: the scheduler calls get stated contracts | 0.5-1 day each |

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

Past bugs of the upstream series #3361-#3382 in the covered code are
mutants (byte_content depth 357d1127, the encoder bounds f708ad5d, the
UTF-8 bounds 07c24665, the string_write memmove af4ba7ab); those in the
units not attempted (decoder nesting/cardinal bounds of #3362, encoder
recursion and buffer overflow of #3373/#3374, encoding size truncation of
#3378, malformed system messages of #3381) become mutants with them.


## Findings

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

## One contract, two renderings

verified/CONTRACTS.toml writes each leaf contract (gc_grow_stack,
gc_allocate_instance, gc_allocate_double, gc_allocate_exception,
gc_call_primitive) once, clause by clause: name, Verus text, VeriFast
text, bridge, note. verified/tools/contract_check.toit (in check.sh)
compares the clauses with the Verus external_body function and the
conjuncts with the contract of the generated rendering; a change on either
side fails until the table, and the other side, follow. "MISSING" marks a
clause one side lacks and is reported. The bridges between the views,
`stack` (the machine's reloaded views against the Stack words and
`same_abstraction`) and `heap` (the abstract heap against VeriFast's
`heap(objs, H)` at `(uword)o - 1`), are written there once: **the
remaining reviewed assumption** of the seam. The allocation and primitive
contracts have their Verus side checked; their C++ is not rendered yet.

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
  `allocate_byte_array`), `Process::on_program_heap`/`true_object`, the
  write barrier, `Error::from` and the error roots, the encoder's
  `two_pass_room` (the one named assumption, CONTRACTS.toml),
  `Utils::is_valid_utf_8`, the policy reads, HeapTagScope,
  `ByteArray::has_owned_external_memory`, the program roots. Each
  is still compared with its source when it is a `@render ... trusted`;
  the others are plain prototypes.
* Everything not attempted (table above).

## Files

* `model/`: the object model (`objects.render`, generated `objects.gen.h/.c`),
  the constant table, `arith.gh` (shift and mask lemmas), `model.cfg`.
* `encoder/`, `grow/`, `prims/`, `utf8/`: the targets (sidecar and
  generated files); `encoder/cardinal.h`/`.c` (the cardinal's byte bound,
  proved with Z3 so that the encoder verifies with the default prover),
  `encoder/llong.gh` (a prelude conversion VeriFast lacks).
* `rust/`: the Rust accessors (VeriFast), the Verus permission trial, the
  census.
* `render.sh` (translator, both widths), `prefetch-ast.sh` (Clang dumps in
  parallel), `clang-ast.sh`, `constants-check.sh`, `mutant.sh`, `run.sh`,
  `metrics.sh`, `vf.sh`.
* `probes/`, `shim/`, `fcshim/`, `framac.sh`, `cn.sh`, `cxx-ast.sh`: the
  pilot's probes of other tools and of the C++ front end.
