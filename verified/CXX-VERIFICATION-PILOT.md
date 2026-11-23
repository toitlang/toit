# Pilot: verifying the trusted C++ in place

Question (2026-11-11): the Verus proof of the sandbox ends at trusted items;
group (2) of them is C++ an untrusted program can reach (35 core primitives,
bitmap, timer and events, the encoders, the glue of src/interpreter_v2.cc
and the helpers they use). Can those pieces be verified where they are, with
a C/C++ tool, instead of being ported to Rust/Verus or merely trusted?

Everything here was done hands-on on this code base (branch
`experiment/cxx-verification`, based on `sandbox-integration` 2507b592).
Harnesses and scripts: `verified/cxx/`. Tools, logs, mutant source copies:
`/home/flo/work/opentoit-sandbox-artifacts/cxx-verification/`. No VM or
proof file changed.

## Summary

* **ESBMC 8.6** is the only tool that parsed the real C++ (whole
  translation units: `primitive_core.cc`, `messaging.cc`, `objects.cc`,
  `interpreter_v2.cc`, `utils.cc`, with the real `ARGS` macros, `objects.h`
  accessors and `process.h`) without rewriting. On code over plain buffers
  it is excellent: `Utils::utf_8_to_16` verified for all inputs ≤ 8 bytes
  in 5 s, the reverted over-read found in 3 s, plus an old UB shift. **On
  code over VM objects it did not scale**: the message encoder, the full
  `int_parse` primitive and `toit_v2_grow_stack` ran out of memory (10 GB)
  or time (25–30 min) in every configuration tried, including the ones with
  the reverted bugs, so it neither proved them nor re-found f708ad5d. The
  cause is structural: every field access goes through a tagged pointer
  (`reinterpret_cast<uword>(this) - HEAP_TAG`), and an integer-to-pointer
  conversion makes the tool resolve each access against every object of
  the model, recursively for fields that hold pointers. On top, three
  front-end defects needed work-arounds; one (T1) silently made every
  layout constant unconstrained, and ESBMC does not check memcpy for
  overlap (it gives it memmove semantics), so the af4ba7ab bug class is
  invisible to it.
* **crux-llvm 0.12** (symbolic execution of the LLVM bitcode clang makes
  from the real source with the VM's `-Os`) worked on a leaf (`utf_8_to_16`)
  and found the reverted bug in the optimized code (UB-shift poison and the
  over-read). It needs an LLVM ≤ 21 toolchain next to the host's clang 23.
* **CBMC 6.11**: its C++ front end fails on the VM's headers (libstdc++
  `<type_traits>`). Usable only on C copies.
* **Frama-C 33 / WP** (C only): on a C transliteration of `utf_8_to_16`,
  89 of 96 goals (memory safety, overflow, contract, all lengths) proved
  automatically; the 7 left are bit-level bounds (masks, shifts) that need
  interactive tactics. The transliteration was tied to the real C++ by an
  ESBMC equivalence check (all inputs ≤ 6 bytes).
* **CN**: not installable from its repository via opam today (no package
  definition for `cn`); C only anyway, so it shares Frama-C's problem.
* **Kani 0.68** (group 1, the Rust accessors): works, 10 harnesses in 6 s;
  found a Kani defect (T2) in its model of `ptr::copy`.

Recommendation, in short: **do not adopt a C/C++ verifier for group (2)**,
neither as a proof substitute nor as a CI gate over the primitives. Keep
porting the pure primitives to Rust/Verus (the result is unbounded and
inside the theorem; a trustworthy C++ harness costs as much per function and
gives a bounded result outside it, when the tool finishes at all), and keep
the scheduler/GC/OS-facing ones trusted with fuzzing. ESBMC is worth keeping
only as a cheap bounded check of the few buffer-level helpers that stay in
C++ (UTF-8/UTF-16 conversion, validation, LEB decoding), with a mutant per
harness. Details and the per-target results below; the next step is at the
end.

## Tools (installed without root)

`verified/cxx/install-tools.sh` installs each from release binaries (or
opam builds) under `$CXXV_HOME/tools`:

| Tool | Version | How | Size |
|---|---|---|---|
| ESBMC | 8.6.0 (Bitwuzla 0.9 default solver; Z3, CVC5, Boolector built in) | GitHub release zip, static binary | 684 MB |
| CBMC | 6.11.0 | Ubuntu 24.04 .deb unpacked with `ar`/`tar` | 212 MB |
| Kani | 0.68.0 (nightly-2026-08-21) | `cargo install kani-verifier`, `cargo kani setup --use-local-bundle`, own `RUSTUP_HOME`/`CARGO_HOME` | 2.6 GB |
| crux-llvm | 0.12 | GitHub release tarball | 152 MB |
| LLVM | 21.1.8 (for crux) | official release tarball (only clang++ and llvm-link are used) | 11 GB |
| Frama-C | 33.0 (Arsenic), Alt-Ergo 2.6.4, Z3 5.1.0, Why3 | static opam 2.6.1, own root, OCaml 5.3.0 switch, `opam install frama-c alt-ergo z3` (about 25 min) | 1.8 GB |
| CN | — | `opam pin add cn git+…/cerberus.git` fails: no package definition for `cn` | — |
| SeaHorn, SMACK, Symbiotic | not tried | Docker images or LLVM-version-pinned source builds; crux covers the LLVM-level approach | — |

