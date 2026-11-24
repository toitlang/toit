# GC proof pilot (2026-11-24)

Scoping pilot for proving the collector. Branch `gc/proof-pilot` from
`wip/collector-proofs` at 9d79d677. Nothing here is in the trusted lists,
`run.sh` or `check.sh`. Admits are marked `PILOT ADMIT` and exist only on this
branch.

**Recommendation: route B (Rust + Verus).** Start with a spec change (stage 0
below) that every route needs. Then measure whether untrusted processes can
use a simpler non-generational collector (option C) before porting the
generational design.

## 1. The property

**What the core assumes today.** `Machine::refines` (core/src/exec.rs) requires
`g.heap == heap.objs()`. Every object of the abstract heap has a permission for
each of its words, at a distinct tagged address (`addrs_ok`), with the values
`view::word_val` gives. The GC leaf contracts (`gc_allocate_*`,
`gc_grow_stack`, `gc_call_primitive`, `Runtime::stack`) promise that if the
views represented `g` before the call, the new views represent `g` (plus the
allocation) afterwards. On the C++ side `gc_equiv(a, b)` is uninterpreted, with
these named properties (CONTRACTS.toml `[[assumption]]`):

- `gc_equiv_trans`: two collections compose.
- `stack_copy_equiv`: a copied stack with the same observables is equivalent.
- `prim_retry`: a failed primitive, a GC and the retry form one step.
- `gc_owns`: the collector owns and frees the external block of a dead object
  that has a VM finalizer.

The allocation window and page metadata after a GC are trusted separately
(TRUSTED.md section 9).

