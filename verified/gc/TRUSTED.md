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
| Layout facts (section 4) | `layout.rs`: the sizes and reference slots of the VM's objects | the shared constants are proved equal to the core's (`bridge::lemma_layout_constants`; LAYOUT.toml checks those against the C++); the size rules the core does not have (string and byte array sizes, external objects, stacks) are checked against the C++ `HeapObject::size` by the differential test |
| The bridge's hypotheses (section 3) | the preconditions of `bridge::lemma_bridge` | the collector's heap represents the spec's (proved for the VM's layouts from a structural description, `lemma_rep_vm`), the roots include the state's, the core's heap invariant |
| The C++ root obligation (section 5) | `sandbox_gc_roots`: the root array and the finalizer nodes are every reference the C++ holds into the process heap | one statement about the C++ runtime (proposed CONTRACTS.toml text); checked empirically by `TOIT_SANDBOX_GC_VERIFY` (from-space checked and poisoned after every collection) |
| The finalizer pass (section 6) | the C++ acts on the verdicts; `weak_keys_maps`; the null object | the node array is what the C++ lists hold; the C++ unlinks, queues and frees as the verdicts say; weak-map keys are maps; `Ctx::null` is the program's null |
| The tail bound and stack shrinking (section 7) | `tail::tiled` when `Ctx::tail`; `Ctx::smin`; `stack_copy_equiv` | the C++ gives each from-space page's used words and they are tiled by objects and one-word fillers; `smin` only decides how much a stack shrinks (any value is safe); the core reads a shrunk stack as the same state (the existing CONTRACTS.toml assumption) |
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
- `ctab_ok`: the class table's permissions (`ncls` 16-bit entries, the
  program's class bits); `cls_ok` for every object: its class id is in the
  table, its ghost class bits are that entry, its ghost stack array word is
  the context's `sw` (`Stack::HEADER_SIZE / WORD_SIZE`, which C++ passes:
  10 or 14 words, larger in debug builds).
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
  under any address map. `lemma_rep_vm` proves it for the VM's layouts
  from `obj_struct` (each object's header encodes its class; an
  instance's fields, an array's length and elements, a double's or large
  integer's payload are its words in the core's encoding; a stack's
  references are in its object stack) and the core's `heap_model_ok`.
  `obj_struct` is what the entry derivation (M5) must give together with
  `heap_ok`.
- `heap_model_ok(s.heap, h.addr, cb)` and `ro <==> i < n0`: the core's heap
  invariant before the collection (`abs::heap_model_ok`, the program heap
  first).
