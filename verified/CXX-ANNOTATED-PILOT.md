# Pilot 2: annotation-based verification of the residual C++

Question (2026-11-11): the first pilot (CXX-VERIFICATION-PILOT.md) showed
that automatic model checkers cannot verify the C++ inside the security
boundary: every VM object access goes through a tagged pointer turned into
an integer and back, and the tools resolved each access against every
object of the model. Can an annotation-based deductive verifier, where the
programmer states once what a VM object is (heap predicates, contracts,
loop invariants), prove the same code unbounded and quickly?

Done hands-on on branch `experiment/annotated-cxx` (from
`sandbox-integration`). Annotated renderings, harnesses and scripts:
`verified/cxx/annotated/`. Tools and logs:
`/home/flo/work/opentoit-sandbox-artifacts/annotated-cxx/`. No VM or proof
file changed.

## Summary

* **VeriFast 26.10 does what the model checkers could not.** One object
  model (predicates for the header, instances, arrays, byte arrays and the
  heap as a set of objects whose reference fields are smis or members;
  contracts for the accessors, proved against their bodies) and four
  targets on top of it, all proved **unbounded, on 64-bit and 32-bit, in
  0.2-1.6 s each**; the whole matrix (28 runs, every mutant included) takes
  23 s. The reverted bugs fail where they should: f708ad5d at the negative
  element count and then at `Array_at(object, i)` with `i >= length`;
  af4ba7ab at the memcpy for overlapping ranges (with non-overlap assumed,
  the same memcpy verifies); 07c24665 at the read `input[i + j]` past the
  end. `toit_v2_grow_stack` meets the Verus `gc_grow_stack` contract only
  with a bound on `needed`: without one VeriFast fails at the
  `static_cast<word>(needed)`, with only the cast made exact it fails at
  `(length - free) + needed`.
* **The tagged pointer, the crux, is cheap in VeriFast's C mode.** An
  integer-to-pointer cast gives a pointer with the null provenance, so a
  chunk owned at the original pointer does not match (sound, PNVI-style).
  Stating the object's memory at the address the code computes,
  `(uword *)((uword)o - 1)`, makes every access match by address, with no
  case splits over objects. That is an assumption that the heap is exposed
  memory addressed by integer, which is what the allocator does; it
  belongs with TRUSTED.md V2.