**What a collector can deliver (route B's `collected`, proved).** The ids stay
stable, the abstract objects are unchanged, and the addresses change:

- There is a live set L that contains every object reachable from the roots and
  is closed under references.
- There is a new address map `addr2`. Objects that were not moved (program heap,
  and old space when the collection does not compact) keep their address.
- For each live id j, its words at `addr2[j]` are `wval(objs[j], addr2, k)` (the
  core's `word_val` for this layout). Copies are disjoint.
- The roots hold `enc(addr2, v)` for their unchanged abstract values `v`.

**Gaps between the two:**

1. **Garbage.** The core's `refines` asks for permissions and distinct addresses
   for every object, garbage included, and a real collector reuses that memory.
   The core must move to a garbage-tolerant refinement: permissions and
   `addrs_ok` only over a live set L that is closed under the references in the
   stack, the globals and L itself. Ids stay stable. Or the spec gets a step that
   renames ids. The pilot proves the shape of the first option.
2. **Weak maps.** A full GC sets to null the values of a weak map's backing
   array that are not otherwise reachable (`zap_dead_values`, heap_roots.cc).
   That writes reachable objects, which "same `g`" forbids. Untrusted programs
   can create weak maps: `add_finalizer` on a Map is in `UNTRUSTED_CORE`. Either
   the spec makes weak values nondeterministic at GC points, or the policy denies
   weak maps to untrusted programs. This is a spec gap, not a C++ bug, and it is
   not documented anywhere in verified/.
3. **Roots.** The spec sees the current stack and the globals. The collector also
   needs the C++ roots: other tasks, process roots, message queues, resources,
   notifiers, finalizer nodes. Nothing states that every object the C++ can later
   hand to the core is reachable from the enumerated roots. A proof needs one
   explicit root interface and a completeness obligation on it.
4. **Finalizers and revival.** Callback finalizers revive what their lambdas
   reach (heap.cc runs a second drain). A proof needs the finalizer lists as
   roots, with "dead key" decided by the same liveness oracle. VM finalizers
   discharge `gc_owns`: free each block exactly once and refund its accounting.
5. **Stacks.** Stacks are shrunk and moved during marking. `stack_copy_equiv`
   covers the copy. The collector must keep the used slots and the frame records
   (heap/stack_relocate and stack_fill prove pieces).
6. **Cards.** After a scavenge, every old object that holds a young reference
   must have a dirty card. The core's `CardBytes` permissions are re-derived at
   GC points, so the post-GC contract must also hand them out.
7. **Allocation window.** The copy pointer after the scan is the new young
   allocation window, with a sentinel and the unused words owned. Today this is
   trusted (`Runtime::allocation_window`). Route B's `free` result is that
   window.
8. **Capacity.** The young path stores the clone result without a null check
   (`*p = clone_into_space(..., &to_)`). This is sound only if to-space is at
   least as large as the used part of from-space. Route B proves exactly this
   argument (`lemma_capacity`, under `flen <= tlen`). The VM must keep the spare
   chunk at least as large as the from chunk. This is an obligation, not an
   observed bug.

## 2. Inventory

C++ line counts include comments. Text sizes are i686 `-Os` objects
(`build/tmp/cxxsz_all.sh` in the worktree): the whole collector is about 27 KB
(an upper bound: inline functions are counted in every unit).

| Phase | Code (approx. lines) | Invariant to keep | Existing coverage (bound) |
|---|---|---|---|
| Young copy: roots, clone, forwarding, Cheney scan | two_space_heap.cc 79-200 (120), object_memory_copying.cc (197) | Cheney: scanned prefix settled, pending run as copied, forwarding injective, capacity | VeriFast heap/semispace, young_allocation, scavenge_clone, scavenge_roots, scavenge_chunk, scavenge_drain: each modular with abstract contracts, not composed. ESBMC gc_scavenge_graph (2 instances, 1 field), gc_scavenge_alias (one 3-word object), gc_scavenge_phases, monitor_scavenge. **Pilot: both routes, any size** |
| Promotion and promoted tracks | mark_sweep.cc 343-396 (55), two_space_heap.cc water mark | promoted objects scanned once; tracks retired | VeriFast scavenge_drain (termination). ESBMC gc_promoted_track, gc_promotion_capacity, promotion_header |
| Remembered set / cards | mark_sweep.cc 261-342 (80), gc_metadata cards | dirty card for every old→young reference | VeriFast remembered_card. ESBMC gc_remembered_card. Core: `CardBytes` (Verus, proven) |
| Old mark: marking stack, overflow | mark_sweep.h (123), mark_sweep.cc 687-726, gc_metadata mark/overflow bits | every reachable object marked; overflow cards rescanned until empty | VeriFast mark_bits, mark_roots, mark_process, overflow_card, page_scan.c. ESBMC gc_mark_*, gc_overflow_* (small fixtures) |
| Sweep | mark_sweep.cc 527-606 (80), sweep_empty_cards.h (95) | dead runs become free regions; live objects untouched; empty chunks released | Frama-C gc-page-scan-wp (32-bit card patterns). ESBMC gc_sweep_free_region; gc_sweep_chunk gives no verdict (other agent) |
| Compaction: destinations, fix pointers, move | mark_sweep.cc 198-260, 415-526 (170), gc_metadata cumulative bits | order-preserving bijection live → destination; every pointer fixed; memmove overlap | VeriFast fix_roots, object_move. ESBMC gc_compaction_* (12 harnesses, fixtures); overhang gives no verdict |
| Free lists and old allocation | mark_sweep.cc 66-182 (117), object_memory.h FreeList | bucket chains; accounting | VeriFast free_list, limits. ESBMC free_list_* (selection gives no verdict) |
| Chunks and metadata setup | object_memory.cc 221-360 (140), gc_metadata.cc (338) | disjoint chunks; tables mapped and initialized | ESBMC gc_chunk_*, gc_page_*, gc_metadata_*; metadata_layout gives no verdict |
| Roots, finalizers, weak, external memory | heap.cc 308-460 (150), heap_roots.cc (226), process roots | roots complete; revival; free each block once | VeriFast process_roots. ESBMC gc_callable_finalizer, gc_external_finalizer, gc_process_roots, gc_root_iterator, finalizer_* (one or two nodes) |
| Driver and phase order | two_space_heap.cc 166-464 | phase order; accounting; epoch | ESBMC gc_collection_phases, gc_scavenge_phases, gc_process_epoch |

No existing check covers a heap of arbitrary size end to end. The VeriFast
pieces are composed through abstract predicates (`partition`, `copy_storage`,
`source_objects`) that nothing ties together.

## 3. The pilots: the young copy

### Route B: Rust + Verus (`verified/gcpilot/src`)

- **Code.** A Cheney scavenge over a from-space and a to-space of any size, as
  raw word arrays with `vstd::raw_ptr` permissions (the accessors work as the
  core's do). It has the copy with forwarding header, the slot visitor, the root
  loop, the scan loop and the driver. It is `no_std` and has no panics.
- **Spec.** Stable object ids. `enc`/`wval` is the core's encoding for a
  three-kind layout: instance, array, raw. The contract is `collected`
  (section 1).
- **Proved, with no admits.** The whole scavenge, including the capacity
  argument (a set-cardinality bound on the copied from-space words) and
  termination. The only trusted item is the `wrapping_add` specification, which
  the core already trusts.
- **Size.** 1,261 lines in total: about 90 lines of code (65 statements plus
  signatures), about 940 lines of spec and proof, the rest comments. That is
  about 14 proof lines per code line, and the figure includes the spec, which
  later phases reuse.
- **Verify time.** 21 s with 64-bit words and 15 s with 32-bit words (Verus
  0.2026.11.02, machine at load 50). 33 functions verified, 0 errors.
- **Code size.** The scavenge is 304 B on thumbv7m and 300 B on riscv32imac at
  opt-level s, and 618 B / 386 B at opt-level 3. On i686 `-Os` it is 383 B. The
  same C++ phases on i686 `-Os` take 641 B (scavenge_root 338, do_roots 66,
  SemiSpace::complete_scavenge with the scan 173, allocate 64), but the C++ also
  does promotion, the remembered set and multiple chunks. Expect parity once the
  Rust has those.
- **Run time (not measured).** The algorithm is the same. Differences:
  - The Rust copies with a word loop where the C++ calls memcpy (slower for large
    objects).
  - The Rust stops at the copy pointer instead of a sentinel.
  - The Rust decodes the layout from the header inline, with no virtual
    `roots_do`/`do_roots` dispatch. The real VM needs a class-table lookup, as the
    C++ does.
  - The Rust has no run-time checks (all proved).
- **Simplifications.** The layout is decoded from the header instead of the class
  table. One to-space chunk. No promotion, remembered set, finalizers, stacks or
  external bytes. The bridge to `toit_spec::HeapObj` is written out, not
  imported: the pilot crate does not depend on toit_spec.
- **Obstacles.** Loop isolation means immutable ghost facts must be restated in
  every invariant. Spec functions that take the whole state need frame lemmas
  when one field changes (`lemma_inv_frame`). One rlimit overrun, fixed by
  splitting the proof into lemmas.

### Route A: the existing C++, VeriFast (`verified/cxx/annotated/gcpilot`)

- **Rendered and proved, LP64 and ILP32** (`check.sh`):
  - `scan_copied_chunk` (the real loop) against a Cheney invariant over to-space
    contents of any length: a scanned prefix whose reference slots are relocated
    and settled, a pending run as copied, the sentinel. Termination included.
  - `ScavengeVisitor::scavenge_root` (the real function, young path) and
    `do_roots` (any slot range), with a content-level model: from-space objects
    as words with forwarding headers, pending copies appended, a capacity
    measure (`unfwd_words`) for to-space.
  - The helpers in_from_space, in_to_space, has_forwarding_address,
    forwarding_address, from_address and has_sentinel_at.
- **Admitted:**
  1. ADMIT 1: `HeapObject::roots_do`, the per-object step in the scan, together
     with the link between the scan-level `vstate` and the step-level
     `step_state`. The dispatch over 12 class tags (and Stack::roots_do) is not
     rendered.
  2. ADMIT 2: `HeapObject::size`.
  3. ADMIT 3: the word-level clone into the semispace.
     heap/scavenge_clone.render proves a byte-level version with a different
     predicate shape; the bridge between the two is not done.
  4. Promotion: the precondition puts the water mark at the start of from-space,
     which makes the old-space clone dead code.
- **Size.** 822 lines (two sidecars and the shared cheney.gh) for about 75
  rendered C++ lines. About 600 lines are annotations: about 8 per C++ line,
  with the admits above.
- **Verify time.** 0.6-0.9 s (scan) and 1.1-4 s (step) per width.
- **Obstacles.**
  - Every open/close is manual.
  - VeriFast has no quantifiers, so frame facts become inductive list lemmas.
  - Integer-to-pointer provenance must be pinned (`top == (void **)(uword)top`).
  - `x->f |-> _` means possibly uninitialized.
  - The renderer requires the C++ token for token, so loops cannot be reshaped
    to suit the proof.
  - Composition is by restating predicates in each sidecar: one more bridge per
    seam.

## 4. Estimates

| | Route A (VeriFast on C++) | Route B (Rust + Verus) |
|---|---|---|
| Proof lines per code line | 8 measured with 3 admits; 12-15 expected without admits and with composition | 14 measured, no admits; about 10 expected for later phases (spec reused) |
| Full generational collector (about 2,500 code lines) | 30-40k annotation lines, plus a bridge assumption per seam (the C++ model is not the core's model) | 25-35k proof lines, stated in the core's model; no bridge |
| Verify wall time | seconds per file | about 0.3 s per code line now: 10-15 min for the whole collector, parallel per function |
| Hard parts ahead | renderer rules for the virtual RootCallback, std::function visitors, range-for over DoubleLinkedList, templates; the 12-tag `roots_do`/`size` dispatch; composing more than 20 sidecars | compaction (forwarding from cumulative mark-bit counts: bitmap counting lemmas); mark-stack overflow and rescan; cards with object starts; weak and finalizer processing; Stack objects |
| Design or interface changes | none to the algorithm; code reshaped where the renderer cannot follow | collector rewritten in Rust behind an FFI: root slices from C++, finalizer and external-memory hooks, the class table from layout.rs |
| Flash | unchanged | same order as the C++ (pilot smaller, but with fewer features) |
| RAM | unchanged | unchanged (same algorithm and metadata) |
| Risk to speed | none | low: the core's proven accessors did not grow instruction counts; watch for proof-shaped code (word loops instead of memcpy) |

Both routes need stage 0 (garbage-tolerant refinement, the weak-map decision,
an explicit root interface) before any collector proof means anything end to
end.

**Option C: a simpler collector for untrusted processes only.** The untrusted
heap is capped at 128 KiB on devices (`UNTRUSTED_MAX_HEAP_BYTES`). The trusted
system keeps the current collector.

- **Non-generational mark-compact (old space only).**
  - Removes the young generation for these processes: scavenge, promotion,
    remembered set, promoted tracks, and the young/old interplay in finalizers.
  - Removes the cards. The core could then drop the write barrier (`CardBytes`)
    for untrusted programs, which needs a core mode or a second instance.
  - RAM: saves the young page and the spare chunk per process (4 KiB pages on
    ESP32); mark bits and cumulative bits stay.
  - Cost: every GC is a full mark-compact of the process heap. Pauses scale with
    the live heap and allocation-heavy programs run slower (not measured).
  - Proof scope: mark with overflow, compaction, free list, roots and finalizers.
    That is about 60% of the generational proof, and the hardest part
    (compaction) stays.
- **Semispace for the whole untrusted heap.**
  - The simplest to prove: the pilot plus roots, finalizers and large objects is
    most of it.
  - RAM: a to-space as large as the live heap, held transiently during each GC
    (chunks taken from the page pool). For a 128 KiB cap that is not affordable
    on a plain ESP32. It fits only with untrusted heaps capped at about
    32-48 KiB.

## 5. Recommendation and staged plan

Use route B.

- The pilot proved the whole young copy in the core's own terms with no admits.
- Route A, for comparable effort, left three admits and a composition seam.
- The existing ~1,600 lines of scavenge renderings were also never composed.
- Code size is at parity or better, and this matches the earlier Rust+Verus
  decision.

Option C is attractive for the sandbox (fewer phases, no cards), but decide on
measurements, not on proof cost alone.

| Stage | Work | Exit criterion |
|---|---|---|
| 0 | Spec and core: garbage-tolerant `refines` (live set, stable ids, `addrs_ok` on L); the GC leaf contracts in `collected` form; the weak-map decision (deny for untrusted, or spec nondeterminism); one root interface with a completeness obligation | core and spec verify; the pilot's `collected` proved to imply the new `refines` (gcpilot imports toit_spec types) |
| 1 | Measure option C: run the untrusted suite on the C6/ESP32 with the young generation minimized (full collections only) | pause and throughput numbers decide C or generational |
| 2 | Real layouts: the class table and all 12 tags, including Stack and external byte arrays, against `view::word_val`; scan and size dispatch proved | zero admits; differential host test against the C++ heap after GC |
| 3a (generational) | promotion and remembered set, multi-chunk to-space | the young collection replaces `two_space_heap` scavenge on hosts behind a flag; tests pass |
| 3b (both) | old mark with bounded stack and overflow rescans | proof: every reachable object marked |
| 4 | sweep and free lists, or compaction (cumulative bits, forwarding, fix, memmove) | proof: the `collected` contract for a full GC |
| 5 | finalizers, weak processing, external memory | `gc_owns`, `gc_equiv_trans` and `prim_retry`'s GC part removed from CONTRACTS.toml assumptions |
| 6 | Switch untrusted processes to the Rust collector (Kconfig), then trusted | ESP32 flash, RAM and pause measured, no worse than the C++ |

## 6. Collector bugs

None found. Spec-level findings: gap 2 (weak maps are not in the spec) and gap 1
(the core's model never frees). The capacity precondition of gap 8 is an
obligation to discharge, not an observed failure.

## 7. What was run

- Verus on the gcpilot crate, 64- and 32-bit (`verus --crate-type=lib
  src/lib.rs`; the 32-bit Verus is from build/verus-i686-unknown-linux-gnu).
- cargo build `-j4` for thumbv7m-none-eabi, riscv32imac-unknown-none-elf and
  i686, opt-level s and 3.
- VeriFast on the two pilot sidecars (gcpilot/check.sh), LP64 and ILP32.
- render.sh on the pilot sidecars and on model/objects.render (32-bit mirror
  only; the committed files did not change).
- clang++ `-m32 -Os` objects of the collector for size.

Not run: run.sh (any tier), check.sh, ESBMC, the slow tier, hardware, the
untrusted suite.

Reproduce:
- Route B: `cd verified/gcpilot && verus --crate-type=lib src/lib.rs`.
- Route A: `verified/cxx/annotated/gcpilot/check.sh`. It needs TOIT pointing to a
  host SDK with the tool packages, and the mbedtls headers.