Downloads: 2.5 GB. The Clang static analyzer is not a verifier (no
guarantee of absence of bugs); not evaluated.

## Feasibility: can the code be compiled as C?

No. The VM proper avoids exceptions and RTTI (`-fno-exceptions`,
`-fno-rtti` in release) and the STL in data structures, but it is C++
throughout: classes with inline accessors over raw words (`objects.h`),
templates (`List<T>`, `Utils::min/max`, `bit_cast`), namespaces, references,
lambdas (`v2_allocate` in interpreter_v2.cc takes one), `std::function`
(utils.h, heap.h), `std::atomic` (heap.h), `auto`, `static_cast`. A primitive
body is short, but it calls `Object::byte_content`, the `Smi`/`HeapObject`
encoding, `Process::allocate_*` and `Primitive::integer`; a C version is a
transliteration of all of that. That is what Frama-C, CN, VST and CBMC would
verify. A transliteration is honest only if it is checked against the
original: here an ESBMC equivalence harness compiles the C copy and the real
C++ in one unit (`harness/utf_8_to_16_equiv.cc`, all inputs ≤ 6 bytes,
6 s; it detects a divergent copy). That bounds the honesty of the unbounded
WP proof, and it costs a second artifact per function.

## Pilot results

All ESBMC runs: 64-bit host model, `--unwind` as stated (unwinding
assertions on: a loop that needs more iterations fails), default checks
(bounds, pointers, division) plus `--overflow-check` (signed overflow and
shift UB) where stated, memory capped at 10–12 GB (`ulimit -v`). Run times
on this machine (32 cores, one core per run).

| Target | Tool | Source | Bound | Real code | Reverted bug | Time |
|---|---|---|---|---|---|---|
| (d) `Utils::utf_8_to_16` | ESBMC | real utils.cc | input ≤ 8 bytes | verified (P1–P4, overflow) | found (over-read; and UB shift) | 4.9 s / 2.6 s |
| (d) `Utils::utf_8_to_16` | crux-llvm | real utils.cc, bitcode at `-Os` | ≤ 4 bytes (≤ 6: > 27 min) | valid (3069 goals) | found (poison, load error), ≤ 3 bytes | 42 s / 7 s |
| (d) `utf_8_to_16` C copy | Frama-C/WP | transliteration | unbounded | 89/96 goals (7 bit-level timeouts) | memory-access and shift goals unprovable | 69 s |
| (d) C copy ≡ real C++ | ESBMC | both | ≤ 6 bytes | equal | divergent copy found | 6.0 s / 2.2 s |
| (d) C copy | CBMC | transliteration | ≤ 8 bytes | verified | — | < 5 s |
| (d) `string_write_to_byte_array` | ESBMC | real primitive_core.cc | — | tool crash (T3) | memcpy overlap not checked by ESBMC | — |
| (a) `int_parse` (full primitive, ARGS, byte_content) | ESBMC | real primitive_core.cc, objects.cc | blob ≤ 64, loops cut at 3 iterations | verified (contract), weak | — | 251 s |
| (a) `int_parse`, full loop bound | ESBMC | same | loops ≤ 19 | no result in 40 min | — | — |
| (a) `int64_to_string` | ESBMC | real primitive_core.cc | all smis, bases ≠ 2/8/10/16 | no result in 25 min (symbolic base), nor with base 7 fixed | — | — |
| (b) `MessageEncoder` (List_, ListSlice_, Map_) | ESBMC | real messaging.cc, objects.cc | arrays ≤ 1–3 | out of memory (10 GB) | out of memory | 4–7 min |
| (c) `toit_v2_grow_stack` | ESBMC | real interpreter_v2.cc (+ v2_copy_to extract) | length ≤ 3, needed ≤ 3 | no result in 28 min | — | — |
| (1) `StackMem::copy_within`, `Heap::string_len/byte` | Kani | copies of view.rs | arrays of 6–8 | verified (7 pos harnesses) | 3 neg harnesses fail as expected | 5.7 s total |

### (a) A pure leaf: `PRIMITIVE(int_parse)`