- From-space is exactly the non-program heap (`from(h, i) <==> i >= n0`).
- `roots_cover(s, rv)`: the roots include the object stack, the globals and
  the running task (M3's completeness obligation).
- The program's roots and literals are program-heap constants
  (`gcbridge::ro_const`, as the core's `collected` asks).

Weak processing (M4): `lemma_spec_collection_fin` and
`lemma_spec_collection_core_fin` take the heap after the finalizer pass;
the spec state after weak processing is `fin_state` (the weak maps the
collector reset are `gc::reset_map`, every other object unchanged: a
cleared finalizer bit is not part of a spec object), proved `zapped` from
the state. Their extra hypotheses are in section 6. Instead of `rep` they
take `obj_struct` of every object (the VM's layout), from which they derive
`rep` of the heap after the pass.

## 4. Layout facts (`layout.rs`)

The collector reads object sizes and reference slots as the C++
`HeapObject::size` and `roots_do` compute them (the table in layout.rs).
Little-endian targets only (the string length half word's position in
word 1; layout.rs has no big-endian definitions, so such a build does not
compile). How each fact is tied to the VM:

- Class tags, the header's class id and tag fields, the array, instance,
  stack, byte array, double and large integer word offsets, the content
  offset of strings and byte arrays, the string sentinel, the external
  objects' last word, the instance size field of the class bits: proved
  equal to verified/core/src/layout.rs (`bridge::lemma_layout_constants`),
  which verified/LAYOUT.toml checks against the C++ headers for both word
  sizes.
- The size rules the core does not need (an internal string has a
  terminating zero byte, `align(content + length + 1)`; an internal byte
  array `align(content + length)`; external strings and byte arrays 4
  words; a stack `sw + length` with its array at `sw`): checked against the
  C++ on every object the differential test compares (tests/difftest.rs:
  the size and reference slots of the proved collector's copy and of the
  C++ prototype's copy must agree, on heaps of real programs, 64-bit and
  32-bit with 4 kB pages).
- The stack array word `sw` is a run-time parameter (`Ctx::sw`), as the
  core's `Runtime::array_word`.

## 5. The C++ root obligation (milestone M3)

What the Rust side proves about roots: the state's values survive
(`bridge::state_live`) when the root array starts with the running task and
the globals in order (`bridge::roots_core`) and the process heap holds the
running stack in the running task's stack object (`rep` of
`bridge::saved(s)`): the object stack is reached through the task, the
collector never needs it as roots (`bridge::lemma_roots_core_live`,
`lemma_spec_collection_core`). The core's state at a collection point has
nothing else: its registers are saved in the stack object's header and its
views are re-derived after every call that may collect (verified/core/
TRUSTED.md section 1).

What remains is one obligation on the C++ runtime, stated here verbatim
(proposed `[[assumption]]` text for verified/CONTRACTS.toml at M5, when the
collector is linked):

> **sandbox_gc_roots** (C++ root completeness for the copying collector of
> sandboxed processes). At every collection of a sandboxed process's heap,
> the root array given to the collector holds, in this order: (1)
> `ObjectHeap::task_`, the running task; (2) the
> `program()->global_variables.length()` slots of
> `ObjectHeap::global_variables_`; (3) the slot of every `HeapRoot` in
> `ObjectHeap::external_roots_`; (4) `ObjectNotifier::object_` of every
> node of `ObjectHeap::object_notifiers_`; and the finalizer nodes are
> given with their kinds: (5) key and lambda of every node of
> `registered_callback_finalizers_` (`ToitFinalizerNode`,
> `WeakMapFinalizerNode`) and of `runnable_finalizers_`, (6) the key of
> every `VmFinalizerNode` of `registered_vm_finalizers_`. After the
> collection the C++ writes each root word back into its slot. Apart from
> these slots and the stack object of the running task (reached from
> (1)), the C++ runtime holds no reference into the process heap that it
> reads after the collection: the verified core keeps its state in that
> stack object; C++ primitives that fail with an allocation error are run
> again from the start after the collection, reading their arguments from
> the stack (`v2_primitive_failed`, `v2_allocate`, `toit_v2_grow_stack`
> re-reads `task()->stack()`); the message encoder and decoder hold heap
> references only within one encoding or decoding, which never collects
> (an allocation failure abandons the decoding); messages in transit and
> kept messages are malloc'ed buffers without heap references; the program
> heap and the process's `null_`, `true_object_`, `false_object_` are
> outside the process heap and refer to no process object; no other
> process, scheduler structure or external message handler holds a
> reference into the process heap.

Where the enumeration lives today: `ObjectHeap::iterate_roots` (1)-(4),
`ObjectHeap::iterate_finalization_roots` and the three finalizer lists
(5)-(6), src/heap.cc and src/heap_roots.cc. External roots are used by one
place (`toit_v2_allocate_exception`: the trace across the allocation of
the exception instance).

How it is checked empirically: `TOIT_SANDBOX_GC_VERIFY=1` (hosts only,
src/sandbox_gc.cc) makes every copying collection check, before from-space
is freed, that no slot of (1)-(6) and no reference slot of any object of
the new heap points into from-space, and then overwrites from-space with a
poison word, so that a reference the enumeration missed reads garbage
(and, under ASan, use-after-free once the pages are freed). Runs:
README, section M3.

## 6. The finalizer pass (milestone M4)

`statement::collect` takes the finalizer nodes as an array of four words
per node (kind, key, lambda, verdict): first the callback nodes (`ncb`:
the registered callback finalizers, kinds 0 Toit and 1 weak map, then the
queue, kinds 2 and 3), then the VM finalizers (kind 4), in the order of the
C++ lists. It proves, besides `collected` for the heap after the pass,
`fin::fin_done`: every node has its fate (`fin::fate`) and the heap after
the pass is the old one with the dead keys killed (`fin::changed_ok`). What
the C++ must do, and what the bridge assumes:

- The nodes are the C++ lists' nodes with their kinds (part of
  `sandbox_gc_roots`, section 5: the node keys and lambdas are roots
  through the node array, not the root array).
- The C++ acts on the verdicts: KEEP writes the key and lambda words back
  into the node; QUEUE (a registered Toit finalizer whose key died: the
  collector has cleared the key's finalizer bit and nulled the key word)
  moves the node to the queue with the key and lambda words; DELETE unlinks
  and deletes the node (for a dead weak map the collector has already
  reset the map and cleared its bit); FREE (a VM finalizer whose key died
  with its bit set) frees the key's external memory
  (`VmFinalizerNode::free_external_memory`) and deletes the node. The
  collector decides; the freeing and the list surgery are C++.
- `Ctx::null` is the address of the program's null object, `Ctx::nullid`
  its id; the bridge assumes `null2(ap) == Value::Obj(nullid)` (the spec's
  null is the program's first root).
- `bridge::weak_keys_maps`: the key of every callback node other than a
  registered Toit finalizer, if in from-space, is a map (`gc::is_map`).
  `add_finalizer` (src/primitive_core.cc) registers a weak-map node only
  for an instance of the map class outside the program heap; a queued
  Toit finalizer's key is null (`ToitFinalizerNode::weak_processing`), so
  not in from-space. `is_map`'s other conditions (not the task class, at
  least four fields) are the verifier's `check_builtin_classes`.

Not done: zapping the values of live weak maps (`zap_dead_values`). The
proved collector traces a live weak map's fields like any instance's, so it
keeps values the C++ prototype nulls; `zapped` allows that (an object may
stay as it is), so the statement holds; the difference is memory retained
until the map drops the entry. The differential test counts it.

## 7. The tail bound and stack shrinking

**Tail bound** (`tail.rs`). With `Ctx::tail` the collection first walks
every from-space page from offset 0 to its used words (`Ctx::fused`, one
word per page) and takes the largest object `mx`; it then reserves
`min(2 nf + 1, floor(nf * pw / (pw - mx)) + 1)` pages and is proved never to
take more (every closed page holds at least `pw - mx` words). Trusted:
`tail::tiled`, part of the entry derivation: the objects (and the C++
one-word fillers a stack shrunk in place leaves) tile each page up to its
used words. The C++ knows them: they are the previous collection's
`tused` table, the allocation top for the page being allocated in. If
`tiled` were false the bound could be exceeded mid-collection, so it is
not a mere hint; without `Ctx::tail` the reservation is `2 nf + 1` and
needs nothing.

**Stack shrinking** (`shrink.rs`). After the copy and the finalizer pass
every copied stack is shrunk in place by the C++ rule
(`Stack::shrink_v2_for_gc`, `shrink_stacks()`): records stay, the object
stack moves down by `d`, length and top drop by `d`, one-word fillers fill
the `d` words given up. `collected` says the copies' words are
`shrink::cimg`'s. `Ctx::smin` (the C++ passes `2 *
global_max_stack_height + RESERVED_STACK_FOR_CALLS + V2_FRAME_WORDS +
V2_STACK_RESERVE`) only sets how much is taken; any value is safe for the
statement. What the core needs, that the shrunk stack is the same state
for it, is `stack_copy_equiv` (verified/CONTRACTS.toml), already an
assumption for stack growth: the collector proves its premise
`same_abstraction` for every shrunk copy (`lemma_same_abstraction`: same
record top, records equal, the object stack equal counted from the end,
the other header words equal) and relies on it; it discharges nothing new.
The spec and the bridge are unaffected (the core models no stack word but
the header).