* **Not on the real C++.** VeriFast's C++ front end rejects every
  integer-to-pointer cast (`reinterpret_cast` and C casts: "Expression of
  kind 'CXXReinterpretCastExpr' is not supported"), and the real headers
  pull in the standard library. So the proofs are on a C rendering of
  objects.h, messaging.cc, interpreter_v2.cc, primitive_core.cc and
  utils.cc: function by function, the same expressions, member calls
  spelled as functions, the implicit conversions written out. The rendering
  is not checked against the C++ by a tool here.
* **Frama-C with frama-clang** (built here against the host's LLVM 21)
  accepts C++ with `reinterpret_cast` and a tagged `this` (a member
  accessor proved 14/14), but not the real headers: after three stand-ins
  for its incomplete libc++, it crashes on `static const uword
  CLASS_ID_MASK = -1` (F1), then rejects a constructor initializer (F2). WP
  has no separation logic: the encoder's object-graph recursion would need
  a hand-written global heap invariant and frame reasoning.
* **CN** (installed this time, from rems-project/cn) rejects the tagged
  read on both shapes ("Missing resource for reading ...
  RW<intptr_t>(intToPtr)"). Its documented route is
  `copy_alloc_id(addr, p)` in the code, i.e. changing `_raw_at`.
* **VeriFast's Rust front end** verifies `Heap::string_len` and
  `Heap::string_byte` from view.rs with the same style of predicate, and
  rejects `i <= len`. So one tool can cover the raw-memory layer on both
  sides of the FFI.
* **VCC** is archived on GitHub (last commit 2021-01-20). VST is skipped as
  planned.

Recommendation, in short: **adopt VeriFast for the C++ that stays C++**:
the glue of interpreter_v2.cc, the message encoder and decoder, the blob
argument decoding, and the C++ helpers until they are ported. Use it on C
renderings with a mechanical correspondence check (next step). Do not
annotate primitives that are about to be ported to Rust/Verus: a port
costs about the same and removes the item from the trusted list. Details,
numbers and the next step below.

## Results

| Target | Tool | Source | Bound | Fixed code | Reverted bug | Time (64/32-bit) | Code / annotation lines |
|---|---|---|---|---|---|---|---|
| A. Object model: is_smi, is_heap_object, Smi::from, HeapObject::_raw_at/header/class_id/has_class_tag, Instance::at/at_put, Array::length/at, ByteArray::raw_length/content, six type tests, heap open/close lemmas | VeriFast (C) | rendering of objects.h | unbounded | verified (141 stmts) | — | 0.26 / 0.18 s | 162 / 486 (one-time, incl. 50 lines of shift lemmas) |
| B1. `MessageEncoder::encode_any/array/list/map` | VeriFast (C) | rendering of messaging.cc | unbounded (any heap, sizes, nesting) | verified: memory safety, no overflow, heap read-only | f708ad5d: fails at `(uword)(to - from)` (negative count); with `0 <= from <= to` assumed, at `Array_at(object, i)`, `i < len` | 0.19 / 0.15 s | 189 / 92 in the bodies (241 / 163 with the stubs) |
| B2. `toit_v2_grow_stack` + `Stack::v2_copy_to` against `gc_grow_stack` | VeriFast (C, Z3) | rendering of interpreter_v2.cc, objects_runtime.cc | unbounded | verified: OK ⇒ free ≥ needed; records, header fields, used slots preserved; else unchanged | `needed` unbounded (the current Verus contract): fails at the cast; `needed ≤ INTPTR_MAX`: fails at the sum | 0.91 / 0.66 s (69 s with VeriFast's default prover) | 37 / 42 in the bodies (86 / 165 with the trusted GC/allocator/header contracts) |
| B3. `PRIMITIVE(string_write_to_byte_array)` with its `ARGS` decoding | VeriFast (C) | rendering of primitive_core.cc + the primitive.h macros | unbounded | verified: copy inside the regions, legal memmove use, no overflow | af4ba7ab (memcpy): fails at the memcpy (no separate chunks); verifies with non-overlap assumed | 1.01 / 0.69 s | 19 + 25 macro lines / 59 in the body (73 / 148 in all) |
| B4. `Utils::utf_8_to_16` with `bytes_in_utf_8_sequence`, `payload_from_prefix` | VeriFast (C, Z3) | rendering of utils.cc, utils.h | unbounded | verified, including the bit-level facts WP left open | 07c24665: fails at the `payload_from_prefix` precondition (the UB shift); only the length part reverted: fails at `input[i + j]` | 1.42 / 1.63 s | 66 / 49 in the bodies (74 / 112 in all) |
| Rust: `Heap::string_len`, `string_byte` (view.rs) | VeriFast (Rust) | copy of view.rs bodies | unbounded | verified (internal strings) | `i <= len`: fails at the content read | 0.22 s (64-bit host) | 34 / 23 |
| Tagged read `*(uword*)((uword)this - 1)` in a C++ class | frama-clang + WP | C++ | unbounded | 14/14 goals | — | 1.1 s | — |
| C++ copy of Array::length/at (no helper contracts) | frama-clang + WP (Typed+cast) | C++ | unbounded | 22/25 goals (callees without contracts) | — | 23 s | — |
| Real src/objects.h | VeriFast C++ / frama-clang | real | — | not accepted (casts; F1, F2) | — | — | — |
| Tagged read | CN | C | — | rejected (no allocation id after int-to-pointer) | — | 0.2 s | — |

All VeriFast entries: `verified/cxx/annotated/run.sh` (expected verdicts,
both widths). Times on this machine, one core. "Code" counts C lines of
the rendering, "annotation" counts lines inside `//@` and `/*@ @*/`
(`metrics.sh`), comments excluded.

## Tools (installed without root)

`verified/cxx/annotated/install-tools.sh` (stages as named):

| Tool | Version | How | Size |
|---|---|---|---|
| VeriFast | 26.10 (2026-10-05), Z3 4.5 and Redux built in | GitHub release tarball | 304 MB (94 MB download) |
| VeriFast Rust front end | rustc nightly-2026-09-25 with rustc-dev, llvm-tools, rust-src | `rustup toolchain install` into an own RUSTUP_HOME | 1.6 GB |
| frama-clang | 0.0.20, into the first pilot's opam switch (Frama-C 33) | source tarball pinned with `opam pin`, linked against the host's shared LLVM 21 (/usr/lib/llvm21). The opam-repository package wants libclang 22. With the LLVM 22.1.8 release tarball (zstd fix in its CMake exports) it built, but linked the host's libLLVM.so.23 and aborted at start ("no handler registered for module format 'raw'"). That tarball (12 GB unpacked) was removed afterwards | 65 MB |
| CN | git main 891fcaa6 (2026-11-05), cerberus-lib dev, Z3 5.1.0 | `opam install ./cn.opam z3` in an own opam root with OCaml 5.2.0 (the README's route; the first pilot's `opam pin` of the Cerberus repository failed because CN moved) | 1.2 GB |

## A. The object model

`verified/cxx/annotated/model/objects.h` (predicates, contracts) and
`objects.c` (the accessor bodies, verified against those contracts). The
model, in words:

* **Tagged words.** `is_smi_w(w)` is `w % 2 == 0`; `is_heap_w(w)` is
  `w % 4 == 1`; `smi_val(w)` is the signed word halved. The code's
  `(uword)o & 1` and `& 3` are tied to these by VeriFast's
  `bitand_pow_nat` lemma, one call each.
* **Raw address.** `raw(o) = (uword *)((uword)o - 1)`, the very expression
  of `_raw_at`. All object chunks are stated at offsets from `raw(o)`.
* **Header.** `header(o; hw)`: a pointer-typed word at `raw(o)` that is a
  smi `< 2^16` (class id below 1024). `header_cid(hw) = hw / 64`;
  `header_tag2(hw) = hw & 30`, the expression `has_class_tag` compares.
  `class_id()` is proved from the C++ expression
  `Smi::from((Smi::value(header()) >> 5) & CLASS_ID_MASK)`. That needs
  arithmetic-shift and all-ones-mask lemmas, proved once (`arith.gh`, by
  induction over VeriFast's bit-string integers).
* **Bodies.** `instance_body(o, n; fields)`: n pointer-typed words after
  the header. `array_body(o; len, elems)`: the length word, then len
  elements. `byte_array_body(o; raw_length)`: internal bytes, or the
  external address and tag words. Fields and elements are the words as
  stored: nothing about their values.
* **The heap.** `heap(objs, H) = foreach(objs, heap_obj(objs, H))`. Here
  `H` is a ghost map from each object to its header, length and words: the
  abstract heap, as `objs` in the Verus model. `heap_obj` requires each
  object's tag to agree with its class
  (`header_tag2 == 2 * class_tag(cid)`), the field count of an instance to
  be its class's, and every word in a body to be `good`: a smi or a member
  of `objs`. That is TRUSTED.md V2 ("heap integrity") and the verifier's
  builtin-class check (`prog_ok`: List_ has at least 2 fields, ListSlice_
  3, Map 4; the array class has the array tag), the same seam the first
  pilot's harness had.
* **Opening one object.** `heap_open(o)` / `heap_close(o)` take one object
  out of a fraction of the heap and put it back. A function that holds
  `[f]heap(objs, H)` and returns it unchanged has provably not written the
  heap.

How VeriFast treats pointer to integer and back with low-bit tags
(`probes/tag_roundtrip.c`):

1. `(T *)(uword)p` gets the **null provenance**. A chunk owned at `p`
   does not match it: "No matching heap chunks: intptr(pointer_ctor(
   null_pointer_provenance, ...))". This is a sound model of C (PNVI). The
   way out VeriFast documents is a per-pointer
   `assume(p == (T *)(uintptr_t)p)`.
2. Stated at the computed address, `intptr((word *)((uword)tagged - 1),
   ?v)`, the access matches by address: no search over objects, constant
   cost per access. The pilot uses this throughout. The correspondence
   "this memory is the object" is assumed in the predicates. It is exactly
   the allocator/GC invariant the Verus side also assumes (V2).
3. Every implementation-defined or unsigned-wrapping step is checked:
   `(uword)o - 1` needs `o >= 1`; `(uword)-1` needs `/*@ truncating @*/`;
   `reinterpret_cast<word>(o)` for a word above `INTPTR_MAX` and `>>` of a
   negative word are refused outright. So **`Smi::value` is the one
   accessor whose body is not proved.** Its contract (the halved signed
   word, the smi range) is assumed: GCC and Clang define both conversions
   and C++20 standardizes them, VeriFast's C does not.
4. VeriFast enforces typed memory: a uword-typed chunk cannot be read
   through `Object **`. With `-fno-strict-aliasing` the C effective-type
   check is off, but the chunks are still typed (`pointer` vs `uintptr`).
   So what is proved is that each object word is always accessed at one
   type. The header and the fields are always `Object*`, the lengths
   always uword. The VM respects that.

The C rendering, and how it corresponds to the C++: every class is the
same opaque `struct Object` (they have no data members; `this` is the
tagged word); `T C::f(args)` becomes `T C_f(C *self, args)`; static
constants become macros with the same values; a template becomes a
function at the one instance used. Written out where VeriFast's C requires
it, and marked `// C++: ...` at each place: the implicit conversions
(`word & uword`, `uword + word`, word to uword arguments, int to uint16
stores). Also changed:

* A local whose address is taken is declared at the block start (the
  `Blob` locals of `_A_T_Blob`).
* VeriFast has no annotations inside macros, so the six `is_X` type tests
  are written out.
* `-assume_left_to_right_evaluation` allows calls inside expressions.

Everything else is the C++ expression, including the `ARGS`/`_A_T_*`
macros and `FAIL`.

What it would look like in place (not possible today: the C++ front end
rejects the casts):

```cpp
  INLINE Object* at(word index) const
  //@ requires [?f]array_body(this, ?len, ?elems) &*& 0 <= index &*& index < len;
  //@ ensures [f]array_body(this, len, elems) &*& result == nth(index, elems);
  {
    return _at(_offset_from(index));
  }
```

## B. The targets

### B1. The message encoder (f708ad5d)

`encoder/message_encoder.c`: `encode_any` (all branches: smis; List_,
ListSlice_, Map instances; null/true/false; byte arrays, doubles, strings,
arrays, large integers), `encode_array`, `encode_list`, `encode_map`. The
contract: given `encoder(self, ids, n)` (nesting `n` at most 8) and
`[f]heap(objs, H)`, and a `good` object, the function returns both
unchanged. Sizes, slice bounds, backings and map sizes are arbitrary smis
or references, as a program can store them. Trusted: the buffer writers,
`is_too_large`, the program's class-id roots, `encode_copy`,
`encode_byte_array` and the number-object reads (contracts: they read only
the given object). The recursion over a cyclic or shared graph is no
problem: each call holds a fraction of the whole heap, and termination is
not claimed (the nesting counter bounds the depth).

Excerpt (`encode_array`, fixed version):

```c
bool MessageEncoder_encode_array(MessageEncoder *self, Array *object, word from, word to)
//@ requires encoder(self, ?ids, ?n) &*& n <= MESSAGING_ENCODING_MAX_NESTING &*& [?f]heap(?objs, ?H) &*& mem(object, objs) == true &*& has_tag(H, object, ARRAY_TAG) == true &*& smi_range(from) == true &*& smi_range(to) == true;
//@ ensures encoder(self, ids, n) &*& [f]heap(objs, H);
{
  //@ heap_open(object);
  //@ open body(object, _, _, _);
  if (from < 0 || from > to || to > Array_length(object)) {
    //@ close [f]body(object, 2 * ARRAY_TAG, o_len(H(object)), o_words(H(object)));
    //@ heap_close(object);
    return false;
  }
  //@ close [f]body(object, 2 * ARRAY_TAG, o_len(H(object)), o_words(H(object)));
  //@ heap_close(object);
  MessageEncoder_write_uint8(self, TAG_ARRAY);
  MessageEncoder_write_cardinal(self, (uword)(to - from));   // C++: implicit word -> uword
  for (word i = from; i < to; i++)
  //@ invariant encoder(self, ids, n) &*& [f]heap(objs, H) &*& from <= i;
  {
    //@ heap_open(object);
    //@ open body(object, _, _, _);
    Object *element = Array_at(object, i);
    //@ good_nth(objs, o_words(H(object)), i);
    //@ close [f]body(object, 2 * ARRAY_TAG, o_len(H(object)), o_words(H(object)));
    //@ heap_close(object);
    if (!MessageEncoder_encode_any(self, element)) return false;
  }
  return true;
}
```

Readability: the contracts read well; the noise is the open/close pair
around each field access (4-5 ghost lines). A heap-level accessor
(`Array_at` with a contract over `[f]heap` and `has_tag`) would remove
most of it. It would be proved once in objects.c, as the type tests
already are; the pilot did not do that for the field accessors.

Mutant (`-D F708AD5D_REVERTED`: the three checks of the commit removed,
`ASSERT(from <= to)` as in a release build). The first failure is a bug
the commit message also names: "Potential arithmetic underflow. (Cannot
prove 0 <= (to - from).)" at `write_cardinal((uword)(to - from))`, the
huge element count of a slice with `to < from`. With `0 <= from <= to`
assumed at the old `ASSERT` (`-D ASSUME_FROM_LE_TO`), the next failure is
the read past the backing array: "Cannot prove i < o_len(H(object))" in
the precondition of `Array_at(object, i)` (message_encoder.c:339). This is
the List_ whose size exceeds its array. The first pilot's ESBMC ran out of
memory on this function at arrays of one element.

### B2. `toit_v2_grow_stack` against the Verus contract

`grow/grow_stack.c`: the arithmetic of the new length, the retry loop
around the GC, `Stack::v2_copy_to` (two memcpy of the records and of the
used slots, with the displacement) and the stack switch. Postcondition:
the current task's stack satisfies `same_abstraction` with the old one
(same record top, records and header fields; same used slots by position
from the end). On `TOIT_V2_OK`, `top' - rtop >= needed`, which is
`step::gc_grow_stack`'s `r == V2_OK ==> top - rtop >= needed`. Otherwise
the result is STACK_OVERFLOW or OUT_OF_MEMORY. Assumed: the GC preserves
the same abstraction (it may move and shrink the stack); the allocator
returns null or a fresh stack of the asked length; the header accessors
(bit-packed record word); the write barrier.

The `needed` bound: the Verus contract has none. The first pilot found
this by reading the code; here the prover finds it.
`-D NEEDED_UNBOUNDED` fails at `static_cast<word>(needed)` ("Cannot prove
needed <= 9223372036854775807", and 2147483647 on 32-bit).
`-D NEEDED_WORD_RANGE` fails at `(length - free) + needed`. With
`needed <= Stack::max_length()` (a bound of 2^20 here; the core passes
`FRAME_WORDS + max_height + STACK_RESERVE + FIN_WORDS`) it verifies. That
precondition should be added to the external_body contract.

VeriFast's default prover (Redux) needs 69 s for this file; Z3 needs 0.9 s.

### B3. `string_write_to_byte_array`, end to end (af4ba7ab)

`prims/string_write.c`: the real `ARGS` macro chain (`_A_10`,
`_A_T_Blob`, `_A_T_MutableBlob`, `_A_T_word`, `FAIL`), with member calls as
functions, then the body. Blob memory is a set of regions (internal
content or external memory; a slice shares its byte array's region),
`regions(rs)`, one `uchars` chunk each. `Object::byte_content` and
`mutable_byte_content` are trusted. Their contracts say the result range
lies in one region (mutable_byte_content may add one, for a
copy-on-write array made mutable). Their bodies (objects_runtime.cc, with
slices and the COW chain) are the natural next target for the object
model.

The proof splits into "same region" (one chunk holds both ranges) and
"two regions" (two chunks). memmove is given a contract that covers both.
VeriFast's own string.h memmove needs the two ranges in one contiguous
chunk, so it cannot serve two separate byte arrays. Mutant
`-D AF4BA7AB_REVERTED` (memcpy, with VeriFast's own memcpy contract:
separate chunks). The ghost code does the best possible: it splits the one
region when the ranges do not overlap. It fails with "No matching heap
chunks: uchars_(... dest_index ...)" at the memcpy, and with
`-D AF4BA7AB_DISJOINT` (non-overlap assumed) the same mutant verifies. So
the failure is exactly the overlap. ESBMC was blind to this bug class
(memcpy with memmove semantics); here it falls out of the separation
logic. Contents (memmove semantics byte by byte) are not stated; only
memory safety and that the copy is a legal memmove.

### B4. `Utils::utf_8_to_16` (comparison with the first pilot)

`utf8/utf_8_to_16.c`, with `bytes_in_utf_8_sequence` and
`payload_from_prefix` verified too. Contract: reads only
`input[0, length)`, writes only `output[0, output_length)`, no overflow, no
UB shift, no out-of-range conversion to uint16, result -1 or in
`[0, length]`, for every length up to 2^28. Frama-C/WP left 7 bit-level
goals open on this function. Here they are lemmas:

* the bit test `p & m` for a byte, by bit-blasting with `Z_of_uint8`;
* the leading-ones loop against a closed form `utf8_count(p)`;
* `x >> 1 == x / 2`;
* bounds of `(c << 6) | (b & 0x3f)` per sequence length, with
  `bitor_limits`.

They need `-prover z3v4.5`. Under Redux the first bit-blasting lemma did
not finish in 5 minutes; under Z3 the whole file takes 1.4 s. Mutants:
07c24665 reverted fails at the precondition of `payload_from_prefix`
(the `1 << (7 - 8)` UB the first pilot found); with only the length check
removed, "No matching array chunk: uchars(input, 0<=(+ i j)<n, _)": the
over-read.

## Other tools

* **frama-clang 0.0.20.** On a minimal class with a tagged `this` and
  `reinterpret_cast` (`probes/framaclang_min.cpp`): 14/14 goals, once the
  precondition says `(uword)this >= 1`. Without it the modular
  subtraction differs from the ACSL integer one. WP maps an int-to-pointer
  cast to `addr_of_int`, the same "state it at the computed address" as
  VeriFast. On the real headers (`probes/framaclang_real.cpp`), through
  `framac.sh`:
  * frama-clang's own libc++ lacks `std::function`, `std::nothrow`,
    `std::memcpy`, `is_trivial`, and the `make_unsigned` specializations
    (stand-ins: `fcshim/fcshim.h`);
  * Frama-C's libc `pthread.h` contracts do not parse in C++ ("reference
    to 'pthread_once' is ambiguous", then an assertion failure in
    framaCIRGen; stand-in: `fcshim/pthread.h`);
  * **F1**: `static const uword CLASS_ID_MASK = -1;` crashes framaCIRGen
    (`APSInt::getExtValue`: "Too many bits for int64_t";
    `probes/framaclang_uconst.cpp` reproduces it in 10 lines);
  * **F2**: with that constant changed in a copy, "Unsupported constructor
    initializer: Method".

  The system libstdc++ instead fails on `_Complex __float128`. A C++ copy
  of the Array accessors (`probes/framaclang_array.cpp`) gets 22/25 goals
  under Typed+cast: the private `_at`/`_word_at` would need their own
  contracts. WP has no separation logic, so B1 would need an axiomatized
  global heap predicate and explicit framing. Not attempted.
* **CN** (`probes/cn_tag.c`, `cn.sh`): both shapes fail with "Missing
  resource for reading, Resource needed: RW<intptr_t>(intToPtr)". The
  pointer from an integer has no allocation id; ownership stated at a
  derived pointer, or at a `(pointer)` cast in the specification, does not
  match it. CN's documented route is `__cerbvar_copy_alloc_id(addr, p)` in
  the code, i.e. changing every `_raw_at`. C only, besides.
* **VCC**: github.com/microsoft/vcc is archived; last commit 2021-01-20.
  Not tried.
* Others alive in this family, not tried: VerCors (Java-based, C subset);
  Gillian-C; RefinedC (Coq/Iris, heavy like VST); on the Rust side Prusti
  and Creusot (no C).

## C. Assessment

### (a) Annotation burden for all C++ inside the boundary

What the pilot measured, once the model exists:

| Kind | Annotation lines per C++ line in the bodies | Plus, per target |
|---|---|---|
| Object-graph code (encoder) | 0.5 | stubs for leaves |
| Glue with a GC/allocator contract (grow_stack) | 1.1 | 120 lines of trusted contracts (GC, allocator, header accessors) |
| Primitive with blob ARGS (string_write) | 3 (the two-region case split around one memmove) | a region model (40 lines, reusable by every blob primitive) |
| Bit-level helper (utf_8_to_16) | 0.75 | lemmas: 40 lines |
| The model (objects.h/.c) | 3 (one time) | — |

Effort in this pilot (agent hours; for an engineer new to VeriFast, count
three to five times longer): the model 2.5 h (mostly learning the tool's
pointer, provenance and bit-arithmetic rules), the encoder 1 h, utf8
1.5 h, string_write 1 h, grow_stack 1 h.

C++ inside the boundary and what it would take:

| Part | C++ lines (approx.) | Annotation lines (estimate) | Effort (engineer days) |
|---|---|---|---|
| The model extended: strings (internal/external), byte-array slices and COW, Stack, Task, doubles, large integers, the heap-level field accessors | — | +500 | 5 |
| `Object::byte_content`, `mutable_byte_content` (objects_runtime.cc), then contracts for all blob ARGS | 150 | 300 | 4 |
| MessageEncoder and MessageDecoder (messaging.cc): the decoder allocates and initializes objects, so heap extension (`appended`) must be modelled | 900 | 1 000 | 15 |
| ProgramOrientedEncoder (encoder.cc, encode_error, the raise path) | 400 | 400 | 6 |
| interpreter_v2.cc glue: grow_stack (done), start/transfer task, allocation wrappers, call_primitive retry loop, exception allocation, V2MethodTable::compute | 670 | 700 | 12 |
| 35 core primitives (25 to 60 lines each with helpers; mostly blob ARGS, number formatting and parsing, UTF-8, time/random shells) | 1 500 | 1 500 | 20 |
| Total | about 3 600 | about 4 400 | about 60 days |

The primitives line is the one to cut: most of them are on the port list
(the first pilot's recommendation), and a Rust/Verus port costs the same
0.5-2 days and leaves the trusted base. Without the portable primitives
the total is about 2 000 lines of C++, 2 500 annotation lines and
35-40 days.

### (b) Strength, and what remains trusted

* **Proved**: for every input and every heap that satisfies the model,
  unbounded:
  * no out-of-bounds or ill-typed access;
  * no signed overflow, no implementation-defined conversion or shift;
  * the stated contract (heap unchanged, the Verus grow contract, the
    UTF-8 length bound).

  Far more than the first pilot's bounded runs; no case splits over
  objects, so the cost does not grow with heap size.
* **Trusted**:
  * VeriFast itself (symbolic execution plus SMT; the Redux/Z3 split
    matters);
  * the C rendering's agreement with the C++. Not checked by a tool here.
    This is the largest gap;
  * the model's agreement with what the allocator and GC establish: that
    the exposed address `(uword)o - 1` is the object's memory, and the
    layout constants. The latter are shared with verified/layout_check.cc
    and could be checked against it;
  * `Smi::value`'s contract;
  * the stubs: buffer writers, GC, allocator, header bit-packing,
    `byte_content`;
  * single-threaded access (V1: VeriFast's chunks are exclusive or
    fractional per thread; nothing here models other threads, which is
    the VM's actual guarantee).
* **32-bit and 64-bit**: every C entry is verified for both `-target LP64`
  and `-target ILP32`, the same sources; only the class-id mask lemma
  needed a width case. The Rust run is host-only (64-bit).
* **Source, not device code**: like every source-level tool here, this is
  C semantics, not what GCC for Xtensa/RISC-V emits. VeriFast's
  provenance and effective-type strictness are on the safe side.

### (c) The seam with Verus

* **One contract, two renderings, is practical.** The VeriFast contract of
  `toit_v2_grow_stack` and the Verus `gc_grow_stack` say the same thing
  over the same observables (stack length, top, record top, the slots).
  The VeriFast side is phrased over the stack predicate, the Verus side
  over `reloaded(m, g)`. A contract table entry (first pilot, section 3)
  with formulas over named views can render the Verus `requires`/`ensures`
  and the VeriFast `//@ requires`/`ensures`. What cannot be generated is
  the bridge between the views: `reloaded(...).refines(p)` on the Verus
  side against `same_abstraction` and `stack_ok` here. That bridge is
  a reviewed definition, written once per view. The pilot already found
  one disagreement: the missing bound on `needed`.
* **VeriFast's Rust support is relevant.** `Heap::string_len` and
  `string_byte` (bodies verbatim from view.rs) verify against a predicate
  `internal_string(obj, len)` of the same shape as the C model, with the
  same integer-to-pointer treatment (null provenance, stated at the
  computed address). So one tool and one way of describing a VM object
  can cover the raw-memory accessors on both sides of the FFI.

  Caveats:
  * VeriFast does not read Verus files. The bodies must be copied or
    extracted (they are `external_body`: plain Rust, as the Kani pilot
    did).
  * A function with a precondition must be an `unsafe fn` for VeriFast
    (its soundness check of safe functions).
  * The Rust predicates are a third copy of the layout. They should be
    generated from layout.rs, like the C ones from the layout check.

### (d) Maintenance and CI

* **Run time**: the whole matrix (28 runs with all mutants, both widths)
  takes 23 s on one core. That is cheap enough for every push, unlike the
  first pilot's harnesses, which did not finish.
* **Installation**: VeriFast is one 94 MB download; the Rust front end
  adds a 1.6 GB pinned nightly. No root, no build.
* **Maintenance risks**:
  * **(1) Rendering drift.** A change to messaging.cc does not fail
    anything here. It needs a mechanical check: a script (Toit or shell)
    that extracts each rendered function's C++ original and compares it
    token by token after the documented rewrites, or an equivalence check
    with ESBMC (the first pilot's harness/utf_8_to_16_equiv.cc did that,
    bounded).
  * **(2) VeriFast's annotation language and its library change between
    releases.** Pin the version; the pilot used 26.10.
  * **(3) Error messages are precise.** Each failure named the exact
    obligation, which kept the debugging cycles short. The pitfalls were
    tool behaviour:
    * `p + 0` is not simplified to `p`;
    * a ghost `assume` inside a skipped `#ifdef` broke parsing;
    * `#if` between a `for` and its invariant is not accepted;
    * Redux is slow on division and bits.
* **Skill**: separation-logic annotation is a skill; the model and the
  lemma library make it repeatable, and the error messages point at the
  exact obligation.

### (e) Against porting to Rust/Verus

If the Rust interpreter runs all containers, every ported primitive
replaces its C++ version, costs no extra flash, and is inside the theorem.
For those, porting beats annotating. What stays C++ regardless is the
natural home for VeriFast:

* the interpreter glue to the allocator, GC and scheduler (interpreter_v2.cc:
  stack growth, task start and transfer, the primitive call retry,
  exception allocation, the method-table decoder);
* `byte_content`/`mutable_byte_content` and the `ARGS` decoding the
  remaining C++ primitives use;
* the message encoder and decoder (messaging.cc), shared with the C++
  side of process messaging and spawn arguments, timers, events and
  anything OS-facing. Here only the argument decoding and the shell can
  be verified; the effect stays in trusted code.

For these, the proof has to be in C++ terms, and VeriFast gives an
unbounded result in seconds where the model checkers gave none.

## D. Recommendation

**Adopt VeriFast for the residual C++** (not more widely: keep porting
the pure primitives). Concretely, in order:

1. **Bring the Verus contract up to date.** Add the `needed` bound to
   `step::gc_grow_stack` (and take `needed` as unsigned, bounded, in the
   C++), through the normal review path (0.5 day).
2. **Close the rendering gap first.** A `verified/cxx/annotated/
   correspond.sh` that checks every rendered function against its C++
   source: extract the C++ function, apply the documented rewrites
   (member call to function, implicit conversions as casts), compare
   tokens; fail CI on drift (2 days). Alternatively, report the C++ front
   end's missing integer-to-pointer casts to VeriFast. It has templates
   and most classes already; with casts, the annotations could live in
   objects.h and messaging.cc themselves, as sketched in A.
3. **Put `run.sh` into the nightly job** with the pinned VeriFast
   (0.5 day).
4. **Extend the model** to strings, slices and COW byte arrays, and
   verify `byte_content`/`mutable_byte_content` with heap-level accessors
   (1.5 weeks). Then the MessageDecoder with heap extension, and the rest
   of the interpreter_v2.cc glue (about 5 weeks).

Total for the residual C++ without the portable primitives: about
7-8 engineer-weeks.

Optional and cheap (1 day): run VeriFast's Rust front end on all
`external_body` accessors of view.rs, with the bodies extracted. That
gives one tool, and one object description, on both sides of the FFI.

## Files

* `verified/cxx/annotated/install-tools.sh`: tool installation (versions
  and history in comments). `env.sh` holds the tool paths.
* `vf.sh`, `vf-rust.sh`, `framac.sh`, `cn.sh`, `cxx-ast.sh`: one run of a
  tool. `run.sh`: the matrix with expected verdicts. `metrics.sh`: line
  counts.
* `model/objects.h`, `model/objects.c`, `model/arith.gh`: the object model.
* `encoder/message_encoder.c` (B1), `grow/grow_stack.c` (B2),
  `prims/string_write.c` (B3), `utf8/utf_8_to_16.c` (B4),
  `rust/view_accessors.rs` (Rust side).
* `probes/`: the tag round trip (VeriFast, CN), the bit facts, the C++
  front-end probes, the frama-clang probes, F1.
* `fcshim/`: stand-ins for frama-clang's libc++ and pthread.h.
* `shim/`: the standard-header stand-ins tried for VeriFast's C++ front end
  on the real headers.