`harness/int_parse.cc` compiles the real `src/primitive_core.cc` and
`src/objects.cc` and calls the static `primitive_int_parse(process, args)`
with an argument array on a fake stack, so the real `ARGS(Blob, input, word,
from, word, to, int, block)` decoding runs (`_A_T_Blob` →
`Object::byte_content`, `_A_T_word`, `_A_T_int` with
`Primitive::return_not_a_smi`). Input: a string or byte array of the heap
model (below) of any length up to 64 with unconstrained bytes; `from`, `to`,
the block argument: any smi (a non-smi only takes the type check, and each
extra heap object makes every field access dearer, see below).
`Primitive::allocate_large_integer`
(src/primitive.cc, it allocates) is defined by the harness to record the
value. Properties: memory safety, no signed overflow or UB shift, and the
**full functional contract** against an independent reference
(`parse_reference`: OUT_OF_RANGE for a bad or > 18-byte range,
INVALID_ARGUMENT exactly for bad syntax, else the value). Bound: blob length
≤ 64; the parser's own bound (18 bytes) makes that cover every range a
longer blob could have, as the code reads only `[from, to)`. The blob kind
is fixed per run (`CXXV_BLOB_KIND`); only the internal byte array was run.

Results:

* Before and after the T1 work-around, with the loops unwound 20 times:
  out of memory (10–12 GB) after 100–200 s in
  every configuration; the formula had 285 000 assignments, almost all of
  them case splits of the form `SAME-OBJECT(p, o1) ? o1[...] : SAME-OBJECT(p,
  o2) ? ...` over every object for each field read (`_raw_at` turns the
  tagged pointer into an integer and back).
* After it, with the from/to/block arguments restricted to smis and no
  oddball objects (fewer objects to resolve against), one blob kind
  (internal byte array), blob length ≤ 64, but the loops unwound only
  3 times (`--no-unwinding-assertions`: paths with more iterations are cut):
  **verified**, P1 and P2, in 251 s. This is a weak result: it covers the
  argument decoding and the range checks for every input, and the digit
  loop only for ranges of up to 3 bytes.
* The full bound (loops unwound 19 times by name, everything else twice,
  blob ≤ 19): no result in 40 minutes. The formula was small (3 469
  assignments after slicing); the time went into the solver.

A pure-arithmetic variant without a blob, `harness/int64_to_string.cc`
(`PRIMITIVE(int64_to_string)`, every smi value, the bases the body formats
itself: 64 iterations of a division by a symbolic base): no result in 25
minutes; with the base a constant (7) per run, still none in 25 minutes:
64 unrolled iterations of a 64-bit `%` and `/` on a symbolic value, plus
the harness's check that parses the digits back, are too much for
bit-blasting. The [current VeriFast proof](cxx/annotated/prims/format_integer.render) covers all 64-bit inputs and radices 2–36 for the shared C++ formatter. The native harness now captures the explicit length passed to the allocator.

### (b) Fields a program controls: the message encoder

`harness/message_encoder.cc` compiles the real `src/messaging.cc` and
`src/objects.cc` and runs `MessageEncoder::encode` (the size pass of
`process_send`; `-DCXXV_NO_WRITE_PASS` off adds the writing pass into a
buffer of the computed size and checks the two agree) on a nondeterministic
`List_`, `ListSlice_` or `Map_`.

The heap model (`harness/heap_model.h`) assumes exactly what the VM
guarantees: every reference is a live object with a valid header and the
size its class tag and length words imply (aligned as the allocators do);
blobs have their length, internal or external raw memory (TRUSTED.md V5); an
instance of a builtin collection class has at least the fields
`VerifierImpl::check_builtin_classes` (src/verifier.cc) requires of an
accepted program — **this is a seam: the harness relies on a check in the
C++ structural verifier**. Not assumed: the values of any field. Sizes,
`from`/`to`, map sizes are arbitrary smis; backings are arrays (≤ 3
elements), lists over arrays with an arbitrary size, smis or null.

Mutant: `mutants/message-encoder-bounds.patch` is `git diff f708ad5d
f708ad5d~1 -- src/messaging.cc` (the fix of the three over-reads), applied
to a copy of `src/` by `mutant-src.sh`.

Results: **no verdict, on the real code or on the mutant.** Every run ran
out of memory at 10 GB after 4–7 minutes of solving (Bitwuzla), in this
order of narrowing: any object graph (depth 2; 25 GB before it was capped);
collections only; elements constant smis (so `is_smi(element)` can be
decided while unrolling); one collection kind and one backing kind per run
(List_ over an array, the case of the first f708ad5d bug); arrays of at most
one element; per-loop unwinding (`--unwindsetname`); and as a pure
bug-finding run (`--no-unwinding-assertions`, unwind 3) on the mutant. The
size of the formula before solving was small (a few thousand assignments);
the solver blows up on the pointer resolution described in (a), which here
is nested: the list's backing field is a pointer read through a pointer, the
backing's elements a third level. The earlier fuzzing found these bugs in
minutes (docs/sandbox-primitive-audit.md).

