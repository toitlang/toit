# Trusted base of the proved collector (verified/gc)

Everything the collector's proof relies on without proving it. The
machine-checked list of escape hatches is `TRUSTED.toml` next to this file,
enforced by `check.sh --only audit` (counts per file and kind, cross-checked
with `verus --no-cheating`). The crate is not in
`verified/tools/trust_audit.toit`'s crate list yet: it is not linked into the
VM before milestone M5, when it joins that list and `verified/TRUSTED.toml`.
This file explains the contracts behind the entries and the boundaries that
are not escape hatches. The list must only shrink.

## 0. On one page

| Kind | Items | Statement |
|---|---|---|
| Word size | `global size_of usize` (lib.rs, one per width) | the word is 8 bytes on 64-bit targets, 4 on 32-bit ones; Verus checks each declaration with a compile-time assertion for the target it verifies for; check.sh verifies both widths |
| vstd | `raw_ptr` axioms: `PointsTo`, `ptr_ref`, `ptr_mut_write`, the specifications of `<*mut T>::addr` and `<*mut T>::with_addr`, `PointsTo::is_disjoint`; `Map`, `Seq`, `Set` | Verus' own trusted base. The crate has no `assume_specification` of its own: unlike the core (`wrapping_add`), word pointers are `base.with_addr(base.addr() + i * W)`, with vstd's specifications, and the arithmetic is proved not to wrap |
| The page source (section 1) | `space::PageSource`: its contract | what every implementation must guarantee; the crate has none |
| The entry (section 2) | the preconditions of `statement::collect` | the heap is well formed and the caller hands over exactly the permissions it describes |
| The bridge's hypotheses (section 3) | the preconditions of `bridge::lemma_bridge` | the collector's heap represents the spec's, the roots include the state's, the core's heap invariant |
| Not verified | `nopanic/` (a C entry point: `unsafe` extern calls, `assume_new` for the ghost arguments), `tests/` | measurement and tests only; nothing in the VM |

What is checked at run time instead of trusted: the from-space table (word
aligned, in the address space with room above each page, sorted, disjoint:
`space::check_ftab`), the capacity of the to-space tables (`2 * nf + 1`
entries) and the reservation; each failure returns a `GcError` before
anything is written (proved: the state is unchanged).

## 1. The page source (`space::PageSource`)

To-space pages come from the runtime's page allocator. The trait's contract
is the assumption on every implementation:

- `reserve(n)` returning true reserves `n` pages; `take(key)` requires a
  reserved page and returns a fresh page: its start address `s`, word-aligned
  with `s + pw * W < usize::MAX`, and the permissions of its `pw` words
  (keys `(key, k)`, nothing else) with the heap's provenance (`prov()`, the
  provenance of `Ctx::base`); `release` ends the reservation. `pw()` and
  `prov()` do not change.
- Fresh means: nothing else holds these words. The proof does not trust
  more than that: that a new page overlaps no page the collector holds
  (from-space or to-space) and no object outside from-space follows from
  the permissions it holds (`space::lemma_page_apart_all`,
  `lemma_page_apart_others`, through `PointsTo::is_disjoint`).
- The collector reserves `2 * nf + 1` pages before it writes anything and
  is proved to take at most that many (two consecutive closed pages hold more
  than a page's words: `cap_ok`); it takes one at a time, when the next copy
  does not fit below the last page's sentinel word.

At M5 the implementation is an `external_body` wrapper of
`ObjectMemory::allocate_chunk` and `free_chunk`, whose reservation is
counted against the sandbox quota or a VM-wide reserve (the owner's decision
1 of the stage-1 README); a `take` that cannot deliver despite a successful
reservation must stop the VM in C++ (it would be a broken reservation, not
an out-of-memory condition the collector can report). The plan's
alternative, a collector that can abort mid-way leaving the heap unchanged,
was not chosen: undoing forwarding headers needs either the from-space to
be parseable or a log of the copied objects; the reservation keeps the
collector simple and its failure case trivial (nothing written).

## 2. The entry (`statement::collect`'s preconditions)

At M5 a derivation point establishes them, as `view::Heap::new` does for the
core (verified/core/TRUSTED.md section 1): the C++ hands over the process's
pages and the Rust side receives their permissions with a ghost description
of the heap. Until then they are the caller's obligations:

- `ctx_ok`: the words per page (`pw`, at least 2, at most 2^20) and the
  from-space page count (`nf`, at most 2^16) are in range; the ghost page
  starts `fss` are the table's contents (`ftab_ok`: the permissions of the
  table's `nf` words).
- `heap_ok`: the heap description is well formed. Every object agrees with
  its layout (`layout::obj_ok`: its words, a raw even header, raw words
  outside its reference slots) and its reference slots hold references to
  objects or raw words that are not from-space addresses (`slot_ok`). Every
  from-space object lies inside its page below the sentinel word, at the
  address its location gives, and from-space objects do not overlap. The
  objects outside from-space (the program heap) are at tagged addresses
  outside from-space, distinct from one another, and refer only to objects
  outside from-space (`prog_ref_ok`: the program heap is immutable and built
  before any process heap). At most 2^30 objects.
- `from_ok`: the permissions of every word of every from-space page, with
  the heap's provenance; each from-space object's words hold its abstract
  words under the old address map.
- `others_ok`: the header permissions of the objects outside from-space.
  No code reads them; they are ghost witnesses that a new page holds none of
  these objects. At M5 they come from the same derivation (the core's
  `HeapMem` has a permission for every object's header).
- `roots_in`: the root array's permissions; each root word holds its
  abstract value under the old address map, a valid slot value. Root
  completeness (every reference the C++ will later hand to the core is in a
  root the collector was given) is milestone M3's obligation, stated at the
  bridge (section 3).
- The to-space tables' permissions (`tcap` words each).
- The page source's `pw()` and `prov()` agree with the context.

## 3. The bridge's hypotheses (`bridge::lemma_bridge`)

`lemma_bridge` shows that the collector's statement implies the core's
`gcbridge::collected` (the real definition, imported with the spec crate),
and `lemma_spec_collection` composes it with the core's
`gcbridge::lemma_collected` into a collection of the spec
(`toit_spec::v2::gc::collection`) represented by the core's heap model. Their
hypotheses, which the integration must discharge:

- `rep(s.heap, h, cb)`: the collector's heap represents the spec's heap:
  same ids; every reference a spec object holds (`obj_vals`) is in a
  reference slot of the collector's object; every word the core models
  (`view::is_word`) is the core's word of the object (`view::word_val`)
  under any address map. With M1's layout (not the VM's) this is a
  hypothesis; M2 proves it for the VM's layouts from the object
  description.
- `heap_model_ok(s.heap, h.addr, cb)` and `ro <==> i < n0`: the core's heap
  invariant before the collection (`abs::heap_model_ok`, the program heap
  first).
- From-space is exactly the non-program heap (`from(h, i) <==> i >= n0`).
- `roots_cover(s, rv)`: the roots include the object stack, the globals and
  the running task (M3's completeness obligation).
- The program's roots and literals are program-heap constants
  (`gcbridge::ro_const`, as the core's `collected` asks).

No weak processing in M1: the bridge uses `zapped(ap, s, s)`. M4 (weak
maps) replaces it with the collector's own zapping, which `zapped` allows.