### (c) Glue with a Verus contract: `toit_v2_grow_stack`

`harness/grow_stack.cc` compiles the real `src/interpreter_v2.cc`
(`Stack::v2_copy_to` is extracted verbatim from `src/objects_runtime.cc`,
see T3) and checks the C++ side of the leaf contract
`step::gc_grow_stack` (verified/core/src/step.rs):
`r == V2_OK ==> top' - rtop' >= needed`, plus what "refines again" needs
from the stack: records, frame top, finally count, bci and object-stack
slots (by position from the end) preserved; not OK leaves the stack alone.
Stack: any length up to `Stack::max_length()`, any top, frame top and
finally count the core can leave (record top ≤ top ≤ length). Modelled, not
compiled (group 3): `ObjectHeap::allocate_stack` (null or a fresh stack
initialized by the real `Stack::_initialize`), the GC (moves nothing; the
re-read of the task's stack after a GC is therefore not tested), the card
mark of the write barrier (an address computation into a side table that an
object-based memory model cannot express: replaced by explicit
specializations), `TOIT_V2_VALIDATE` unset.

Results:

* Before the T1 work-around: an out-of-bounds report in the harness's own
  object setup (`HeapObject::SIZE` was unconstrained), i.e. a tool artifact.
* After it, any stack length up to `Stack::max_length()`: after 290 s, an
  unwinding failure in ESBMC's `memcpy` model (a byte loop) for the
  symbolic-length copies of `Stack::v2_copy_to`: BMC cannot cover a 4 KB
  symbolic memcpy.
* Length ≤ 6 words, `needed` ≤ 8, memcpy unwound 60 times: no result in 30
  minutes. Length ≤ 3, `needed` ≤ 3, no oddball objects: no result in 28
  minutes either (3 573 assignments after slicing; solver time).

The contract question this raises for the seam: the Verus side declares
`gc_grow_stack` with no bound on `needed`, and `toit_v2_grow_stack` casts
`needed` to `word`. For `needed ≥ 2^63` the C++ would return OK with fewer
free words (the cast makes the check `free + growth < needed` false), and
for `needed` near `2^63` the sum `(length - free) + needed` overflows. The
only caller (`step::grow_frame`) passes `FRAME_WORDS + max_height +
STACK_RESERVE + FIN_WORDS`, small, so this is not a bug today; it is a
precondition the external_body contract does not state. (Found by reading
the code while writing the harness's precondition, not by the tool, which
did not finish; the harness bounds `needed` by `CXXV_NEEDED_MAX`.)

### (d) Conversions and overlapping copies

`harness/utf_8_to_16.cc`: the real `Utils::utf_8_to_16` (src/utils.cc, the
conversion of `string_to_utf_16`) on arbitrary bytes in a malloced block of
exactly the length (so any over-read leaves the object). Properties: memory
safety, no UB; the sizing pass returns `0 <= n <= len`; the writing pass
into exactly `n` units returns `n` (the primitive allocates from the first
pass and writes with the second, so a disagreement would be a heap
overflow); a shorter output is refused with -1. Mutant:
`mutants/utf-8-to-16-overread.patch` (`git diff 07c24665 07c24665~1`).

`harness/string_write.cc`: `PRIMITIVE(string_write_to_byte_array)` with a
destination that is the source byte array itself or a slice of it with
arbitrary bounds; property: memmove semantics (the destination byte
`dest_index + k` is the source byte `from + k` before the call). Mutant:
`memmove` → `memcpy` (af4ba7ab fixed this).

Results, `utf_8_to_16`:

* ESBMC, real code, inputs ≤ 8 bytes, `--unwind 10 --overflow-check`:
  **verified** (P1–P4), 4.9 s. Mutant: **found** the over-read
  (`utils.cc:348`, "array bounds violated: heap object", 2.6 s) and, with
  `--overflow-check`, a UB shift the commit message doesn't mention
  (`payload_from_prefix`, `1 << (7 - 8)` for a first byte `0xff`, 4.8 s).
* crux-llvm on the bitcode of the real `utils.cc` at `-Os` (LLVM 21):
  **valid** for inputs ≤ 3 bytes (749 goals, 7 s) and ≤ 4 bytes (3069
  goals, 42 s); ≤ 6 bytes did not finish in 27 minutes (path explosion:
  symbolic execution, exponential in the input length). Mutant (≤ 3 bytes):
  **found** both, as an LLVM poison value at `utils.h:340` and an error
  during a memory load at `utils.cc:348`, in the optimized code.
* Frama-C/WP on the C transliteration (`framac/utf_8_to_16.c`, ACSL
  contract: valid input/output ranges, separation, result -1 or in
  `[0, length]`; loop invariants; `-wp-rte`): **89 of 96 goals proved for
  all lengths** (Qed 62, Alt-Ergo 21, Z3 2, terminates/unreachable 4) in
  69 s; 7 time out even at 120 s: the bounds of `prefix & mask`,
  `1 << (7 - n)`, `c << 6`, `0xd800 + (c >> 10)` and the shifting-mask loop
  invariant of `bytes_in_utf_8_sequence` (bit-level facts WP's integer model
  needs tactics or bit-vector lemmas for). On the mutant the memory access
  `input[i + j]` and the shift goals become unprovable (87 of 99).
* ESBMC equivalence of the transliteration and the real C++ (all inputs
  ≤ 6 bytes, every output length ≤ 7, with and without output): equal,
  6.0 s; a copy with the old code is told apart in 2.2 s.
* CBMC on the transliteration (`cbmc/utf_8_to_16_harness.c`, inputs ≤ 8
  bytes, pointer, bounds, overflow and shift checks): verified, 63
  properties.

`string_write_to_byte_array`: **not run**. ESBMC crashes on the harness's
translation unit (T3: it needs all three overloads of
`Object::mutable_byte_content`). And it would not have found the bug:
**ESBMC does not check memcpy for overlap and gives an overlapping memcpy
memmove semantics** (`feas/memcpy_overlap.c`: the memmove-semantics
assertion holds under ESBMC); CBMC reports "memcpy src/dst overlap" on the
same probe. For this bug class (af4ba7ab) ESBMC is blind. The overlapping
copy was verified on the Rust side instead: Kani proves
`StackMem::copy_within` (a `ptr::copy`, overlapping allowed) against its
exact memmove `ensures` for every `from`/`to` and counts 0, 1 and 3 (see
"Group (1)" below).

### Group (1): Kani on two accessors of view.rs

`verified/cxx/kani/src/lib.rs` copies `StackMem::copy_within` and
`Heap::string_len`/`string_byte` verbatim (Verus attributes and ghost
parameters dropped; layout constants of layout.rs, 64-bit), turns the Verus
`requires` into `kani::assume` and the `ensures` into assertions, on a
String object laid out as src/objects.h does (internal and external). 10
harnesses, 5.7 s in total, all with the expected verdict:

* `pos_copy_within_safe` (memory safety for every from/to/n within the
  precondition), `pos_copy_within_contract_n0/n1/n3` (the exact memmove
  `ensures`, every from/to), `pos_string_internal`, `pos_string_external`
  (length and byte are the model's): verified.
* `neg_copy_within_wrapping_precondition` (the precondition evaluated with
  wrapping usize arithmetic instead of Verus' integers),
  `neg_string_sentinel_in_internal_string` (an internal string whose length
  half word is the sentinel), `neg_string_index_at_length` (`i <= len`):
  fail, as they must (the harnesses are not vacuous).
* `tool_copy_symbolic_count`: tool defect T2 (below).

What this adds to the Verus proof: the accessor bodies have no UB and meet
their `ensures` **on the layout the harness builds**. What it does not: that
the VM's objects have that layout and the addresses designate them (V2,
heap integrity), which is what the accessors really trust; that stays in
the harness as an assumption, as in the external_body contract.

## Tool findings

These are defects of the tools, found while doing the pilot; reproducers
are in `verified/cxx/feas` and the scripts under `$CXXV_HOME/feas`.

* **T1 (ESBMC 8.6, serious): constant initialization ordered wrongly.** In
  every translation unit that includes the heap headers (`heap.h`,
  `process.h`, everything that compiles a primitive), ESBMC emits the
  initialization of class static constants (`HeapObject::SIZE`,
  `Smi::MAX_SMI_VALUE`, every layout offset of `objects.h`) before the
  namespace constants of `top.h` they use (`WORD_SIZE`, …), whose values
  are unconstrained at that point. Effect: every object layout is symbolic.
  That is an over-approximation (no false proof), but it produces false
  alarms in the static initializers with `--overflow-check`, and formulas so
  large that the solver exhausts memory (the first runs of (a), (b), (c) did,
  at 12–25 GB). It is invisible unless checked: the harnesses now assert the
  constants at their start (`harness/constants.h`). Trigger narrowed to the
  instantiation of `std::swap` for `DoubleLinkedList<Chunk>`
  (object_memory.h:248) in one unit, and to other parts of `heap.h` in
  others; a minimal self-contained reproducer did not reproduce it
  (`feas/static_init.cc`), the in-tree one is `objects.h` +
  `third_party/dartino/object_memory.h` (`feas/bisect_om.sh`). Work-around
  (`harness/prelude.h`): after `top.h`, redefine the namespace constants as
  macros with the same constant expressions (static_asserts check them).
* **T2 (Kani 0.68): `ptr::copy` of `usize` elements with a symbolic count
  is modelled wrongly.** With the count constrained to 1, a copy of one
  element leaves a wrong value (`kani/src/lib.rs`,
  `tool_copy_symbolic_count`; with `u8` elements or a constant count it is
  right; the native run is right). It affects exactly the accessors that
  are memmoves (`copy_within`, `content_copy`, `array_copy`); the harnesses
  check the contract per constant count instead.
* **T3 (ESBMC 8.6): segfault in the C++ converter** on
  `src/objects_runtime.cc` as a whole, and on a unit with
  `primitive_core.cc`, `objects.cc` and `Object::mutable_byte_content`
  (5-argument overload) together, although each part alone converts. Work-
  around: verbatim extraction of the needed functions (`esbmc.sh`, `awk`
  from the function's first line to the next lone `}`).
* ESBMC's C/C++ library model lacks `strnlen`, `flockfile`,
  `fwrite_unlocked`, `putenv`, global `isfinite`/`signbit`, and its
  `std::function` cannot be copied: the harnesses declare the functions
  (`harness/cxxv.h`) and replace `<functional>` (`verified/cxx/include`);
  none is called on a harnessed path.
* crux-llvm cannot read clang 23 bitcode (LLVM ≤ 21 only), and its
  `crucible_size_t` is not overridden in 0.12 (use the integer variants).
* Objects are the unit of the memory models of all of these tools: a read
  into the padding of an allocation is not an out-of-bounds access for
  them (Kani `neg_string_index_at_length` showed it until the test object
  had no padding). The VM allocates word-aligned, so an off-by-one inside
  the alignment slack of an internal string or byte array is not found.

## Findings in the VM

No new memory-safety bug was found (little code got a complete verdict:
`utf_8_to_16`, the accessor copies). Observations:

* **Unstated precondition of a trusted contract** (above, (c)):
  `gc_grow_stack` needs `needed < 2^63` (and in practice `needed ≤
  Stack::max_length()`); the Verus `external_body` should require it, or
  the C++ should take `needed` as unsigned throughout. Not reachable today.
* **Old UB, already fixed**: before 07c24665, `payload_from_prefix` shifted
  by a negative amount for a first byte `0xff` (`1 << (7 - 8)`), besides the
  over-read the commit message names. ESBMC and crux (at `-Os`, as a poison
  value) both report it on the mutant.
* (Not a bug, noted while reading.) `Object::mutable_byte_content` checks
  `if (content == null)` where `*content` is meant (src/objects_runtime.cc,
  byte-array-slice branch); the check is dead, not harmful.

## Assessment

### 1. Coverage

Of the 35 C++ core primitives of the untrusted set and the bitmap, timer
and events primitives:

| Class | Primitives | With ESBMC harnesses like the pilot's | Effort per function |
|---|---|---|---|
| Pure leaves over blobs and integers | `int_parse`, `int64_to_string`, `uint64_to_string`, `printf_style_int64_to_string`, `smi_to_string_base_10`, `byte_array_convert_to_string`, `byte_array_is_valid_string_content`, `string_to_utf_16`, `utf_16_to_string`, `crc`, `word_size`, `platform`, `architecture`, `bitmap.byte_zap`, `bitmap.blit` (15) | the buffer-level helper each calls (`Utils::utf_8_to_16`, `utf_16_to_8`, `is_valid_utf_8`, `crc32`, the digit loops): yes, in seconds, for small buffers. The primitive as a whole, with its `ARGS` blob decoding over VM objects: only with truncated loops (pilot (a)); full bounds exhausted the tool. `snprintf` paths only up to the libc model | 0.5 day per helper; whole primitives not feasible today |
| Floating point through libc | `float_parse` (`strtod`), `float_to_string` (`snprintf %.*g`, buffer growth), `float_round` (`pow`, `round`) (3) | only the buffer handling around the libc call | weak result |
| Encoders and decoders | `process_send`, `encode_error`, `task_receive_message`, `main_arguments`, `spawn_arguments` (5) | no: out of memory even for a List_ over a 1-element array (pilot (b)) | — |
| Scheduler, GC, OS | `task_new`, `task_transfer`, `task_has_messages`, `add_finalizer`, `remove_finalizer`, `time`, `time_info`, `seconds_since_epoch_local`, `get_real_time_clock`, `random`, `gc_count`, `process_current_id`, `process_system_id`, `spawn_method`, timer and events (7) (21) | only the argument decoding and the shell; the effect is in code that stays trusted | not worth it |

Glue in src/interpreter_v2.cc: `toit_v2_grow_stack` (pilot (c): only tiny
stacks, symbolic memcpy is a loop in ESBMC's model), the `try_allocate_*`
wrappers (one line over the heap's allocators: nothing to verify without
the allocator), `v2_start_task`/`v2_task_transfer` (frame construction:
like grow_stack), `V2MethodTable::compute` (a LEB decoder over the
program's bytes, no objects: a good BMC target, 1–2 days),
`toit_v2_call_primitive` (retry loop around the GC: only the loop),
`toit_v2_allocate_exception` (encoder + allocation: as (b)). The helpers
`Object::byte_content` and the `ARGS` macros run unmodified in every
primitive harness, and are what makes those harnesses expensive.

So: the buffer-level helpers under about 12 of the 56 entry points, and the
method-table decoder, get a fast bounded result; the primitives themselves,
the encoders and the glue do not, with the tools as they are.

### 2. Strength

* **Bounded.** Every ESBMC result holds for inputs within the stated
  bounds (blob lengths, array lengths, object-graph shapes, unwinding). For
  leaves whose loops the code itself bounds (int_parse: 18 bytes; the
  formatters: 64 digits) a bound covers all inputs; for the conversions and
  copies (blob length unbounded) it does not: `utf_8_to_16` is verified for
  inputs ≤ 8 bytes, which is strong evidence and no proof. ESBMC's
  k-induction and loop-invariant modes were not tried (these loops need
  invariants about memory contents and the harnesses did not get that
  far); only the deductive tool (WP) gave an unbounded result, on a C copy.
* **What "verified" honestly means here**: no out-of-bounds access, no
  invalid pointer, no signed overflow or UB shift, and the stated
  assertions, for all inputs within the bounds, **under the harness's model
  of the VM** (heap model G1–G4, the stubs for allocators and GC, the
  harness's own arithmetic) and **under the tool's front end being right**
  (T1 shows how that fails silently). It is not the Verus contract
  `prim_heap_ok`: the harness checks memory safety and a few postconditions,
  not "every object stays well formed" over a heap it does not model.
* **32-bit targets.** ESBMC has `--32` (ILP32 machine model) and the
  harnesses are written for both widths (`BUILD_64` branches); the 32-bit
  runs were not done in this pilot. Source-level tools check the C++
  semantics, not the code the ESP-IDF compiler (GCC for Xtensa/RISC-V)
  generates. crux checks the LLVM IR clang generates (`-Os`), which is a
  different compiler from the device's; UB-dependent miscompilation by GCC
  is outside both.

### 3. The seam with the Verus proof

The Verus side assumes a contract per C++ function (`gc_grow_stack`'s
ensures, `prim_default` for every C++ primitive, the `Allocator`
contracts); a C++ tool proves a property in its language over its memory
model. To keep them in agreement:

* **One contract table** (TOML, next to `verified/TRUSTED.toml`), one
  entry per trusted C++ function: name, C++ symbol, the Verus item, the
  precondition and postcondition as simple formulas over the FFI parameters
  and named views (`stack.top`, `stack.rtop`, `stack.len`, `needed`,
  `result`), and the harness bounds. A generator (Toit, like the other
  verified/ tools) would emit the `requires`/`ensures` of the Verus
  `external_body` and the `CXXV_ASSUME`/`CXXV_ASSERT` lines of the C++
  harness; `check.sh` would fail when either drifts. Example:

  ```toml
  [[contract]]
  cxx = "toit_v2_grow_stack"
  verus = "step::gc_grow_stack"
  requires = ["needed <= 65536", "0 <= stack.rtop <= stack.top <= stack.len <= STACK_MAX"]
  ensures = ["result == V2_OK ==> stack'.top - stack'.rtop >= needed",
             "result == V2_OK ==> stack'.len - stack'.top == stack.len - stack.top"]
  bounds = { unwind = 6 }
  ```

  The pilot found that such a table would already have caught something:
  the Verus contract of `gc_grow_stack` has no bound on `needed`, the C++
  needs one.
* **What stays trusted**: the correspondence between the Verus views and
  the C++ objects (`reloaded(m, g).refines(p)` is far richer than the
  harness's "record top ≤ top ≤ length"; the ghost heap model `objs`,
  `addrs` is not in the C++ harness at all), the harness's model of the VM
  invariants (G1–G4, and the verifier's builtin-class check behind G3), the
  models of the allocators and the GC, the tool's front end and memory
  model, and the gap between source and device code.
* **Smaller than today?** Only for the buffer-level helpers, and modestly:
  today `prim_default` for, say, `string_to_utf_16` rests on review and
  fuzzing; with a harness its conversion loop is checked for every small
  input, but the primitive around it (argument decoding, allocation) still
  rests on review. For the glue and anything touching objects or the GC,
  no: the tool did not finish, and the parts that matter (the GC preserves
  the abstraction, the allocator appends one object) would be modelled
  anyway. A Rust port of a leaf removes the item from the trusted list; a
  C++ harness only changes what it rests on.

### 4. Cost in CI

* Run time: the buffer-level harnesses take seconds (utf_8_to_16 5 s,
  equivalence 6 s, crux at 4 bytes 42 s, Kani 6 s for all ten, WP 70 s).
  The object-level ones did not finish within 10 GB and 25–30 minutes;
  their cost grows with the number of objects in the model and with the
  depth of pointer chains, not with the size of the code. The matrix that
  does finish (`verified/cxx/run.sh`, utf8 and its mutant, equivalence,
  crux, Kani) takes 2–5 minutes (depending on the machine's load), one
  core each, with a memory cap.
* Installation: ESBMC is one static binary (684 MB); crux needs its own
  LLVM 21 (11 GB unpacked, of which clang++ and llvm-link are used);
  Frama-C an opam switch (1.8 GB, 25 min build); Kani 2.6 GB with its
  pinned nightly. Tool defects appeared in every tool tried (T1–T3, T2, the
  crux bitcode version limit), each costing hours to diagnose.
* Maintenance: each harness encodes the VM's object layout and invariants
  (heap_model.h), loop names (`--unwindsetname`) and work-arounds
  (prelude.h); the mutant patches must keep applying; a source change can
  silently change what a harness covers (T1 appeared when one more header
  was included). A Verus port needs attention only when the spec changes.

### 5. Recommendation

* **Group (2), leaves: port to Rust/Verus**, as planned (the audit's "cheap
  to move" list: UTF-8 validation and conversion, `int_parse`, the four
  integer formatters, `crc`, `float_round`, `word_size`, bitmap). A port is
  0.5–2 days per function including the proof, the result is unbounded and
  inside the theorem, and the C++ leaves the untrusted path. A C++ harness
  costs about as much and, for a whole primitive, did not finish.
* **Group (2), what stays in C++** (encoders, decoders, `ARGS` decoding,
  glue): **do not adopt a C/C++ verifier** for it. The pilot could not get a
  verdict on the message encoder, not even re-find f708ad5d, which fuzzing
  found in minutes; ESBMC is blind to overlapping memcpy (af4ba7ab). Keep
  the fuzzers (they found R5 and the encoder bugs) and the reviews.
* **Adopt only for a subset**: ESBMC (and crux as a second opinion on the
  `-Os` code) for the buffer-level helpers that stay in C++ until ported
  and for `V2MethodTable::compute`, as a CI check with a mutant per harness
  and the T1 sentinel. Seconds per harness.
* **Do not adopt** CBMC (no C++), CN/VST (C only, heavy), or Frama-C on
  transliterations (two artifacts per function; the equivalence that keeps
  the copy honest is bounded anyway) for this code.
* **Group (1) with Kani**: works on copies of the accessors, in seconds. It
  checks the bodies against their `ensures` on a layout the harness builds;
  the trusted part (layout and heap integrity, V2) moves into the harness
  unchanged, and T2 shows Kani's model of exactly the memmove accessors is
  not reliable yet. Low value; a one-off review at most.

**Next step** (about 2 days): (1) add the missing precondition on `needed`
to `gc_grow_stack` (and take `needed` as unsigned in the C++) through the
normal review path; (2) put `verified/cxx/run.sh` (the entries that finish)
into the nightly job, so the UTF-8 helpers keep a bounded check until their
Rust ports land; (3) report T1 and T3 to ESBMC and T2 to Kani with the
reproducers; (4) spend the rest of the budget on the Rust ports. A contract
table generator (section 3) is worth building only if more than a handful
of C++ functions keep a precise contract; with the ports, they won't. If the
question is reopened, the thing to try is a tool with a byte-addressed
memory model that handles integer-to-pointer casts cheaply (e.g. a
SeaHorn/Crux setup with flat memory), on the encoder harness; the pilot's
heap model and mutants carry over.

## Files

* `verified/cxx/install-tools.sh` — tool installation (records versions).
* `verified/cxx/env.sh` — tool paths, the VM's flags.
* `verified/cxx/esbmc.sh`, `cbmc.sh`, `crux.sh`, `framac.sh`, `kani.sh` —
  one run of a tool on a harness.
* `verified/cxx/run.sh` — the pilot matrix with expected verdicts.
* `verified/cxx/mutant-src.sh`, `verified/cxx/mutants/*.patch` — known bugs
  put back into a copy of `src/`.
* `verified/cxx/harness/` — ESBMC and crux harnesses, `heap_model.h`,
  `prelude.h` (T1), `constants.h` (T1 sentinel), `cxxv.h`.
* `verified/cxx/framac/utf_8_to_16.c`, `verified/cxx/cbmc/` — the C
  transliteration with ACSL, its CBMC harness.
* `verified/cxx/kani/` — Kani harnesses on copies of two view.rs accessors.
* `verified/cxx/include/functional` — `<functional>` stand-in for ESBMC.
* `verified/cxx/feas/` — feasibility probes and the T1 reproducer attempt.
