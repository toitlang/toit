# Trusted base of the verified core

Everything the core relies on without proof. The machine-checked list of
every escape hatch (external_body, uninterp, unsafe, plain-Rust items) is
verified/TRUSTED.toml, enforced by `verified/check.sh`; this file explains
the contracts behind the entries. The list must only shrink.

## 0. The residual trusted base on one page

Since branch core/proven-accessors (2026-11-11) no accessor of VM memory
is trusted: every read and write of the stack, the program tables, the
globals and the heap objects is verified against `vstd::raw_ptr`
permissions (section 1). What remains, all of it:

| Kind | Items | Statement |
|---|---|---|
| Derivation points (the allocator and GC invariant, section 1) | `Table::from_raw`, `Globals::from_raw`, `StackMem::from_stack` (via `ffi::Runtime::stack`), `Heap::new`; the leaf contracts of the calls that may GC (section 2, 6: `gc_allocate_instance`, `gc_allocate_double`, `gc_allocate_exception`, `gc_grow_stack`, `gc_call_primitive`, the `Runtime` wrappers) and of `ffi::Allocator` (section 8), which hand out the views after them | the VM's memory is well formed now: the permissions of exactly the words, half words and bytes `view::word_val`, `str_ok`, `ba_ok`, `hdr_ok`, `array_ok` describe, with the values the heap model says (V1, V2, V5) |
| Aligned load | `Table::u16_at_even` (a method header's u16 field, format note 21) | one 16-bit load of two bytes the table's permissions cover, at an even address (`Table::even`, checked at entry), is their little-endian combination (`u16::from_le`) |
| Rust and target semantics | the `assume_specification`s of `pointer::wrapping_add` and `wrapping_offset`; `global size_of usize`, `size_of u8` (compile-time checked) | wrapping address arithmetic keeps the provenance; the word size |
| vstd | `raw_ptr` axioms (`PointsTo`, `ptr_ref`, `ptr_mut_write`, `with_exposed_provenance`, `IsExposed`), `Map`, `Seq` | Verus' own trusted base. Note: a `PointsTo` grants writing; program-heap objects (read-only memory) get permissions too, and every verified write requires `!ro` (`set_field`, `set_element`, `content_*` with `writable`, `set_byte_at`, `set_string_hash_field`) |
| Not memory | `Preemption::{word, clear, request}` (the scheduler's watermark, environment nondeterminism), `proven_unreachable`, the loader's and scheduler's `assume_new`s (section 6), the epoch (section 9), floating point (`prims/fp.rs`, the spec's uninterpreted float functions), `Accepted::trusted_program`, the semispace ownership and page metadata (`Runtime::allocation_window`, `inline_page_metadata`, section 9) | sections 6, 8, 9 |
| The checked loop (programs not accepted; not built on devices) | `machine.rs` (plain Rust), and its raw accessors `Heap::{header, word, word64, set_word, byte, set_byte, half_word_at}` (no ghost content: the checked loop is not verified, its run-time checks keep them in bounds) | section 4 |
| Layout constants | src/layout.rs, checked against the C++ headers at build time (section 3) | |
| FFI structs and trampolines | ffi.rs plain items, `cold!`, the `*_raw` trampolines | section 2, 4 |

## 1. Memory views and the memory model (`src/view.rs`)

Stack copies for frame moves, tail calls, and exception unwinding use a verified word loop. Its contract covers overlapping ranges and preserves every stack word outside the destination.

Every view owns permissions (`vstd::raw_ptr::PointsTo`) for the VM memory
it touches, as tracked fields (erased: no run-time representation), and
its ghost content is defined from them (`view()`, `objs()`, ... are
closed spec functions of the permissions, no longer uninterpreted). A
type invariant (`#[verifier::type_invariant]`) ties each permission to
the address the accessor computes and, for the heap, its value to the
heap model. So the accessors are verified code: each read is `ptr_ref`
of the permission at that address, each write `ptr_mut_write` (in a
helper that takes a tracked mutable borrow of the permission field, so
that the type invariant is checked against the helper's contract), and
the bodies are the former trusted ones (the same pointer arithmetic,
`wrapping_add`; the instruction counts and the device code size did not
grow: PROGRESS.md, "Proven accessors").

| View | Permissions | Layout facts (the type invariant) |
|---|---|---|
| `Table<T>` | element `i` of `ptr[0..len)` | `array_ok`: in the address space, initialized; `pre` is `ptr` moved back by `PRE` elements (`at` addresses through it, so that constant negative distances fold into load offsets on Xtensa), `len + PRE` fits a word. `u16_at_even` (trusted, section 0) reads a u16 of the bytecodes with one aligned load |
| `Globals` | word `i` of the globals | `array_ok` |
| `StackMem` | the array words and the top, record-top and bci header words of the Stack object | `array_ok`, `hdr_ok`; `sid()` is the array's pointer |
| `Cursor<T>` | none (a pointer with a ghost base pointer and index) | the pointer is element `idx` of the array at `base` (`at_index`, wrapping); reads and writes take the view's permission at `idx + n`, matched by `sid() == mem.sid()` (the same array pointer, address and provenance) |
| `Heap` (`HeapMem`) | per object: its header word, an instance's fields, an array's length and elements, a double's or large integer's payload words (key: object id, word index); a string's length and hash half words (`HalfWord`: u32, u16 on 32-bit targets) and its external length and address words; a byte array's length, tag and address words; the content bytes of strings and model byte arrays (key: object id, index); the content pointer per blob; the heap's default exposed provenance and the per-object provenance for newly allocated words (`IsExposed`) | `word_val` (header: class id and the class' tag; fields; length; elements as `abs::enc`; payload words), `str_ok` (internal or external string), `ba_ok` (V5: internal, raw external at a non-null address, or opaque), the content bytes equal the model's content |
| `Heap` (`CardBytes`) | write permission for one byte per distinct writable-object card, with the card table’s exposed provenance | `card_ok` relates each permission to its physical address under the VM-supplied bias. Verified field and array stores initialize the destination byte with the mark. An object is marked afterwards exactly when it was already marked or shares that card. Array copy has the same effect for a nonempty range and preserves all marks for an empty range. |
| `Content` | none (pointer, length, object id and writability, the last two ghost) | `content_ok`: the view's pointer is the object's content pointer, which the accessors keep and a heap after a GC point does not relate to the old one |

Aligned header loads (`Table::u16_at_even`, branch core/call-speed-size):
the u16 fields of a method header (selector, receiver range; format note
21) are read with one 16-bit load instead of two byte loads, a shift and
an or (Xtensa and the ESP32 RISC-V cores have no unaligned 16-bit
loads). The function is external_body with `unsafe`: its contract says
the load yields `code[i] | code[i + 1] << 8` for an even `i` with
`i + 1 < len` in a table at an even address (`Table::even`), which is
exactly the verified byte read it replaces on a little-endian target
(`u16::from_le` makes it so on any byte order). The facts it needs are
in `prog_rel` (abs.rs): `table_ok` requires the entry of every method,
accessor and lambda to be odd (`vprog::rec_ok`; the fields lie at odd
distances before it, so at even offsets), and `p.code.even()` requires
the bytecodes to start at an even address. The loader establishes both:
`V2MethodTable::compute` rejects unaligned bytecodes and even entries
(`v2_check_header`, `V2_HEADER_EVEN_ENTRY`; proven with the rest of the
table validation, verified/cxx/annotated/README.md, and mirrored by the
spec loader `interp::loader::method_table_v2` and `vprog::x_table_ok`),
the compiler pads before such entries (`V2_PAD`, a never-executed
`RETURN_NULL`), and `toit_v2_run` re-checks the alignment of the
bytecodes before it builds the views. The load itself goes through
`pre` (`ptr - PRE`, the `Table` type invariant), so that the negative
distance of a field folds into the load's unsigned offset on Xtensa.

Tagged references: an accessor computes `obj - HEAP_TAG` and turns it into
a pointer with `with_exposed_provenance` and the heap's `IsExposed` token,
then `wrapping_add(k)`; the permission of word `k` of object `id` is at
`at_index(obj_ptr(m, id), k)`, where `obj_ptr` is that same computation
on the model's address `addrs[id]`, so the recomputed pointer matches by
the invariant (and `obj - HEAP_TAG` cannot underflow: `obj_fits`).

The derivation points are the only places where permissions come into
existence (`Tracked::assume_new` in the constructors, and the contracts of
the calls that may GC, which return a new machine whose views carry new
permissions by their type invariants). What they assume is exactly the
allocator and GC invariant: the objects of the model lie at their
addresses with these words, half words and bytes, in the address space,
and nothing else accesses them while the core runs. The C++ side states
the same facts as its object model (verified/CONTRACTS.toml, bridge
`heap`; verified/cxx/annotated).

| Derivation point | When | Permissions |
|---|---|---|
| `Table::from_raw` | `toit_v2_run`, once per run | the program tables (immutable) |
| `Globals::from_raw` | `toit_v2_run` | the globals |
| `StackMem::from_stack` | `toit_v2_run`, and `ffi::Runtime::stack` after every call that may GC | the current task's stack array and header words |
| `Heap::new` | `toit_v2_run` | the heap model's objects (the ghost state of the run loop's precondition) |
| the GC leaf contracts (section 2) and `ffi::Allocator` | after each call | the views after the call (a new machine; for the allocator one appended object, the old content pointers kept: `view::appended`) |

On the C++ side, the old-space bump allocator transfers disjoint words from
its current range. The primitive-retry path checks the returned address,
allocation accounting and remembered-set update. Free-list insertion and search
preserve the bucket chains, and flushing the active range returns and uncharges
its unused suffix. Installation of a detached region transfers its words to the
reservation and the remaining allocation window. Across flush and selection,
the accounting proof derives room for the selected extent from a bound on
charged bytes plus all chainable free bytes. The heap must establish this
aggregate bound and supply metadata for the selected address. The promotion
header and payload may share a card or occupy adjacent cards. [Free-list proofs](../cxx/annotated/heap/free_list.render) [Native allocator proofs](../cxx/annotated/heap/semispace.render)

The native metadata checks exercise host table layout, chunk commit requests
and page classification. Given the mapped mark storage and an object's valid
extent, the native whole-object marker sets precisely that extent's bits.
The proof covers either fast access mode and the slow range fill. The root visitor now proves first discovery and stack admission or overflow
recording for a supplied range. The drain proof still relies on the object
enumerator and on recovery of deferred objects. The [bitmap scan](../cxx/harness/gc_overflow_byte.cc)
preserves overflow flags raised during traversal. A [registration check](../cxx/harness/gc_overflow_registration.cc)
follows two native overflow registrations through group dispatch with existing
flags and valid starts. Both objects are in the delivered intervals, including
when the second registration shares a card with earlier work.
The [registration sequence proof](../cxx/annotated/heap/page_scan.c)
covers arbitrarily many registrations between scans. For every card, the
production update retains the earliest known start and preserves all its
pending work in the overflow byte.
The [card walk](../cxx/annotated/heap/overflow_card.render)
checks each object in the recorded interval given the heap partition,
and the [size dispatcher](../cxx/harness/gc_object_size.cc) checks its
extent given valid headers and class metadata. For a discovered one-word
object, its first mark covers the whole object and its native enumerator
has no outgoing slots, regardless of the adjacent object's mark.
For a format-2 stack that shrinks during marking, the [shrink check](../cxx/harness/gc_stack_shrink.cc)
uses the collector's size and sentinel tests to verify that the retained
stack and one-word fillers end exactly at the original successor. It
assumes a valid initial stack, the libc move contract and the pointwise
fill contract. The [format-2 scanner entry](../cxx/harness/gc_stack_scan_entry.cc)
checks the stack guard before dispatch and uses the post-shrink live bounds
and the exact bytecode table interval. The host snapshot [layout check](../cxx/harness/snapshot_image_layout.cc)
bounds external tables within the page-rounded image prefix. The [byte-table
reader](../cxx/harness/snapshot_bytecode_slice.cc) publishes the exact
snapshot slice or records failure. The [host image backing check](../cxx/harness/image_backing.cc)
follows the aligned malloc grant through publication, POSIX page protection
and release. Given a movable object in separate storage, its tagged reference
lies outside the entire published image. The proof relies on libc and the OS
providing disjoint live allocations and successful protection calls.
The [group lifetime check](../cxx/harness/process_group_lifetime.cc) covers
registered members and pending process destructors. The [scheduler exit
check](../cxx/harness/scheduler_teardown.cc) follows a peer exit during the
unlocked destructor and checks that the group survives through notification.
The [spawn check](../cxx/harness/scheduler_spawn.cc) covers allocation failures
before registration and notification ownership after admission. The [target
selection and barrier check](../cxx/harness/scheduler_gc_barrier.cc) covers
overlapping collectors, late acknowledgments and a spurious wakeup. The
[collector check](../cxx/harness/scheduler_gc_scan.cc) runs native selection,
scanning control flow and resumption for a single registered target.
Repeated wakeups during the modeled heap scan keep the target off the
ready queue until release. The [ownership check](../cxx/harness/scheduler_gc_ownership.cc)
checks one lock-serialized step from each collector-owned state, including
reprioritization, a competing claim and release with a pending wake.
For an arbitrary finite queue of claimed targets, the [target traversal
proof](../cxx/annotated/heap/scheduler_targets.render) establishes termination,
one scan per entry in queue order and an exact count. Cleanup empties the
queue and resumes exactly the entries outside the barrier-waiter state.
The same proof follows all group and membership links under the lock. Given
well-formed lists and the per-process claim contract, it constructs exactly
the admitted subsequence in visitation order. The [worker-list proof](../cxx/annotated/heap/scheduler_workers.render)
checks which running processes receive preemption requests and the count
used to wait for acknowledgments. For a fixed worker list, induction over
lock-serialized returns in any order proves that the count equals the number
of outstanding worker marks until timeout. Only the return that clears the
last mark broadcasts. A timeout leaves the counter at zero as late workers
return, and a new request replaces any remaining marks. The [worker handoff check](../cxx/harness/scheduler_worker_handoff.cc)
follows a dequeued sandbox process through barrier entry, interpreter
binding, execution outside the lock, unbinding and result routing.
It includes a barrier waiting for a different worker and a preemption
request during execution. In the checked timeout schedule, collection
finishes while the interpreter is still bound and skips its heap. In the
waiter schedule, an eligible heap is visited with both worker bindings
cleared and the process suspended. A dispatch skipped for pending signals consumes
no preemption sample from the previous process. The interpreter body and
OS synchronization use contracts. Profiler sample aggregation remains
outside this check. The [native list check](../cxx/harness/scheduler_target_queue.cc)
checks the concrete cursors, priority-to-bucket mapping and independence of
membership and target links. Given a ready count consistent with all five
queues, the [dispatch proof](../cxx/annotated/heap/scheduler_ready.render)
returns the detached head of the highest-priority nonempty queue, preserves
all other entries and leaves the count equal to the new total. Connecting
these traversals across concurrent scheduler operations
still requires the OS synchronization contracts and a global invariant
for list ownership and process state. Outstanding image accesses must
finish before destruction returns. Shutdown also relies on joining workers
before draining groups.
The [marking loop proof](../cxx/annotated/heap/mark_process.render) establishes
termination over a finite heap under the discovery and card-scan contracts.
The [collection-phase check](../cxx/harness/gc_collection_phases.cc) verifies
the ordering of marking, finalizers, pointer updates and mark-table clearing
for both sweeping and compaction. The [compaction tail check](../cxx/harness/gc_compacted_chunk_tails.cc)
runs the native old-space cleanup with up to two independently sized chunks.
Empty chunks are detached before release. Each retained chunk stays in order,
contributes its unused payload up to the sentinel to the free list when nonempty,
and resets both metadata tables from the card boundary following its last live word.
The check assumes valid compaction tops and models page release, free-region
headers, and the two metadata reset calls. The [destination planning check](../cxx/harness/gc_compaction_destinations.cc)
runs the preceding native planning loop for up to two chunks. Given the per-source
planner's cursor contract, it checks each published live end, resets unused
destinations to their starts, and verifies the signed reclaim estimate.
The [forward scan check](../cxx/harness/gc_compaction_scan.cc) observes one
iteration of the production loop from an arbitrary aligned cursor. For every
mark word it checks the published destination, the exact advance in live
bytes, and both metadata pointers. An overshoot enters rollback even when the
source cursor is at its end. The input must leave room for the live-byte sum
in a machine word. The [object-start check](../cxx/harness/gc_metadata_access.cc)
writes and decodes a start for any aligned word of the mapped heap.
The [object-end check](../cxx/harness/gc_compaction_object_ends.cc) follows two
variable-size objects whose mark states are independent. For a supplied
size lookup, it checks both ends of the last live object starting before
the limit, including when its body crosses the limit, and preserves an
optional output when no live header qualifies.
The [last-fitting-card fixture](../cxx/harness/gc_compaction_last_fit.cc)
runs the native search across three cards with two instances and an array.
The fixture reads the instances' sizes from the image and the array length
from its header. The symbolic search checks the address on each read and
uses the size, liveness, destination, and sentinel values measured by the
native accessors before the read-only walk. The fixture checks each object's liveness independently,
including exact fits, dead objects that exceed the remaining capacity,
and reaching the chunk sentinel.
The [per-card destination check](../cxx/harness/gc_compaction_card_rank.cc)
covers every mark pattern. Given a cumulative base for a card, the first
word maps to that base and each marked word advances the next destination
by one word. At the start of the subsequent scan, the [compaction sentinel
check](../cxx/harness/gc_compaction_sentinel.cc) verifies that the visitor
requests a reset of all object-start entries and sets the final sentinel's
mark bit while preserving the other marks. When backtracking reaches the
first source line, the [chunk switch check](../cxx/harness/gc_compaction_switch.cc)
runs the production branch for arbitrary disjoint page-aligned chunks and
an aligned cursor at or below the usable end. If the cursor precedes the
chunk, the branch publishes an empty chunk and carries the exact difference
into the successor. When initializing that bias, the planner subtracts only
the part of the last live object extending beyond the resumed source line.
The arithmetic check assumes the distance between the two ends fits in a
signed int and the successor has a representable biased address. On hosts,
the page allocator limits a chunk to 64 pages.
The [overhang fixture](../cxx/harness/gc_compaction_overhang.cc) runs the native
planner over three source cards with two live objects, a modeled size lookup,
and one skipped destination. It has a verdict only on ILP32: on LP64 the model
checker gives no verdict (verified/cxx/annotated/README.md, "No verdict").
General object layouts and arbitrary-length sequences of destination switches still require verification. The low-level marking and layout models must still agree throughout an
actual collection. The [compaction root walk](../cxx/annotated/heap/fix_roots.render)
proves termination for any finite initialized root range. With stable
page classification and aligned, representable destinations for old roots,
it rewrites each old reference to its tagged destination and preserves every
other slot. The [object move proof](../cxx/annotated/heap/object_move.render)
covers any positive number of aligned words with representable endpoints.
It copies the original source values to disjoint storage on either side, or
to an overlapping range starting below the source. Only the source words
need to be initialized. The source suffix outside an overlapping destination
retains its original values. The caller must supply these ranges and their
ownership. The [live visitor check](../cxx/harness/gc_compaction_live_visit.cc)
follows a marked three-word object through the native caller. The modeled
root callback checks its program, visitor, and destination, sees all three
copied words, and observes the published start and remembered-card byte
before the live-byte count advances. The cases cover staying in place,
overlapping on the same card or across a card boundary, and disjoint
storage. A second run takes an exact fit in a third chunk after skipping
a short remainder and an empty chunk. The
[dead visitor check](../cxx/harness/gc_compaction_dead_visit.cc) covers any
first following live bit across four source cards, including the sentinel,
and checks that skipping garbage preserves the destination and byte count.
The [native root check](../cxx/harness/gc_compaction_fix_roots.cc)
exercises mixed roots, repeated references, and selected subranges using
the real page classifier and destination lookup. The [process root enumeration proof](../cxx/annotated/heap/process_roots.render)
establishes termination and exact callback order for the task, globals, and
arbitrary finite external-root and notifier lists. It assumes well-formed
forward links, a valid global table, and a terminating visitor that preserves
list topology. [Native process](../cxx/harness/gc_process_roots.cc) and
[list checks](../cxx/harness/gc_root_iterator.cc) cover concrete field addresses,
the table count, cursor steps, and local prepend/unlink behavior.
The [current-task relocation check](../cxx/harness/gc_current_task.cc)
follows the mutable process root through the native task scanner to the
stack field. It supplies a two-field task and independent forwarding
choices for task and stack. Selection and copying of their destinations
remain assumptions of this check.
At format-2 GC and primitive entry, the [dispatch proof](../cxx/annotated/ffi/interpreter_v2.render)
requires a write barrier on the current stack. A primitive retry reloads
and remembers the stack after collection. The [native barrier check](../cxx/harness/gc_stack_barrier.cc)
checks the exact dirty-card byte under the installed table mapping. The
[process-heap epoch check](../cxx/harness/gc_process_epoch.cc) verifies one
epoch increment before the heap lock is released for every collection kind,
including word wraparound. The scheduler still supplies the number of
collections per call and the collector's state-preservation guarantee.
For a word-aligned object extent that fits an int and has initialized bytes, the [scavenger
clone proof](../cxx/annotated/heap/scavenge_clone.render) checks that a
successful copy retains the original representation and installs a forwarding
pointer in the source header. Both specializations use the checked C++ allocator
contracts. The young copy leaves a sentinel after its destination. The old
copy carries the bump-window and metadata updates through to the caller.
The [old-space chunk installation check](../cxx/harness/old_chunk_install.cc) covers the header’s dirty card and object-start entry across attachment and installation.
The source extent, the incoming free-list and metadata invariants, new-chunk allocation, and libc copying
still supply contracts. The [native alias check](../cxx/harness/gc_scavenge_alias.cc)
covers repeated references, promotion failure and remembered-card updates
for a three-word survivor. The [root range proof](../cxx/annotated/heap/scavenge_roots.render)
covers the single-slot helper and every length of a valid slot array. It checks
ordered relocation, alias reuse, remembered-card writes and promotion-failure
requests. Both clone implementations establish that a successful copy writes a
tagged destination to the source header. The visitor reads that header and
preserves every other source header across a copy. The two native membership tests
use the cached chunk bounds and exclude tagged integers from the source space. The proof requires an
inventory of live source objects, valid roots, valid chunk descriptors, sufficient
young-space capacity and allocator contracts for storage and destination space.
The visitor builds its relocation map from the actual copy results. Exclusive
ownership of the copied headers gives distinct destinations for distinct copied sources. The [two-instance graph check](../cxx/harness/gc_scavenge_graph.cc)
connects the C++ root visitor, young allocator, forwarding headers and destination
scan. A root points to the first instance. Each instance's single field can point
to either instance or hold a tagged integer. The check covers all nine graphs,
including a cycle and an unreachable neighbor. Only reachable instances get a
copy, each surviving edge points to the corresponding copy, and the scan ends
at the allocation sentinel. The fixture supplies the single-field layout,
disjoint two-word copy, and chunk metadata contracts. Promotion, finalization
and arbitrary graph sizes remain outside this check. The [scavenge drain proof](../cxx/annotated/heap/scavenge_drain.render)
establishes that the alternating scan finishes with no queued work in either
space. The [native finalization phase check](../cxx/harness/gc_scavenge_phases.cc)
checks that ordinary roots and remembered edges drain before callback decisions,
revived work drains before VM finalizers, and remaining work drains before tracking
ends and survivor bytes are deducted. Root enumeration, list processing and the
two space scanners supply contracts here. Each modeled drain admits new old-space
work and one return of work from old to young space. A separate [ordinary callback
check](../cxx/harness/gc_callable_finalizer.cc) follows one registered Toit
finalizer through the real young-space liveness test, both FIFO walks and callback
delivery. An inactive registration is discarded. A live key and its closure are
visited. A dead active key loses its finalizer bit and its queue entry retains
only the relocated closure, which can be delivered once. The root callback
models relocation. The [VM finalizer check](../cxx/harness/gc_external_finalizer.cc)
follows one successfully registered external object through collection and
heap shutdown. It checks that live keys can move, that transferred bytes are
left with their recipient, and that freeing owned bytes refunds exactly their
live charge. Strings include their terminator in that charge. Null-backed
and mapped-file arrays trigger no libc release. The check models liveness,
header relocation and the payload allocation. Mapped-file reclamation itself
remains outside this path. The drain proof includes both the old-space walk of promoted tracks and the
young-space walk of destination chunks, including newly appended chunks.
The progress measure counts the bytes remaining past each young scan cursor,
the occupied old-track payloads, the unused old allocation window, free-list
storage and an external reserve. Short tails returned as fillers keep their
accounting across an empty pass. The drain calls the verified free-list flush
with the actual track end field. Enabling tracking preserves available capacity
when the mutator window is flushed. The last pass leaves the physical track
head null, as required when disabling tracking. Flushing trims the current track to its
occupied extent and conserves the measure. Old-space scanning accounts for
a whole detached payload once. The root visitor still supplies the object
partition and preservation of pending work. Its allocations must respect
the combined capacity, including when new chunks are installed. The native [chunk iterator check](../cxx/harness/chunk_iterator.cc)
covers advancing an existing cursor after a new tail is linked. A separate
[native insertion check](../cxx/harness/gc_chunk_insert.cc) covers old-space
insertion with zero to two existing chunks. It checks that traversal retains
each descriptor once, in size and address order, and gains exactly the new
extent. It assumes allocated, disjoint pages and models owner assignment
without its metadata writes. The [host chunk lifecycle check](../cxx/harness/gc_chunk_lifecycle.cc)
covers arbitrary host-word byte requests. It checks that zero and
unrepresentable rounded extents return before any reservation, and that the
same whole-page extent is reserved, recorded, initialized, charged, and
released. The modeled host allocator can admit one to 64 pages. The check
includes page and descriptor allocation failure.
The [FreeRTOS admission check](../cxx/harness/freertos_chunk_admission.cc)
uses 32-bit words and 4 KiB pages. It verifies the native whole-chunk range
predicate against widened arithmetic for every candidate start and byte count
in a representable metadata mapping. The loop check models that decision
and covers every possible index of the first accepted or null reservation
and rejection of all 50 offers. It checks each range query's arguments,
the rounded request and ordered release before handoff. If all 50 reservations
fall outside the mapping, every one is released and the caller receives
allocation failure. Only an accepted reservation reaches the descriptor
helper. The check models the page provider and descriptor helper.
The FreeRTOS variant of the chunk lifecycle check runs the real range test,
retry loop, descriptor allocator helper, metadata initialization and retirement
in one harness. It admits every page-aligned position and length in a
64-page mapping. An optional rejected reservation precedes the accepted
block or a null result. The check observes its release before descriptor
allocation and verifies the exact mark and cumulative-mark slices, including
the mark lookahead byte. Device page allocation, metadata commits and libc
fills are modeled.
The [device page backend check](../cxx/harness/device_page_backend.cc)
verifies the ESP32 and EC618 OS wrappers separately, using their production
function bodies. For positive byte requests with representable rounded sizes,
both pass 4 KiB alignment and the exact rounded size to their allocator.
The tagged allocation path restores the prior thread tag on success and
failure. On EC618 it also checks the allocation result and tag restoration
when the caller has no task handle or the tag table is full. A missing tag
affects allocation reporting. GC admission uses the address range.
ESP32 selects heap and metadata RAM capabilities independently.
Both return the metadata allocator's result, report success when asked to
commit metadata, and pass the original allocation to the release function.
The SDK and libc allocators supply contracts. On EC618, the
[thread-tag check](../cxx/harness/ec618_thread_tags.c) exercises the SDK tag wrappers, allocator
option setter, lookup and scheduler-lock wrappers over all 16 slots. From a
table with canonical empty slots and a unique entry for the caller, clearing
a tag releases its slot. Setting a nonzero tag updates the existing slot or
takes the first empty one. A full table drops a new task's tag, so exact tag
installation requires capacity. The SDK wrapper can tag a task before heap
registration. Task identity, task-handle lifetime, single-threaded boot and
FreeRTOS scheduler suspension still supply contracts.

The [ESP32 heap range check](../cxx/harness/esp32_heap_range.cc) verifies
selection of the GC heap and metadata RAM across the six supported SoCs.
It checks internal and external RAM configurations, the original ESP32's
revision threshold with and without the cache workaround, and the P4's
cache reservation. Both flags reflect the current selection even when
initialization starts with stale flags. The selected range uses the bounds
from the accepted external probe or the internal query. Missing internal
bounds select the SoC's DRAM limits with the configured P4 cache excluded.
SDK heap queries supply ordered bounds when present. Chip revision and cache
size are inputs, and firmware logging is omitted from the check.

The [ESP-IDF range aggregation check](../cxx/harness/esp32_heap_aggregation.cc)
runs the SDK's heap capability filter and statistics aggregation over empty,
one-node and two-node registries. For arbitrary 32-bit capability masks it
checks exactly which live heaps are queried and the minimum and maximum
reported addresses. The first matching range can have arbitrary extrema,
so the two-node case also exercises merging an existing range with the next
report. The allocator either supplies ordered bounds for each heap or omits
bounds throughout. The check uses a stable list and untagged byte accounting.
Per-heap statistics, longer list traversal and concurrent registration remain
outside its scope. The SDK compares integer addresses across heap regions.

The [EC618 heap range check](../cxx/harness/ec618_heap_range.cc) exercises
GC range discovery and the allocator wrappers against the same linker symbols.
The native board initialization computes the linker extent using integer
addresses and publishes the handle returned by registration. The check
covers a failed registration followed by a retry, reuse of a published
handle, and another task finishing registration before scheduler suspension.
Malloc, realloc, memalign and free reach the corresponding allocator only
with a published handle. Freeing null skips initialization. An empty or
reversed linker extent yields zero bytes and skips registration.
The GC derives its range from the whole pages inside the linker interval,
independently of allocator initialization. The check proves exact containment
for any aligned, positive whole-page chunk. Heap diagnostics still read the
allocator statistics.

*Unchecked linked-image results.* The passages below that mark a check
*(unchecked)* (here, and in the memmove, metadata-fill, scheduler, thread
and mailbox passages further down) report one-time runs of scripts that
disassembled particular EC618 base and slot ELFs. Those images are not in
the repository (they come from an EC618 build with the vendor SDK, which no
gate does) and the scripts were removed on 2026-11-24 (no Python in the
repository), so nothing checks these results any more: each is a recorded
observation about one firmware build and is trusted, and a new base or slot
build has none of them. The SMT models those scripts ran
(`../cxx/annotated/heap/ec618_*.smt2`, linked below as proofs) are still
checked by the C++ matrix (`run.sh ec618-smt`), but only as models: that a
model is the linked Thumb code is part of the unchecked result. See the
[annotated README](../cxx/annotated/README.md#ec618-linked-image-results-unchecked).

For the final format-2 slots linked against base-v5 fingerprint
`f0ae7c907be49d8af02ea2dbcfa6aecf`, the GC range check *(unchecked)*
binds the two range literals to the base linker symbols. It compares the
compiled rounding with whole-page containment for arbitrary 32-bit endpoints.
Both builds cover 85 pages in `[0x443000, 0x498000)` and pass 28,672 bytes
to base malloc for metadata. Given a non-null, writable, word-aligned grant
of that size disjoint from live state, six disjoint tables occupy its first
27,648 bytes. The check follows the four commit calls and the page-type
zero fill, verifies the five published bias fields, and checks the byte or
aligned-word lookup formulas for every address in the linked heap range.
On normal return from initialization, setup
copies all 19 descriptor words from private stack storage into the singleton.
This assumes serialized setup, ordinary stack storage and callee contracts.
For this same base the registration check *(unchecked)*
binds the initialization flag and heap pointer to their linked writable globals.
The page allocation check *(unchecked)* follows the
metadata request through malloc into the registered arena. For any stable
page occupancy it checks that the allocator returns the first seven contiguous
free pages and zeroes them, or returns null if no such run exists. This relies
on writable arena RAM, serialized heap publication, and exclusive access with
accurate ownership recorded in the page descriptors. Maintaining those
conditions across all allocator clients and checking all GC lookup callers
remain open. The allocator ABI check *(unchecked)* also passed on this base (11 CBMC properties).

The linked teardown check *(unchecked)*
covers both slots and this same base. When initial spare-chunk allocation
fails, object-memory setup releases the metadata. When mutex allocation fails,
it frees the spare chunk first. Normal teardown also frees the spare before
releasing the metadata. The linked chunk check *(unchecked)*
follows the spare allocation through the page-aligned request, range filter,
bounded list of 50 rejected grants, and cleanup of that list. Widened arithmetic
checks the complete accepted byte interval. For the null-space spare, descriptor
allocation has a null-result cleanup branch in the slot. The linked base’s
nothrow new forwards to ordinary new, which retries malloc after a returning
new-handler and calls abort when no handler exists. Its ordinary return
therefore supplies a non-null pointer. Success installs the start and exclusive
end and adds the rounded size to the atomic counter. On destruction the linked
code subtracts that extent, clears the corresponding page-type bytes, and
passes the page grant and descriptor separately to base free, in that order.
This requires intact, disjoint live allocations, the allocator and mutex
contracts, ARM exclusive-access semantics, and a nonreturning fatal-error routine.
For a live, nonempty, page-aligned chunk inside the configured heap range,
the linked allocation and owner-change paths classify the chunk using the
owner’s page-type byte. With a non-null owner the fill proof *(unchecked)*
checks every memset destination, length and fill value. It clears the chunk’s
marks, overflow bits and remembered set, and writes 2 to its object-start
entries. Clearing ownership sets the chunk’s page type to zero.
The space append check *(unchecked)* follows
owner assignment before inserting the chunk. Given a valid exclusive ring
and a detached chunk, semispace append preserves traversal order and places
the chunk last. Ordinary space insertion preserves size order and breaks ties
by start address. The semispace constructor initializes an empty ring; with
an initial chunk it sets the allocation top to the chunk start, writes a
zero-word sentinel there and sets the limit to the chunk end. These checks
assume valid writable chunk, space and metadata storage.
The linked scavenge swap check *(unchecked)*
follows the handoff after copying into a one-chunk temporary semispace. It
checks that the outgoing chunk becomes a detached spare with unknown page
type, while the persistent semispace takes the survivor, its top and its limit
without reinitializing survivor metadata. Both collection paths publish the
returned chunk to their respective shared or private spare. Destruction of
the emptied temporary space skips chunk release. The watermark proof binds
the virtual used-size call to the semispace implementation and checks both
promotion thresholds. This requires exclusive, distinct chunk storage, valid
space rings, an intact semispace vtable and a valid survivor allocation top.
The linked scavenger copy check *(unchecked)*
follows the root visitor, semispace allocation, and word-aligned base memcpy.
For a positive word-aligned true object size and a disjoint live grant, every
destination word receives its original source value before the source header
is replaced with the tagged destination. The semispace sentinel fits and
remains zero. A subsequent root pointing at that source reads the forwarding
header and reuses the same destination. The check follows the old-space
promotion call and young-space retry, assuming the old allocator returns
a valid grant or null. If young space runs out, the release root visitor
can publish a null result. The
[copy proof](../cxx/annotated/heap/ec618_scavenge_copy.smt2) checks the
single-copy capacity step. The [capacity proof](../cxx/annotated/heap/ec618_scavenge_capacity.smt2)
derives its initial budget for a single well-formed source page: even if every
object survives, the sum of their disjoint extents leaves room for the sentinel
on an empty destination page. The linked capacity check *(unchecked)*
checks the one-page requests at heap and spare initialization, selection of a
private or shared spare (including allocation failure), and the chunk bounds
passed into both visitors. Applying the bound to every collection still
requires valid chunk ownership throughout the heap lifetime, a source top
with room for its sentinel, true disjoint object extents, and valid root
slots. The linked object-size check *(unchecked)*
follows the fixed-size instance, array, internal byte-array, internal string,
stack, double and large-integer constructors
and the corresponding size reads in the collector. The
[extent proof](../cxx/annotated/heap/ec618_object_extent.smt2) shows that a
fresh object from each of these paths reports its allocated size on a
successful young allocation. It assumes a valid, stable class table with
representable class IDs and the expected class descriptors. Stack and string
lengths must satisfy their constructor preconditions.
The external descriptor check *(unchecked)*
follows external string and byte-array construction, finalizer registration,
and external byte-array resize and detach. The
[extent proof](../cxx/annotated/heap/ec618_external_extent.smt2) checks the
16-byte GC size, including when the finalizer flag changes, a resize fails,
or detaching leaves a zero-length external descriptor. This assumes valid
variable-size class entries, nonnegative lengths, disjoint backing storage
of the required size, and valid queue links. The accounting writes target the
separate process heap counters. The allocator must preserve the descriptor. Extending the
result through subsequent mutations, covering the other object layouts,
and tracing the entire reachable graph remain open.
The linked root traversal *(unchecked)*
follows each copied or promoted object into its type-specific scanner. Arrays
visit each element, instances and tasks visit each payload word, and leaf
tags return immediately. The scavenger's vtable disables both weak marking
skips and stack shrinking. For a valid stack in either bytecode format, the
[slot proof](../cxx/annotated/heap/ec618_object_roots.smt2) counts one visit
for every live slot whose value lies outside the program bytecode interval.
It also checks retirement of the three-word promotion descriptor and bounds
each promoted-object step by the end of its track. These results require
valid object partitions, stable unvisited fields, well-formed stack bounds,
a correct bytecode interval and valid promotion tracks. Establishing these
conditions for every collection and seeding every reachable root remain open.
The linked process-root check *(unchecked)*
binds the task, global table, external-root ring and notifier ring to their
actual callback arguments in each slot. It follows the remembered-set call
and all three drains, including the drain after runnable closures are visited.
For ordinary callable finalizers it binds the virtual methods for forwarded-key
liveness and callback processing. Removing a dead active registration clears
its key and visits its closure before appending the node to the runnable FIFO.
The [queue proof](../cxx/annotated/heap/ec618_process_roots.smt2) checks the
keep, delete and move steps, including removing the last registration and
appending to an empty queue. This assumes finite valid root and queue lists,
disjoint storage, an accurate from-space partition, and callbacks that preserve
unrelated links. Complete root registration, remembered-set coverage and the
other finalizer implementations remain separate obligations at the linked level.
The linked remembered-set check *(unchecked)*
follows old-space card scanning, the ordinary instance-field write barrier,
and the start byte published by a successful old-space bump allocation.
The barrier dirties the card containing the object's header, including when
the field lies on a later card. The [scan proof](../cxx/annotated/heap/ec618_remembered_scan.smt2)
checks the four-card zero-word skip, backward lookup of a safe object
boundary, and exact visitation of an arbitrary object starting on a dirty
card. With successful relocation the rebuilt byte retains each resulting
young reference. This requires disjoint live tables, page-aligned chunks, a
valid object partition through the sentinel, and accurate nonempty start
entries. Slots containing a reference to the new destination before their
visit must already be accounted for in that card's record. Coverage of
every mutator store and preservation of these premises through sweeping and
compaction remain open.
The linked small-block allocation check *(unchecked)*
checks rounding and first-eligible-bucket lookup for the small malloc route.
Given an accurate bitmap and correctly classified live free blocks, the selected
head fits the request. On a split the remainder still ends at the original
right neighbor, whose left boundary tag is repaired. Both split and unsplit
paths clear the rounded payload in four-byte steps within the new allocation.
For a 28-byte descriptor that is 32 cleared bytes. This base uses the rounded
size as its loop bound even when the allocation retains extra space, so that
extra space has no zero-initialization guarantee. The source-harness result
below applies to the workspace implementation, which clears the full usable
payload. The removed GC range check also ran the base scheduler proof
*(unchecked)*. The port startup
check *(unchecked)* follows successful
scheduler initialization through the priority and timer register writes,
the linked exception stack, and SVC. It binds the hardware SysTick vector to
the checked kernel tick and its conditional PendSV request. On EC618's
three-bit priority configuration both SysTick and PendSV have priority 7,
so BASEPRI 0x20 masks both during kernel critical sections. Between those
sections the heap lock relies on scheduler suspension to defer task switches.
This requires the application vectors to be active, the documented Cortex-M
exception semantics and priority grouping, a valid current task, stable port
configuration, and no interrupt-side allocator mutation. The linked allocation
tag lookup reads the current task handle and checks up to 16 entries in the
linked tag table. It returns the first matching tag, or zero for a null handle
or missing entry. The linked tag-update check *(unchecked)*
follows the VM get/set wrappers and confines setter stores to that 128-byte
table, disjoint from the registered arena and GC singleton. A serialized
setter updates the first matching slot, otherwise uses the first empty slot,
and drops a new task’s tag when full. This base skips the setter before heap
initialization, retains a task’s slot when its tag is cleared, and performs
both scans without acquiring the scheduler lock. The source-harness result
above applies to the workspace implementation. Per-task attribution in the
linked firmware still requires capacity for new entries, serialized updates,
and stable task identity.
The footprint check allows the two scans to observe different slot contents.
The linked small-block release check *(unchecked)*
follows small-block dispatch into the coalescer. Given live consistent boundary
tags and valid free-list helper contracts, all four combinations of neighboring
free blocks select exactly the contiguous extent to merge. Repairing the
following boundary tag preserves its allocation flag and own block size.
The code tests page alignment and both sentinel tags before handing a whole
arena back to the page allocator. The linked bucket check *(unchecked)*
checks size-class selection for every supported aligned block size below 16 KiB.
It follows head insertion and removal at the head, tail, middle, or sole node,
including neighbor links, counters, and the occupancy bit. Given exclusive
access, a well-formed bucket and a valid node to insert or remove, the
[list proof](../cxx/annotated/heap/ec618_free_buckets.smt2) preserves the
traversal order of every retained node for arbitrary list lengths.
The [arena return proof](../cxx/annotated/heap/ec618_arena_return.smt2)
checks the removal of a fully coalesced, page-backed arena from a valid
circular list, including the sole-arena case. The allocator passes the
original page base with the arena ownership flag and restores the 24 bytes
of ring and sentinel overhead. The linked page release check covers arena
and ordinary heads at every registered position and extent. With accurate
page descriptors, an aligned small-block payload strictly inside an arena
lies on a continuation page. Payloads strictly inside either registered
edge fragment cannot be page-aligned. These facts justify small-block
dispatch for allocations with this provenance. Preserving that provenance,
the arena ring, and descriptor ownership across all allocator clients remains open.
Metadata teardown
saves the grant pointer and size, clears the first 18 singleton words, preserves
the heuristics word, and tail-calls the release wrapper. A subsequent serialized
metadata teardown sees a null pointer and returns. For a live ordinary allocation
with valid descriptors, base free clears exactly its status words and credits
the released extent, including allocations at either arena edge.
The historical EC618 allocator checks used the ELF named `ec618-base-v5.elf`
whose manifest reports base version 4 and fingerprint `b11a03ffa2790e3009abc87587810b4b`.
For that ELF, the allocator ABI check *(unchecked)*
follows the actual Thumb instructions from the libc entries to the board
wrappers. The aligned allocation used for GC pages passes its alignment and
size to `pvPortMemalign`. Metadata malloc passes positive sizes through and
requests four bytes for zero. Realloc forwards the original pointer and
size. Free returns immediately on null and passes other pointers to
`vPortFree`. All tail calls preserve the incoming return address and stack
pointer. The [instruction model](../cxx/annotated/heap/ec618_allocator_abi.c)
assumes a valid private caller stack, readable firmware literals and newlib
reentrancy pointer storage. The Thumb semantics are reviewed and each base
ELF requires its own check. Nothing runs that CBMC model now: it includes
the instructions extracted from the ELF, which the removed script wrote.
The scheduler model assumes single-threaded boot and task exclusion during
suspension. Allocator registration, allocation operations and the accuracy of
per-heap statistics remain contracts.

The [EC618 arena layout check](../cxx/harness/ec618_arena_layout.cc) verifies
the size and address calculations in cmpctmalloc registration over all 32-bit
base addresses and sizes. A 64-bit reference calculation checks rejection,
aligned metadata placement, usable whole pages and room for every page-table
entry including the sentinel. A second check follows the production branches
that pass leading and trailing fragments to the small-allocation arena and
checks each address and length. Registration requires a nonzero base, offsets
within the signed address-difference limit, and representable aligned
addresses. The GC range covers the allocator’s complete usable page span.
For linker heaps up to 1 MiB its span fits within the previous outward-rounded
statistics range, including on a heap with unaligned linker symbols.

The EC618 page-table initializer has a VeriFast loop invariant over an
arbitrary number of writable entries and a separate writable sentinel.
It establishes that each usable entry is free with a null tag, and that the
sentinel is in use with a null tag, including for an empty arena page set.
The [registration header check](../cxx/harness/ec618_arena_init.cc) verifies
that the caller passes the flexible array and page count to that initializer.
It checks the installed address bounds, initial byte and block counts, empty
arena list and allocator flags before fragment insertion. It checks the two
zero-fill calls cover their entire bucket and bitmap arrays. The memory
writes of those calls rely on the C library memset contract.

The [registration fragment check](../cxx/harness/ec618_fragments.c) runs
`cmpct_init` followed by zero, one or two native `add_to_heap` calls. The
layout check establishes that each supplied extent is aligned, large enough
for the two sentinels and a free block, smaller than a page, and disjoint
from metadata and whole pages. For independent writable fragments the
insertion check verifies both sentinels, the interior free block, the entire
arena ring, bucket heads and bitmap, and byte and block accounting. When
the two fragments share a size class, it checks both directions of their
free-list links. CBMC models the two zero fills as compiler builtins.

For any registered EC618 page count, VeriFast checks the production
`page_statistics` loop by induction. From read permission for the page
statuses, it proves the longest contiguous free run in bytes and the exact
number of direct allocation heads. It returns the same read permission and
reads only usable entries. The page count bounds the multiplication by page
size and the number of heads.

The [EC618 report check](../cxx/harness/ec618_stats_report.c) uses those
two results to verify `cmpct_get_info_impl` for any registered page count
and any highest occupied bucket, including an empty bucket table. It checks
the reported block and byte counts, address bounds, lock calls and the
small-block estimate used when no page is free. The scan requires a stable
readable page table. Reporting assumes a valid highest bucket head, accurate
allocator counters and representable totals. The
[combined statistics check](../cxx/harness/ec618_stats.c) also runs the scan
and report together on every status pattern through four pages, with up to
two small blocks. It computes the expected result by scanning backwards.

The EC618 page allocator's `first_free_page_run` has a VeriFast proof for
every registered table size. It returns the earliest start whose address
matches the alignment mask and whose entire requested run is free, or
`SIZE_MAX` exactly when no such start exists. Its loop terminates and
restores read permission for the original status table. The proof covers
skipping a partial run: no candidate through the first occupied page can
fit. A separate lemma compares the selected start with any admissible
candidate.

The [page allocation accounting check](../cxx/harness/ec618_page_alloc_commit.c)
uses that selector contract, the proved status fill and the word-clear
contract for every registered page count. For a successful allocation it
checks the returned address, tagged head, continuation range, cleared
extent, byte charge and free-run count. A symbolic observer checks any
descriptor including the sentinel. A failed request preserves the counters
and observed descriptor. This assumes an exclusively owned heap, valid
descriptor storage, a representable page-aligned region, power-of-two
alignment, and consistent initial accounting. The
[combined native check](../cxx/harness/ec618_page_alloc.c) additionally
executes the selector and descriptor writes together for every page-status
pattern through four usable pages, using an independent reverse scan.

The [EC618 page release check](../cxx/harness/ec618_page_free.c) verifies
address-to-index conversion and excludes the page-table sentinel from usable
addresses. The VeriFast proof of `release_page_run` starts at a matching
head and derives its extent from the following status words. With a readable
non-continuation sentinel, it terminates for every registered run length,
frees the head and exactly its continuation prefix, preserves the rest of
the table and leaves tags untouched. The
[page release accounting check](../cxx/harness/ec618_page_free_commit.c)
uses this contract to check `page_free` for all registered page counts and
all addresses. It checks head kind, restored bytes, the new free-run count
for either or both free neighbors, every tag and status, and preservation
of the table and counters on rejection. These checks assume stable metadata,
a readable table through its sentinel, and representable total counters.
The combined check also runs public dispatch and the native loop together
through four usable pages with modeled locking, fatal termination and
small-block delegation.

The [page accounting history proof](../cxx/annotated/heap/ec618_page_accounting.c)
starts from the production initializer's free descriptors. It proves that
the byte and run-count changes checked for allocation and release agree
with recounting the resulting table after any finite sequence of valid
extent changes. The page contributions remain representable throughout a
registered region. An extent change must replace a nonempty free interval
by occupied pages or vice versa without changing its length.

The [page extent history proof](../cxx/annotated/heap/ec618_page_extents.c)
establishes those accounting preconditions for any finite sequence of
reservations of free pages and releases at a matching live head. Starting
with the initializer’s free table, it proves that each reservation publishes
one direct or arena head with the requested page count. A release derives
its length from the same continuation-prefix definition as the native size
query and release routine. It removes that head and preserves the kind and
length of every other live allocation. After every prefix of the history the
table remains well formed and its heads agree with replaying the operations.
The model tracks current heads by page index. Pointer lifetime across address
reuse, synchronization, and small-block ownership remain separate obligations.
The page resize transition is described below.

The [EC618 allocation-size check](../cxx/harness/ec618_allocation_size.c)
checks the query used by realloc. Null returns zero. Small allocations use
the payload extent in their packed header even when the payload is page
aligned. For a live direct allocation, VeriFast proves that the read-only
`page_allocation_bytes` loop returns the exact extent through the first
non-continuation for any registered run length, including a run ending at
the sentinel. CBMC checks that the query selects the right head and uses
that contract for larger runs. It runs the native scan for runs through four
pages and checks rejection of free page starts and the one-past address.
These checks require a live small-block header or a readable page run with
its terminating status. Concurrent page-table changes remain outside the
proof.

The [public EC618 realloc check](../cxx/harness/ec618_realloc_dispatch.c)
runs the production dispatcher for every 32-bit requested size. It checks
zero-size release, allocation from null, and replacement of a live allocation.
On replacement, the dispatcher passes exactly the common prefix of the two
extents to the copy and releases the original only after the copy returns.
If fresh allocation fails, it balances the lock around the page fallback or
retags an eligible small block while preserving its packed size fields. It
checks propagation of the fallback result and that a failed small resize
retains the original allocation. The check uses contracts for allocation,
size lookup, copy, free, classification, thread tags, locking and page resize.

For every registered EC618 table size, VeriFast checks
`page_growth_start` against the page statuses before and after a live
direct allocation. If any placement fits, it selects the greatest valid
start, keeping the old head or making the shortest backward move. Otherwise
it reports failure. The [page realloc accounting check](../cxx/harness/ec618_page_realloc_commit.c)
uses the proven placement, page-number and status-fill contracts. It checks
the returned address, old payload range supplied to `memmove`, new head
tag, every descriptor status and tag, byte accounting and both residual
free runs. This covers every positive 32-bit request, including same-size
success, growth, shrinkage and failure. The heap must be locked with a live
direct allocation, a readable table and sentinel, maximal adjacent free
runs and representable counters. The thread tag comes from the checked
EC618 lookup under the scheduler assumptions above. For the
overlapping copy, the firmware check *(unchecked, see the note on linked-image
results above)* matched the allocator's direct call and the forward Thumb
instructions in the supplied base ELF. For that historical EC618 release ELF, the
[instruction model](../cxx/annotated/heap/ec618_memmove.smt2) (checked as a
model: `run.sh ec618-smt/memmove`) proves that
each destination byte receives its original source byte, all other bytes
retain their values from loop entry and the loop terminates. This uses
unsigned lower destination addresses, a representable source end, ordinary
readable and writable memory, and a valid stack separate from both spans.
The mapping from Thumb instructions to the model is reviewed. Each firmware
build needs its own instruction match. The
[combined native check](../cxx/harness/ec618_page_realloc.c)
also runs the selector and descriptor writes together on tables of up to
four usable pages, with independent enumeration of fitting placements.

The [resize history proof](../cxx/annotated/heap/ec618_page_resize.c)
represents a successful locked page resize as releasing the original run and
reserving the resulting one within their shared extent. It proves those two
logical operations are admitted and can be appended to an existing history.
The resulting table has the new direct head and length, retires the old head
when it moves, and preserves every other allocation. Its changes in free
bytes and runs agree with the changes calculated from the two residual
free extents. The intermediate free interval exists only in this proof.

The page allocator and realloc fallback share `fill_page_statuses` when
marking continuations or releasing the tail of a shrinking allocation.
VeriFast proves for every supplied range length, including zero, that the
routine writes the specified status to every entry and terminates. The
contract requires ownership of just those status words. Tags, the sentinel
outside the range, and other descriptors retain their contents. The bounded
allocation and resize checks above exercise the production calls that choose
the range.

The [EC618 small-block bucket check](../cxx/harness/ec618_buckets.c) covers
all 72 size classes. Allocation rounds a positive payload up to the first
class that fits, and freeing an aligned payload rounds down to its class.
For arbitrary bitmap words and starting indices, lookup returns the earliest
eligible occupied bucket or reports failure. Padding bits cannot identify
a bucket. The check also exercises native insertion and unlinking with all
four combinations of preceding and following neighbors. It checks the
affected links, heads, bitmap and accounting deltas, and the packed header
fields for both a free block and an allocated payload. These checks assume
a valid local list and correctly sized storage. They cover the board's
release configuration.

The [EC618 allocation-tail check](../cxx/harness/ec618_split.c) starts with a
valid selected free block and a fitting rounded request. It checks both
outcomes of the native split decision, the next block's boundary tag, free
list links and bitmap, byte and block accounting, and the tag on the returned
payload. The selected bucket can have a successor and the remainder's bucket
can already be occupied. Clearing covers the full usable payload even when a
small remainder stays in the allocation. The cleared-word loop has a separate
VeriFast proof. Lock release and thread-tag lookup use contracts.

The [EC618 coalescing check](../cxx/harness/ec618_coalesce.c) runs both
small-block free entry points on three adjacent blocks of symbolic sizes.
For all four combinations of free neighbors, it checks which neighbors are
unlinked, the merged address, size and left boundary tag passed to
`free_memory`, the allocation counter, and the interior free marker. It also
checks lock balance, null and ignored frees, and rejection of a header
already marked free. This assumes a valid, stable arena, with contracts for
unlinking, publication and locking. Concurrent changes to the arena and the
lifetime of the pointer supplied by the caller remain assumptions.

The [EC618 arena reclamation check](../cxx/harness/ec618_reclaim.c)
runs `free_memory` for symbolic aligned extents that fit a small-block bucket.
It checks the merged header, the right neighbor's back-link, and the bucket
head, links and bitmap for a retained block. It checks that page return
requires both arena sentinels and both page-aligned ends, that the native
code detaches the arena before the handoff, and that the address and page
count cover exactly the arena. It covers an empty or occupied destination
bucket and arena-list neighbors that may alias each other. The check assumes
valid boundary tags, serialized access and, on return, a matching allocated
page run. It uses the byte and block accounting contract of the
[page-free check](../cxx/harness/ec618_page_free.c). Establishing those
preconditions across arbitrary allocator histories remains open.

The [EC618 growth check](../cxx/harness/ec618_growth.c) exercises the public
malloc dispatch across all 32-bit sizes. It checks direct page rounding,
thread tags and lock balance. On the small-block path it runs the native
bucket search, heap growth and arena construction through the call to the
allocation tail. It covers an existing suitable bucket, page reservation
failure, and successful growth into an empty or populated arena list. The
new arena fits the rounded payload, its header and both boundary sentinels
in the minimum number of whole pages. Only the arena overhead is deducted
from heap capacity and remaining bytes before allocation. The harness
models page reservation, locks, thread tags and the allocation tail.
The [aligned allocation check](../cxx/harness/ec618_aligned.c) covers public
dispatch for arbitrary byte sizes and alignments. It checks rejection of zero
and non-power-of-two alignment, forwarding to ordinary or page allocation,
and bucket exhaustion. For a suitable selected block the production alignment
code leaves either no prefix or a usable free block, preserves both boundary
tags and supplies the allocation tail with the first aligned payload that
fits those conditions. Prefix sizing is checked independently across all
naturally aligned 32-bit addresses and supported small-block alignments.
The harness runs native bucket edits starting from one selected list entry.
It gives the selected payload a symbolic, naturally aligned board address for
the alignment calculation and uses the same byte offsets in its backing storage.
Heap locking, bucket acquisition, the allocation tail and delegated allocation
results supply contracts.

Both host metadata commits stay within the supplied reservation. The first
covers the chunk's mark bits and their lookahead byte, and the second covers
its cumulative-mark entries. If the OS refuses either commit, the allocator
reaches the fatal handler after exactly that attempt. The byte charge is
unchanged, no table fill has run, and allocation cannot return a descriptor.
The fatal handler models process termination. On success, the allocated
descriptor has two self-links.
The [chunk lifecycle check](../cxx/harness/gc_chunk_lifecycle.cc) follows
each admitted allocation through retirement in one execution on ILP32, LP64,
and 32-bit FreeRTOS. It covers any fitting whole-page extent in the 64-page
fixture. For young, old and unowned chunks, raw and tagged GC lookups observe
the expected classification at an arbitrary mapped address. Retirement
subtracts the charge before unclassifying the pages. By the time the OS
receives the pages back, their classification is unknown and neighboring
pages keep their original classification. The exact descriptor storage is
released once after the OS call. The checker expands scalar deletion into
the native destructor and the storage release and models the effect of the
classification fill on the observed table byte. The [constructor proof](../cxx/annotated/heap/scavenge_roots.render)
also covers any representable chunk end. On return the start passed the
metadata range check, the end equals start plus size, and the scan cursor
equals the start. It assumes the link base constructor and fatal termination.
The same sidecar checks the destructor body for any nonempty, mapped,
page-aligned extent. It proves that the descriptor's pages are classified
as unknown before handing the exact original address and size to the OS
release contract.
The space destructor's teardown loop is checked for any finite inventory of
owned chunks. It repeatedly reads the current head, unlinks it, and calls
`ObjectMemory::free_chunk` once per entry in the original list order. It
terminates with an empty list and zero allocation bounds, including when the
space was empty initially. The release-build body of `ObjectMemory::free_chunk`
subtracts the descriptor's exact size from the shared atomic byte counter
before deletion. The rendering of scalar delete invokes the verified chunk
destructor before releasing descriptor storage. This composition assumes
each retiring chunk owns its byte charge, the atomic operation contracts,
the list operations, and final storage deallocation. The release-build
`allocate_chunk_helper` proof establishes that charge for a newly allocated
descriptor and returns the ownership required by retirement. Given a valid
unclassified reservation, a successful owned allocation classifies its pages
and initializes all four chunk tables. Descriptor allocation failure releases
the pages and leaves the charge unused. Null page input returns null.
The helper uses contracts for descriptor storage, committing the metadata
reservation, and atomic addition.
The native chunk iterator check exercises head removal on singleton and
multi-chunk lists, checking both detached links and the successor's links.
The [shared spare chunk proof](../cxx/harness/gc_spare_lifecycle.cc) checks
serialized VM startup and shutdown. It covers page, descriptor and mutex
allocation failure, duplicate startup with a live spare, and teardown before
startup. Normal shutdown restores the byte count and disposes of the mutex
before releasing metadata. The check models the OS and metadata lifecycle calls.
The [FreeRTOS spare selection proof](../cxx/harness/gc_spare_selection.cc)
starts with a shared page and attempts a second reservation under the spare
mutex. It follows allocation, descriptor construction, selection and
retirement with three mapped pages at any representable aligned base. A page
or descriptor failure leaves the shared page available. On success the
lower-address page survives and the other reservation is released. In every
case one page remains charged and the third page keeps its classification.
The check models OS reservations, successful metadata commits, mutex exclusion
and descriptor storage. The harness renders deletion of a live descriptor
as its native destructor followed by storage release, so ESBMC checks both.
The [visitor construction check](../cxx/harness/gc_scavenge_start.cc) starts
with a detached spare, a source descriptor, and installed metadata tables.
It checks the exact destination ranges and values passed to the five metadata
fills, the empty allocation window, and the sentinel write at the first word.
Every other destination payload word is preserved. The visitor records both
chunk extents, the supplied promotion boundary, and its initial card state.
For these two single-page spaces the native list constructors and append
establish the circular links in both directions. Removing either descriptor
restores the selected anchor and descriptor to self-links, clears its owner,
and requests exactly one change to its page classification. The other space
keeps its ring and owner. A second removal from the empty space returns null
without requesting any metadata fill.
The [constructor proof](../cxx/annotated/heap/scavenge_roots.render) establishes
the root visitor’s initial fields for independently sized chunks. It reads the
source descriptor through the single-chunk lookup and consumes the destination
window proof for an aligned buffer of any positive word count. The dummy card
can begin uninitialized. The native owner setter stores the supplied space and requests its page
classification. For a live owner, it initializes all four metadata tables.
For page-aligned descriptors, the page-type write covers one entry per page in
the mapped range. The native mark-bit clear covers one byte per eight heap words.
The remembered-card and overflow address calculations use the published biases,
including word-width wraparound. All four initialization fills use the libc
memset contract and require ownership of their metadata slices. Detachment requests the unknown-page classification and
preserves the tables. The [object-start accessor proof](../cxx/annotated/heap/semispace.render)
derives the table entry from the published bias both when clearing chunks and
when recording an allocation. The native range test accepts the upper endpoint,
which supplies the one-past address used in table fills. The
[setup check](../cxx/harness/gc_metadata_layout.cc) follows a successful host
reservation through the native accessors to the committed card tables.
It has a verdict on ILP32 and in the EC618 and ESP32 variants; on LP64 the model
checker gives no verdict (verified/cxx/annotated/README.md, "No verdict").
The base space constructor installs the program and page type and starts with
zero allocation bounds. The native semispace append sets the owner and links the
chunk before the constructor installs the allocation window. For an empty or
single-chunk space, the removal proof returns the previous descriptor or null.
Removing a descriptor clears its owner and marks every mapped page in its range
as unknown. The survivor transfer proof moves the descriptor and both allocation
bounds to the persistent space, then clears the temporary window. Its contract
requires no access to the survivor payload or metadata tables. These proofs use
contracts for the underlying list operations, the LivenessOracle base
constructor, and ownership of mapped storage.
The [young collection handoff proof](../cxx/harness/gc_spare_exchange.cc)
checks the C++ transfer after copying into a one-page semispace. The survivor
keeps its allocation bounds and metadata and belongs to the persistent space.
The old page is detached, unclassified, and published as the next spare before
unlocking. The check admits any aligned nonzero base for a four-page mapping
whose end fits in a host word, and any two distinct pages in that mapping.
Every neighboring classification byte keeps its initial value. The host
release-build promotion threshold is checked for every word-aligned survivor
size, with empty or nonempty old space, against the heap limits and promotion
inputs recorded before the swap. This check assumes completed copying and
models mutex entry and exit. The separate semispace body proof derives the
used-byte count from the allocation top and the sole chunk's start.
Virtual memory commits supply contracts. For the historical EC618 allocator build, the
firmware fill check *(unchecked, see the note on linked-image results in
section 1)* matched
the linked calls from chunk initialization and destruction in each supplied
VM slot to the base's Thumb memset. Its [instruction model](../cxx/annotated/heap/ec618_memset.smt2)
(checked as a model: `run.sh ec618-smt/memset`)
proves termination, the low byte written at each destination, and preservation
of bytes outside the range for all 32-bit lengths, including zero. This
assumes writable ordinary memory and the reviewed Thumb semantics. For
page classification, the removed checker also matched the singleton literal and the
field loads to the slot's symbols and DWARF layout. The compiled range check
skips starts outside the heap. For a live whole-page chunk contained in the
mapping, the [argument proof](../cxx/annotated/heap/ec618_page_classify.smt2)
checks that the fill covers exactly the corresponding page-table bytes.
For chunk initialization the Thumb instruction model *(unchecked)*
follows the initializer into the mark-bit helper and through all four fills.
It checks each destination, exclusive end and fill byte against the mapped
chunk. Mark bytes, overflow bits and remembered cards receive zero, and
object-start bytes receive the sentinel 2. The mark lookahead byte lies
outside the fill. The linked setup check *(unchecked)*
covers the successful allocation path for a nonempty OS heap range whose
page-rounded exclusive end fits in a word. It checks the requested byte count
and placement of all six nonoverlapping tables within a successful grant,
the four eager commit calls and the initial page-type fill. The five stored
biases recover the corresponding bases at the heap lower bound, including
when unsigned subtraction wraps. This assumes a live metadata object, a
private stack and ordinary writable memory for the granted bytes. The
firmware heap range check *(unchecked)* follows
the slot getter into the release base statistics wrapper. Before allocator
initialization its zero fill selects the nonempty linker arena from
`end_ap_data` to `start_up_buffer`. For that base the registration check *(unchecked)*
follows the linker arguments into the header and verifies that initialization
places all 86 page descriptors and their sentinel inside its reserved storage.
The fragment check *(unchecked)* follows the
two registration insertions through free-list bucket selection, bitmap updates,
arena links and allocation headers. Given a private stack, their stores preserve
the registered bounds, descriptors and whole-page region.
After registration the collector reads the header bounds and reports
`[0x441920, 0x498e00)` on normal return. This depends on a live registered
heap, readable collector inputs, and helpers preserving the header bounds
and caller-owned storage. Initialization must be serialized through heap
publication because this build sets the initialized flag before storing the heap pointer.
For either reported range the reservation is 28,672 bytes. The linked page
allocation check *(unchecked)* follows that request
from base `malloc` to `page_alloc`. For any stable occupancy of the registered
86 pages it checks first-fit selection of seven contiguous free pages or a null
return on exhaustion, the descriptor stores, and zeroing of exactly the selected
run. The linked release check *(unchecked)*
follows metadata teardown from the singleton pointer into base firmware
`free`. For every valid ordinary allocation head and extent in this arena, it
checks that release clears only the run's status words, credits its byte size,
and adjusts the free-run count for both neighbors, including arena edges.
The caller must own a live allocation through dispatch and release. These
checks require live writable registered RAM, accurate page ownership and
exclusive access during allocation. The scheduler lock check *(unchecked)*
follows the base firmware's heap lock into scheduler suspension. With the
application vector table active, a PendSV during suspension sets a pending
yield and restores the same task. Unlock decrements the suspension count in
a critical section and a nested unlock leaves the outer suspension in place.
Before scheduler startup the wrappers bypass suspension. This assumes
single-core task context, valid stacks and task control blocks, stable
scheduler startup state, nonoverflowing nesting and no interrupt-side heap
mutation. For the outermost resume with active tasks and valid scheduler
lists, the checker follows pending-ready tasks into the queue for their
priority, then checks one tick-helper call per deferred tick. Existing yield
requests, newly ready tasks of equal or higher priority, and nonzero tick
results feed the final PendSV decision. The [countdown proof](../cxx/annotated/heap/ec618_scheduler_resume.smt2)
covers every 32-bit pending count. The linked tick check *(unchecked)*
follows the tick increment, delayed-list exchange on wrap, timeout scan and
ready-queue insertion. It checks that a task due on the current tick wakes,
a later task stays delayed, and equal priorities and time slicing participate
in the yield decision. This assumes sorted, well-formed delay lists, a valid
cached earliest deadline, valid task priorities, and an empty retiring list
at rollover. The list splice proof *(unchecked)*
symbolically executes the linked removal and insertion helpers against arbitrary
aligned word memory. Given valid local links, it checks the two neighbor updates,
cursor, container and count, and preservation of every other word. It includes
empty-list insertion and singleton removal with either cursor position.
The startup check *(unchecked)* follows
first-task registration from zero tasks and a null current task through all
56 ready queues and five other scheduler lists. It checks every initial
header word, publication of the two delayed-list pointers, and first ready
queue selection. For a fresh task, the constructor detaches both embedded
items, sets their owner to the task, and clamps its priority to 55. This
assumes valid separate task, stack and output storage and task tracing that
preserves the initialized list fields. The task frame proof *(unchecked)*
follows dynamic allocation of the stack and 200-byte TCB and checks the four
initial frame writes, saved stack pointer, and SVC restore layout. It requires
a word-aligned stack of 18 to 65,535 words; the linked release callers must
supply a valid depth. The [EC618 thread spawn proof](../cxx/harness/ec618_thread_spawn.cc)
checks the current VM wrapper for every signed byte request, including default
selection, word rounding and both depth limits. With modeled RTOS outcomes
it checks publication before task creation, allocation-tag restoration, and
release of acquired resources with a null thread handle on failure. On
successful spawn it follows worker entry, completion and join, including a
joiner reclaiming the data as soon as it is signaled. Synchronous `run()`
restores the caller's thread registration and allocation tag. The lifecycle
harness uses the production map with distinct parent and worker task handles.
It covers worker completion before spawn returns, parent lookup while the
worker is registered, and worker lookup after the parent updates the cache.
A [separate map proof](../cxx/harness/ec618_thread_map.cc) checks the production operations
from arbitrary valid occupancy of the configured 16 slots, including full-map
replacement and exhaustion. It checks publication of the task, thread and cache
before restoring the caller's interrupt mask. This assumes single-core PRIMASK
semantics and no map access by NMI or fault handlers. The lifecycle harness
models RTOS calls. The linked semaphore check *(unchecked)*
follows the two final format-2 slots into the base-v5 firmware
(fingerprint `f0ae7c907be49d8af02ea2dbcfa6aecf`) and checks the 80-byte dynamic
completion semaphore starts empty with capacity one, two empty wait lists
and unlocked counters. The thread gate *(unchecked)*
also checks the linked stack-depth guard, clearing the published descriptor
on failed task creation, and restoration of the worker’s allocation tag before signaling.
The removed combined heap check required the historical allocator layout.
The semaphore check covers the null allocation return and that deleting
the live dynamic queue delegates its original pointer to the allocator.
This assumes an aligned writable grant and exclusive access during creation
and deletion. For a live semaphore and a running scheduler the linked worker's
zero-wait give publishes one token or returns failure if full. Join consumes
one token on success. An empty receive rechecks the count before registering
on the receive wait list and retries after waking. The linked timeout check *(unchecked)*
shows that join's all-ones wait always returns “still waiting” from the timeout
helper and preserves the wait budget, regardless of tick rollover. For finite
waits it checks expiry and remaining ticks across at most one tick-counter wrap
between samples, assuming a coherent snapshot under the interrupt mask.
The linked wake check *(unchecked)* follows
the first waiter into its priority's ready list or, during scheduler
suspension, the pending-ready list. Both paths request a yield for a strictly
higher priority. Queue unlock drains each positive signed-byte lock count up
to the number of waiters and restores the unlocked marker. This assumes valid
list and task ownership and representable deferred counts. The
registration check *(unchecked)* follows an
indefinite join from the receive wait list through removal of the current
task's state item from its ready list and insertion on the suspended list.
It checks ordered insertion after existing equal keys and the complete
splice write footprint. This assumes a finite sorted list with intact links,
a maximal sentinel, an unlinked event item and room to increment the count.
For one successful spawn, one worker signal and one exclusive join, the
linked worker and join paths also had a completion-object lifetime check *(unchecked)*.
It includes a joiner that frees the semaphore and descriptor before the
worker returns from give. The last worker queue access precedes critical
section exit, and its self-delete path uses neither object. This assumes
the callback and RTOS callees respect ownership and the calling convention,
the objects and stacks do not alias, and no other task signals or retires
the queue. Establishing those assumptions at every caller and scheduler
progress remain obligations.
At source level the [event-worker check](../cxx/harness/event_worker_start.cc)
covers the timer and EC618 peripheral constructors. Both publish their
singleton only after the startup resource and worker have been acquired.
Peripheral teardown withdraws its atomic singleton before sending the FIFO
stop message, joining and releasing the queue. A task producer keeps its
nonblocking send and pointer lookup in one critical section. An ISR finishes
before a teardown task can run on the single core. ESBMC checks the production
callbacks before closure, at the stop send, during join and at queue release,
for initial FIFO occupancy from zero through 32. The check assumes one
destructor, a working FIFO, eventual worker execution, and single-core
critical-section semantics. Peripheral dispatch, the mailbox and RTOS queue
operations are modeled in that lifecycle check. A separate [mailbox proof](../cxx/harness/ec618_mailbox.cc)
executes the production C++ from both fresh and arbitrary valid retained state.
It checks the wake request, preserved UART kinds and latest generation per
controller before any token is enqueued, then checks exact dispatch by a
drain with no overlapping publication. A [completion race check](../cxx/harness/ec618_mailbox_race.cc)
interleaves one producer with one take and a final drain under ESBMC's atomic
model. It permits repeated delivery of a generation when calls overlap.
The Cortex-M3 instruction check *(unchecked)*
checks the four mailbox update loops in the EC618 event-source object and
in both final format-2 slot links. The checked build used the verifier,
the Rust interpreter, and base-v5 fingerprint `f0ae7c907be49d8af02ea2dbcfa6aecf`.
The C++ device relocator running on the host reproduced the independent
slot-B link byte for byte, including sector-chunked relocation.
With valid aligned storage and ARM exclusive-monitor semantics, a
failed store leaves the current word intact and retries from a fresh load.
A successful store performs the required set, clear or exchange. The check
also checks that startup
publishes the initialized source after a successful spawn, that task and ISR
producers call the intended mailbox and queue routines, and that teardown
clears the same singleton before sending STOP and joining. The checker reads
the object's call and data relocations or the final ELF's resolved branch
destinations and literal values to establish those identities. It
assumes a nonreturning fatal handler, callee contracts, barrier semantics
and eventual progress for operations that must return.
Lifetimes of resource groups holding a source pointer
and callbacks surviving into a new source generation remain separate obligations.
The thread-stack bound covers construction of the initial
frame; stack consumption during task execution is a separate obligation. Ticks
arriving during suspension increment a 32-bit pending count;
lossless replay requires that count to stay representable. Scheduler object
ownership and preservation of heap ownership across other allocator operations
remain dependencies.
Chunk operations additionally require a live
chunk descriptor and a metadata layout that remains intact. Other targets
still rely on their libc fill contracts. The [host page allocator
check](../cxx/harness/gc_host_pages.cc) exercises a failed commit, a successful
retry, exhaustion, and release for every length and position of a single free
run in the second of two bitmap words, under a modeled resource lock. It
invokes the production chunk destructor and follows it through the native
host release routine. At decommit the page classifications and allocation
bits for the retired run have been cleared, and neighboring entries retain
their values. The
[fragmentation check](../cxx/harness/gc_page_fragmentation.cc) admits every
initial occupancy pattern across two words and all request sizes from one to
64 pages. It checks first-fit selection within word boundaries, exhaustion,
preservation of neighboring allocations, and restoration of both words on
commit failure or release. It also verifies the native first-fit search within
one word against an arbitrary candidate run. Using that contract, Frama-C
proves the [production bitmap scan](../../src/heap_page_scan.h) terminates and
finds the earliest fitting run or returns the end when none exists, for any
valid bitmap whose page count fits a machine word. The same proof checks that
claim and release write only the selected bitmap word and set or clear exactly
the run mask. The [native update check](../cxx/harness/gc_page_update.cc) takes
the scan result as a contract and checks the host allocation and release paths
for any representable nonempty heap bitmap. A successful commit precedes
publication, and either allocation failure preserves the bitmap. Given any
outstanding grant whose pages are marked occupied, a new grant has a
disjoint byte range. Releasing either grant clears exactly its pages before
decommit and preserves the other grant, including when both share a bitmap
word. The check assumes the bitmap initially records the outstanding grant
and each release supplies the address and extent of a grant still held.
At the start of the noncompacting old-space sweep, the [free-list clearing
proof](../cxx/annotated/heap/free_list.render) establishes that every bucket
is empty and returns ownership of every former chain, with its links and
payload intact. The [three-card sweep fixture](../cxx/harness/gc_sweep_chunk.cc)
runs the native sweep, region encoder, and bucket insertion together.
It checks leading, trailing, and interior gaps, an empty chunk, the byte
count, filler words, object starts, mark clearing, and the final sentinel.
It models the page release and supplies the bitmap and chunk. It takes
the filler loop `fill_unmarked_words` by its contract, which the card-scan
proof below establishes for both widths, instead of running its body
(ESBMC could not finish with the native loop; verified/cxx/annotated/README.md,
"Restructured").
The [card scan](../../src/third_party/dartino/sweep_empty_cards.h)
authorizes releasing a whole chunk exactly when it starts at card zero and
every mark word is zero. On a mixed card, both filler loops preserve every
marked heap word. These results assume a valid card mapping and a mark bit
for each word occupied by a live object. The [free-region check](../cxx/harness/gc_sweep_free_region.cc)
shows that extending an empty run into its neighbors includes only clear
bits, leaves space for the free-list header, and excludes the final sentinel
when the run reaches the chunk end. The [traversal proof](../cxx/annotated/heap/page_scan.c)
shows that repeated production card steps select each nonempty card exactly
once, using its actual neighboring marks for empty runs. It assumes the
mark map stays intact during the sweep. Ownership of the chunk, the sentinel's
reserved position, and completeness of the mark map remain assumptions here.

The [POSIX protection check](../cxx/harness/gc_page_protection.cc) verifies
that the Linux and macOS wrappers request read/write access for precisely
the pages touched by a nonempty commit and remove access only from complete
pages within a release. It covers endpoint overflow, empty intervals,
recoverable commit failure, and fatal syscall errors for power-of-two OS page
sizes. Windows uses the same [range calculation](../../src/os_page_extent.h).
The [POSIX reservation proof](../cxx/harness/gc_page_reservation.cc) checks
the mapping hint, exact rounded length, permissions, and flags. It covers
empty and oversized requests, release of an unusable zero-address mapping,
and unmap failure. The [host heap initialization proof](../cxx/harness/gc_heap_reservation.cc)
checks the aligned usable range and bitmap word count, disposal of the original
reservation if bitmap allocation fails, and reuse on a second call. It assumes
serialized initialization, the numeric parser and allocator contracts, and a
representable reserved address range.
The [old-space expansion check](../cxx/harness/old_chunk_expansion.cc) follows
the quota decision through page admission, provider failure and the retry
on a newly installed window. It assumes stable space and external charges,
fresh pages on provider success, and the installation and reservation contracts.
Kernel calls, the resource lock, the Windows API path and the FreeRTOS page
provider remain open.
The [track header check](../cxx/harness/gc_promoted_track.cc)
covers initialization, remembered-card publication, bounds and retirement. The [destination chunk walk](../cxx/annotated/heap/scavenge_chunk.render)
proves that each object initially queued or appended during traversal is
visited exactly once before the scan pointer is published at the final sentinel. The
partition, object-size and root-enumeration contracts supply the next
boundary. The [window proof](../cxx/annotated/heap/scan_positions.gh)
derives one candidate address per word of an installed young allocation window.
Allocation splits the original set between the reservation and the remaining
window. The chunk walker removes each visited address itself. The
[new-chunk sizing check](../cxx/harness/gc_promotion_capacity.cc) covers both
word widths and the header needed during promotion. Establishing the external
reserve from the page provider and proving its transfer on expansion remain open.
Establishing the complete root set and preserving
reachability through movement and sweeping remain open.
For format-2 stacks with valid incoming bounds, the [shrink proof](../cxx/harness/gc_stack_shrink.cc)
checks that the live slice keeps its values and length, record storage stays
in place and the tail becomes single-word free objects. It uses the libc
move contract and a [verified word fill](../cxx/annotated/heap/stack_fill.render).
[Root traversal proof](../cxx/annotated/heap/mark_roots.render) The metadata setup proof checks the reported
bounds, publication after all four eager commits and page-type initialization,
and release of the reservation after a failed commit or normal teardown.
Repeated teardown leaves the mapping released. The mark fast path tests the
heap page offset independently of the mark table's placement. The
[ESP32 internal RAM sizing check](../cxx/harness/gc_internal_ram_range.cc)
proves that trimming the C allocation prefix retains a nonempty, page-aligned
heap interval with the original upper bound, including on small heaps.
The EC618 and ESP32 checks use the published tables to map and initialize
an arbitrary whole-page chunk in the retained range. They check both lazy
commit extents, the mark lookahead byte, young and old page classification,
and the four initialization fills. The destructor unclassifies those same
pages before returning them to the page provider. The ESP32 check covers
both RAM-selection flags and uses independent expected sizes for the retained
heap tiers. These checks model the OS reservation and commit operations and
observe the fill calls. They assume the selected chunk is a live reservation.
Concurrent use of the tables during collection remains open. [GC metadata layout](../cxx/harness/gc_metadata_layout.cc) · [Native table access](../cxx/harness/gc_metadata_access.cc)

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
  This is the largest assumption. Since branch core/proven-accessors it
  is stated exactly, once, as the invariant of the views the derivation
  points produce (`view::heap_ok`: `word_val`, `str_ok`, `ba_ok`), and
  every access is proven inside it: an access to a word outside the
  object's permissions does not verify.
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
header words. ASSUMED (`alloc::gc_alloc_post`): afterwards the views
represent a state `g2` that collections reach from `g`, with the spec's
new instance (class `c`, every field null, outside the program heap)
appended, and the result is its address; or `g2` itself if the result is
0 (out of memory). A collection (`toit_spec::v2::gc::collection`, the
spec's statement of what a collector may do; `gc_steps` is any number of
them, none when the heap's epoch is unchanged) is weak processing (maps
reset, values of maps' backings nulled, as
`WeakMapFinalizerNode::weak_processing` does) followed by a compaction:
a live set that holds the roots of the state (object stack, globals, the
running task) and is closed under references survives, garbage
disappears, the live objects are renumbered `0..n` with their references
renamed, the program heap and the program's constants keep their ids,
and nothing else changes (frames, handlers, finally records, bci). The
collector moves objects and rewrites every root (object-stack slots,
globals; it keeps the frame records and the header, possibly moving or
shrinking the Stack object); allocation appends exactly one object.
Before stage 0 of the collector plan (OBLIGATIONS.md, "The collector")
these contracts said the views represent `g` itself: false for a
collector that frees memory (the model's ids would grow without bound
past the `small` bound) and for programs with weak maps. The save before
and the reload after are proven (`Machine::save`, `alloc::reload`). The
other four state the same about the views, with the spec's object
(double), the spec's raise completion (heap extended by the trace,
`exception_obj2` appended, `prim::raised`, whose completions may collect
first: `prim::raised_gc`), the collected state with room (stack growth,
`step::grow_post`), or one of the spec's PRIMITIVE completions of the
collected state (`theorem::completion`).

`toit_v2_run` builds the program view from the context
`Interpreter::run_v2` fills and checks the table sizes it relies on
(roots, literals, method and bytecode limits); `Interpreter::run_v2` is
trusted to fill it from the process' program and method table.

Trusted C++ the core depends on (src/interpreter_v2.cc): the method-table
decoder (`V2MethodTable::compute`, V3), `v2_program_tables` (the tables
the core and the verifier get, verified/vmverify), `prepare_process_v2`
(initial frame), the handoff between the Rust primitive handler and the
native task switch, stack
growth (`toit_v2_grow_stack`, `Stack::v2_copy_to`), the GC and shrinking
of format-2 stacks (`Stack::roots_do`, `Stack::v2_frames_do`), the
exception allocation and trace encoding, and the C++ primitives.

The [stack-growth proof](../cxx/annotated/ffi/interpreter_v2.render)
starts with an allocated header and an initialized payload. Format-2
allocation fills every slot with tagged zero so the Rust `StackMem`
invariant also holds for the unused gap. Growth copies the record prefix
and live suffix, sets the format-2 header and then publishes the stack.
The proof reads the four concrete header words, decodes the record
bounds and bytecode index, and computes the primitive argument address
from the tagged stack pointer. Each collection supplies the current task
and stack addresses together, so a retry must reacquire the task even
when its record contents are preserved. The proof reads the object heap's
current-task field and the stack pointer in the task's first instance field.
Publishing a grown stack requires the instance write barrier before the
field store. The collector contract still supplies ownership of these
fields and the live stack's header and payload on return. The growth proof
now checks both native record-header stores. Decoding the packed word
recovers the frame top, record top and finally count. Reading the stored
bytecode index recovers every signed word, including negative indices. A
separate [record-header check](../cxx/harness/stack_records.cc) checks the
same round trip directly on the native stack layout. The
[fresh-stack check](../cxx/harness/fresh_stack.cc) covers the C++ stack
allocator for every supported length, including zero, given a loaded
stack class and a raw reservation or failure. It checks the header,
guards, exact writable slot range and the arguments to the
[proved field fill](../cxx/annotated/heap/stack_fill.render). The raw reservation, the GC's
treatment of roots and the relation between the copied words and the
Rust machine state remain assumptions of the combined proof.

The [initial-frame check](../cxx/harness/prepare_process_v2.cc) runs the
native method lookup, stack writes and card barrier for main and spawn
entries. It supplies symbolic method and dispatch table extents and selected entries,
a task linked to its stack, a valid card mapping and sufficient stack
space. It checks the sole object slot, method, return address, base,
handler, record bounds, bytecode index and preservation of other payload
words. Mapping these concrete objects to the spec's initial heap remains
a loader obligation. The format-2 spec's `initial_state` selects main.

Before creating a process group for a program, the VM checks that the
builtin task class has its stack and ID fields and that a fresh page has
room for the initial stack, task and end sentinel. The
[capacity proof](../cxx/harness/initial_task_capacity.cc) checks every
class descriptor against the native semispace reservations on 32-bit and
64-bit hosts and the 32-bit FreeRTOS page layout. It assumes that the
program's class table occupies its declared extent and the allocator
supplies the initial page.

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
retries on allocation failure. The core theorem assumes the leaf contract
`gc_call_primitive` for this path. The untrusted policy resolves 150
primitive names, of which 106 have Rust ports. The [primitive proof
inventory](../cxx/annotated/README.md) records the native body proofs
and their remaining assumptions. Trusted format-2 programs used by the
test suite can reach every primitive. The checked loop for programs
outside the accepted set calls only C++ primitives.

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

The split of the run loop (performance) is no longer trusted: it was the
external_body function `step::split_loop` (`cfg!(target_os = "none")`,
branch core/call-speed-size) until branch core/split-option made it the
core's Cargo feature `split-loop` (Kconfig TOIT_VERIFIED_CORE_SPLIT_LOOP,
default off). With the feature the arms of the rare opcodes
(`step::cold_op`) are compiled out of `step_r` and one arm calls
`step_cold` (which requires `cold_op` and ensures the same `rpost` as the
in-loop handlers); without it `step_cold` does not exist. Both
configurations are separate compilations that Verus verifies (check.sh:
`core` and `core-split`, 64- and 32-bit words), so nothing is assumed
about the configuration.

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
| Between runs | `theorem::resumed`, `machine::run` (`Ghost::assume_new` of `g`) | the scheduler resumes a preempted or yielded task in the state it saved, after collections (`toit_spec::v2::gc::gc_steps`: the GC of the process may run while it is suspended) | C++ scheduler and GC (trusted); `reload` re-checks the Stack header's shape |
| Heap model integrity | `abs::heap_model_ok`, `Machine::refines`, TRUSTED V2, V5 | one distinct tagged address per object; class tag and body agree; read-only objects are exactly those in the program-heap range | the GC, the allocators and the C++ primitives maintain it |
| Allocation | `alloc::gc_allocate_instance`, `alloc::gc_allocate_double` | the views represent a state that collections reach from the one before (`gc_steps`) with exactly the spec's new object appended, or that state itself (out of memory) (`alloc::gc_alloc_post`) | `toit_v2_allocate_instance`/`_double` and the GC |
| Raise | `raise::gc_allocate_exception` | the views represent a state that collections reach from the one before (`gc_steps`) with the heap extended (`prim::heap_extended`: the trace) and `exception_obj2(value, trace)` appended, or only extended (out of memory): `prim::raised` | `toit_v2_allocate_exception` (`ProgramOrientedEncoder`, `allocate_byte_array`, `allocate_instance`) and the GC |
| Stack growth | `step::gc_grow_stack` | the views represent a state that collections reach from the one before (`gc_steps`), with `needed` free words on success (`step::grow_post`) | `toit_v2_grow_stack`, `Stack::v2_copy_to`, the GC |
| Primitives | `primitive::gc_call_primitive` | after collections (`gc_steps`, the GCs between the attempts of a call that ran out of memory), the status, result and resulting state are one of the spec's completions of the PRIMITIVE step from the collected state (`theorem::completion`): `prim_spec` (the default contract, and for the core module the precise contracts of `prim_core::core_contract` and the three examples of `prim.rs`, for arguments without block references) for each C++ primitive the policy resolves, `task_step` for task_new/task_transfer | NOT discharged per C++ primitive (section 8 lists the reviewed ones; the precise contracts of the ported indices are validated against the C++ by verified/core/tests/prim_diff.sh). The Rust ports (`prims::call`, run by `primitive::op_rust_primitive`) are proven: their outcome is a completion (`primitive::lemma_completion`), no leaf contract |
| Floating point | spec crate: `x_double_add/sub/mul` | host IEEE-754 arithmetic implements the spec's uninterpreted functions | as format 1 (shared code) |
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
| `Table::from_raw` (derivation point) | `toit_v2_run` passes a wrong length for a table (e.g. a short invoke-offsets table): the permissions would cover memory that is not the table | layout check (struct offsets), vmverify differential (the verifier reads the same tables), ASan fuzzing |
| `Globals::from_raw` (derivation point) | the globals pointer or length differs from the process' globals | ASan fuzzing, untrusted suite (globals tests) |
| `StackMem::from_stack`, `Runtime::stack` (derivation points) | the Stack object's length word differs from the array the core indexes, or a header word offset collides with the array | `TOIT_V2_VALIDATE=1` (slot checks around GCs), layout check (`STACK_*_WORD`), ASan fuzzing |
| `Heap::new` (derivation point) and the layout facts `view::word_val`, `str_ok`, `ba_ok` | an object's header, field count, length, payload or blob encoding differs from the C++ `HeapObject`, `Instance`, `Array`, `Double`, `LargeInteger`, `String`, `ByteArray` layout (the constants are layout-checked; the encodings, e.g. the string sentinel, the negative byte-array length, the V5 rule, are reviewed against objects.h) | layout check (behavioral, fake objects), IDENTICAL on external strings and byte arrays (untrusted suite), prim_diff.sh, `TOIT_V2_VALIDATE`, ASan fuzzing |
| `pointer::wrapping_add`, `wrapping_offset` (`assume_specification`) | Rust's wrapping pointer arithmetic did not keep the provenance or did not wrap modulo the word size | the Rust reference (`wrapping_offset`: "the resulting pointer has the same provenance"); Miri semantics |
| Card permissions at heap entry and GC transitions | the published bias must designate the live card table, with exclusive access to the bytes covering writable process objects while the core holds the view | `Heap::write_barrier` verifies the store and its effect on existing marks using those permissions. The checked loop uses its separate raw `Heap::set_word` path. |
| `Table::u16_at_even` (aligned load) | the target's 16-bit load is not the little-endian combination of the two bytes, or the address is not 2-byte aligned (a load exception on Xtensa; `pre + (i + PRE)` not `ptr + i`) | `u16::from_le` (byte order), the aligned-address facts in `prog_rel` checked by the loader (`V2MethodTable::compute`, `toit_v2_run`), every call on devices (an unaligned load traps), the suites on the core |
| `Heap::{header, word, word64, set_word, byte, set_byte, half_word_at}` | only the checked loop; a missing run-time check there reads outside an object | ASan with programs not accepted (runtime-hardening-test) |
| `Preemption::*` | the watermark is not the interpreter's | tests that preempt (tests/sandbox scheduling tests) |
| `Runtime::*` (FFI wrappers), `PrimitiveRef` | a wrapper forgets to replace the stack view after a GC | `TOIT_V2_VALIDATE`, ASan |
| `alloc::gc_allocate_instance`, `gc_allocate_double` | the GC moves an object without updating a root the abstraction covers, or the new object is not the spec's | `TOIT_V2_VALIDATE=1` around every GC, untrusted suite, fuzzing |
| `raise::gc_allocate_exception` | the encoder reads a message word as an object after a GC point, or the exception is not `exception_obj2` (value field 0, trace field 1) | negative tests comparing traces with format 1 (untrusted suite), ASan |
| `step::gc_grow_stack` | records not copied (`Stack::v2_copy_to`) or the header not updated | deep-recursion tests (build/t/deep.toit, tests/sandbox), `TOIT_V2_VALIDATE` |
| `primitive::gc_call_primitive` | a C++ primitive breaks `prim_heap_ok` (e.g. writes a task's stack field, as before R5), returns a non-value, or disagrees with a precise contract of `prim_core` | fuzzing (found R5), vmverify differential, prim_diff.sh (C++ against the proven Rust ports, 10M calls); the Rust ports replace 106 of them for untrusted programs (S1) |
| `PrimitivePolicy::core_arities` (C++, read through `Env::core_arities`, a `Table<u8>`) | an entry is non-zero for a primitive the policy denies (the Rust port would run although the C++ entry is `primitive_denied`) | tests/sandbox (denied primitives fail with PERMISSION_DENIED), review of `initialize_core_arities` (compares the policy's function pointer with `Primitive::at`) |
| `ffi::Allocator` (`toit_v2_try_allocate_*`) | an allocation collects garbage (a Content view would dangle) or the object is not the stated builtin class and body | The [native allocation-path proof](../cxx/harness/process_blob_allocation.cc) includes the string and byte-array FFI entries. The [byte-array construction proof](../cxx/harness/byte_array_initialization.cc) checks the class, representation, length and exact zero fill under the raw reservation and libc contracts. The [young-space raw allocator proof](../cxx/annotated/heap/young_allocation.render) transfers exclusive ownership of the requested words given a valid unused chunk range. The same proof transfers the old allocator’s reservation to the caller on a successful retry. Establishing allocator windows from the live heap, establishing free-list ownership and acquiring fresh chunks, and correspondence with the abstract heap remain obligations. Tests include prim_diff.sh and ASan fuzzing. |
| `prims/fp.rs` | a remaining trusted float operation differs from the C++ (arithmetic NaN payloads, libm) | prim_diff.sh (bit-exact checksums) |
| `prims/index.rs` `TABLE` (plain Rust) | a primitive index or arity differs from src/primitive.h | layout check (`toit_vcore_prim_entry` against MODULE_CORE) |
| `ffi::toit_v2_run` `assume_new` (ap, cert, trusted) | the tables the core runs differ from those vmverify checked | vmverify differential (from_vm on the same `toit_v2_program`), the `Accepted` token ties the loop to the accepted table |
| `machine::run` `assume_new` (g) | the scheduler resumes a different state | tests/sandbox task tests, untrusted suite (tasks, channels) |
| `machine.rs` (plain-Rust file), `cold!` | the checked loop runs only programs not accepted; `cold!` (also used by the `*_raw` trampolines of the verified loop's leaf calls) passes the machine by reference to an out-of-line closure | runtime-hardening-test, the checked loop's run-time checks; review: the `*_raw` bodies only call the FFI |
| `ffi.rs` plain items (layout tables, `Context`, `ProgramTables`, extern decls) | a C struct field moved | layout check (every offset) |

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
| Number and blob accessors | `Heap::double_bits`, `large_int`, `bytes_len`, `string_content`, `byte_array_content`, `string_hash_field`, `set_string_hash_field` (section 1) | verified since branch core/proven-accessors against the heap's permissions; what remains is the layout the derivation point states (`word_val`, `str_ok`, `ba_ok`, V5) |
| Content views | `Content`, `Heap::content_at/set/copy/fill` | verified: a view carries the object's content pointer (`content_ok`), which the accessors and allocation keep; a heap after a GC point relates no content pointer to the old ones, so a view cannot be used across one (proven, not reviewed). Content fill verifies each byte store against its permission. The optimized x86-64 host build lowers this loop to libc `memset`, so native execution still relies on that implementation. Content copy verifies each read and write, including overlapping ranges of the same object |
| Array primitives | `prims/array.rs` | The call contracts specify the shared empty-array root, contents of fresh and expanded arrays, and slice replacement using the original source elements even for overlapping ranges. They fix the error roots for invalid lengths, indices, and read-only destinations. The [native array creation proof](../cxx/annotated/prims/array_new.render) calls the object-heap constructor. Its [C++ allocation check](../cxx/harness/process_array_allocation.cc) proves length validation, reservation size, header and element initialization for fresh storage. The same check follows the native two-space retry and verifies the old array’s remembered card before initialization. The [native barrier proof](../cxx/annotated/heap/remembered_card.render) derives the card address from the published table base and heap bounds. Ownership of the reserved words and the live card byte across collection remains a separate obligation. |
| Array memmove | `Heap::array_copy` | Each copied word gets its original source value, all other words retain their values, and a nonempty copy marks the destination card |
| Allocation without GC | `ffi::Allocator` (`toit_v2_try_allocate_*`) | appends exactly one object of the program's builtin class (`p.ap@.builtin[k]`) with the stated body at a fresh tagged address outside the program heap, keeping the model below 2^30 objects (`view::appended`), or changes nothing and returns 0. The class tag of each builtin class is checked at run time (`prims::builtin_with_tag`), not assumed |
| Integer arithmetic | `prims/ints.rs` and the C++ division fallback | The Rust arithmetic contracts specify the exact immediate value or appended large integer, and allocation failure. Division truncates toward zero, remainder follows the dividend, and the leading-zero count uses all 64 bits. The four [C++ division and remainder proofs](../cxx/annotated/prims/integer_division.render) cover both word sizes under the object, error-root and boxing contracts. |
| Float operations | Remaining `external_body` functions in `prims/fp.rs` | Arithmetic, square root and native NaN payload choices retain trusted scalar operations. For float_ceil, float_floor and float_trunc, the verified implementation rounds directly on binary64 bits. Its [rounding check](../spec/tests/binary64-round-integral.smt2) compares all three modes against IEEE roundToIntegral for every non-NaN encoding, including signed zero and infinities. A NaN input uses the target libm payload, and the caller verifies the result encodes a NaN. The run loop, compare_to and min_special_compare_to use a verified numeric comparison. Its [magnitude check](../spec/tests/binary64-mixed-compare.smt2) compares every unsigned integer magnitude and nonnegative binary64 number or infinity in a floating-point format that represents both exactly. For the five binary64 comparisons and float_sign, float_is_nan and float_is_finite, the primitive-call contract specifies the exact result from binary64 bits, an unchanged heap and the wrong-type failure. The [SMT check](../spec/tests/binary64-compare.smt2) compares the five rank predicates with IEEE binary64 operations for all pairs of bit patterns. Run it with Z3 and expect `unsat`. Unary negation flips the sign bit. The two 64-bit raw conversions preserve every bit. Their contracts specify immediate integer results, successful allocation of exactly one object, wrong-type errors and allocation failure. The number_to_integer contract preserves an integer receiver and truncates a double toward zero. It distinguishes NaNs from out-of-range values and accepts −2^63. The [conversion check](../spec/tests/binary64-to-int.smt2) checks the bit operations against IEEE round-toward-zero conversion. The number_to_float contract preserves double payloads and rounds signed integers to nearest with ties to even. A [Z3 check](../spec/tests/binary64-from-int.smt2) compares the encoding with IEEE conversion for every signed 64-bit input. For raw32_to_float the [widening check](../spec/tests/binary64-from-raw32.smt2) covers every binary32 number and infinity. For float_to_raw32 the [narrowing check](../spec/tests/binary64-to-raw32.smt2) covers rounding to nearest with ties to even, gradual underflow and overflow to infinity. In both directions only NaN payload selection uses a native cast, and the verified caller checks the result is a NaN. Boxing still uses the native allocator contract above. The differential test compares the ports with C++. |
| The policy table | `Env::core_arities` (`PrimitivePolicy::core_arities`) | section 2: non-zero exactly where the policy resolves the VM's own primitive. Not used by the proof (the preconditions of `prims::call`, `heap_inv` and `args_ok`, are proven from `Machine::inv` in `primitive::lemma_rust_args`) |
| Out of memory | none | `NeedsGc` leaves the heap unchanged (`prims::prim_post`), so the handler calls the C++ primitive on the same state, which collects and retries (the C++ protocol; its result is the leaf contract's completion) |

### Primitives that stay in C++, and the contract the proof relies on

The theorem needs every allowed primitive to satisfy `prim_default`
(`prim_heap_ok`: objects are only added, keep their class, machine-owned
objects (suspended stacks, tasks' stack and id fields) are untouched,
every object stays well formed with good references; results are good
values; out of memory is a resource error) and the arity of
`prim_arity.rs`. The table records the rationale for the contracts on
the C++ side. The per-primitive inventory lists the corresponding body
proofs and their assumptions. [C++ proof coverage](../cxx/annotated/README.md)

| Primitives | Contract the proof relies on | Why the C++ meets it (review) |
|---|---|---|
| `task_new` | The machine specifies creation in `prim::task_new_step`. | ESBMC checks the C++ primitive's errors and format-2 stack setup given a fresh task and stack. The [allocator check](../cxx/harness/allocate_task.cc) covers ID exhaustion, both reservations in a young-space window, task and stack headers, field contents, the card write and the trailing sentinel. The [instance check](../cxx/harness/instance_allocation.cc) applies the VeriFast field-fill contract at an arbitrary slot. The allocator checks take a loaded class table, a valid young-space window and its card mapping as inputs. Retry in old space and the binding to the Rust heap model are separate obligations. |
| `task_transfer` | The machine specifies transfer in `prim::task_transfer_step`. | Native frame construction checks include the two methods, return addresses, frame bases, handler flags, initial slots and saved bci. The caller must supply a well-formed running stack, machine-owned Task fields, loaded program metadata and a valid GC card mapping. The Rust/native handoff still relies on the core having saved the current state before the call and reloading the selected stack afterward. |
| `task_has_messages`, `task_receive_message` | `prim_default`; the received value is a good value | the result is null, a finalizer lambda (an existing object), a notifier's object (an existing object) or a new 4-element array of smis and the decoded message; `MessageDecoder` only allocates strings, byte arrays (raw external bytes), arrays, lists, maps, doubles and large integers of the program's builtin classes, each fully initialized before it is reachable; it never creates a Stack or a Task. The [process string and byte-array allocation check](../cxx/harness/process_blob_allocation.cc) covers every signed word length, including rejection when the string terminator would overflow and the padding for a forced external empty array. It checks quota refusal, malloc and header failures, initialization of the terminator, and ownership and charge transfer on success under allocator and header contracts. Constructor proofs check the internal string layout and the external string and byte-array handoff to the VM finalizer queue, including allocation failure, given raw heap reservation. |
| `process_send` | `prim_default`; `prim_heap_ok` permits a raw external byte array to become opaque while preserving its class. | Publication clears transferred arrays' addresses, lengths and active-finalizer flags and refunds their external allocation charges. The encoder now uses a verified ownership test over the byte-array layout and finalizer flag. The ownership-table and concrete detach checks cover publication. For an owned byte array at any transfer-table position, the two passes agree on transfer versus inline or external copy, the wire extent and the external charge, given blob lookup and copy contracts. The primitive body checks error propagation, message charges and delivery outcomes given encoder and scheduler contracts. Array and map traversal proofs check child order and the emitted count. Native list encoding checks the requested interval against the logical size and forwards the original offsets to the checked backing-array traversal. List slices preserve both endpoints through direct-array and list backings, including the first child failure. The map proof follows live key/value pairs through direct and list backings, including early failures. Tagged integers, null, booleans, doubles and boxed integers have matching size, write, decode and disposal lengths on both word sizes. For boxed numeric results the decoder checks the allocator handoff, including exhaustion. The native box constructors rely on raw heap reservation. The native cleanup walk consumes a complete IPC tree and releases its external owners given the tree layout. The native cardinal writer constructs the reader’s digit predicate at any buffer offset using exactly the sized extent. Tag, fixed-width and pointer writes also supply the byte chunks needed to assemble cleanup nodes. The native tagged-integer writer supplies a cleanup node with the original sign and magnitude at any valid offset. Given each child’s byte boundaries and ownership contract, the native array loop constructs a complete cleanup node on success and preserves the completed prefix on failure. Proving that arbitrary sender inputs produce that layout and ownership, with matching size and write passes, remains open. |
| `add_finalizer`, `remove_finalizer` | `prim_default`; the model is unchanged | they set or clear the finalizer bit in the object header (not modeled) and register the finalizer in a C++ list (a GC root); program-heap objects are left alone |
| `time`, `time_info`, `seconds_since_epoch_local`, `get_real_time_clock`, `random`, `gc_count`, `process_current_id`, `process_system_id`, `word_size`, `platform`, `architecture` | `prim_default` (environment nondeterminism: any good result) | they read the clock, the PRNG, counters or constants and return smis, booleans, program roots, new strings or a new array of smis (`time_info`) |
| `spawn_method` | `prim_default` with an unchanged heap and a Smi result | VeriFast checks the exact legacy offset or format-2 method index, including the -1 sentinel. The loaded image and method table must satisfy the bounds and ordering in the proof. ESBMC checks record extents, canonical headers, receiver intervals and spacing between adjacent entries on both word sizes. Installation preserves the records by borrowing the aligned literal or owning a copy. Frama-C verifies the loop accepts exactly the well-formed record sequences and terminates. ESBMC checks the final literal selection, TMT2 header and exact record view. `compute` passes the same validated record view and image to installation and propagates its result and allocation failure. The program heap and backing storage lifetime and allocator contracts remain trusted. [Implementation proof](../cxx/annotated/prims/spawn_method.render) · [Loader checks](../cxx/harness/v2_table_bounds.cc) · [Validation loop](../../src/v2_validate_records.h) · [Installation proof](../cxx/harness/v2_table_install.cc) · [Loader composition](../cxx/harness/v2_table_compute.cc) |
| `main_arguments`, `spawn_arguments` | `prim_default` | decode the launch arguments with `MessageDecoder` (as `task_receive_message`) |
| `encode_error` | `prim_default` | The [primitive body proof](../cxx/harness/encode_error.cc) checks stack store/reload ordering, failure results, and the copy into a fresh internal or external byte array under the allocator and memcpy contracts. ESBMC checks the native buffer's write bounds, size accounting and ownership transfer on both word widths. The [byte-array encoding proof](../cxx/harness/encoder_byte_array.cc) checks the typed header, 40-byte prefix and empty representation of native proxies. WP checks the [string truncation boundary](../../src/encoder_string_prefix.h) for every nonnegative word-sized length. The [tag dispatcher](../cxx/harness/visitor_dispatch.cc) selects the matching callback given a valid reference. The [scalar visitor proof](../cxx/harness/encoder_scalar.cc) checks the values passed to the writers for integers, doubles, booleans and null. The [numeric writer proof](../cxx/harness/encoder_numbers.cc) checks integer and binary64 encodings and collection headers. The [frame callback proof](../cxx/harness/encoder_frames.cc) checks the advertised count, retained frames and emitted records for a stable, consecutively numbered walk. The [format-2 walker](../cxx/harness/v2_frame_walk.cc) proves enumeration given live, valid frame records, bytecode storage and a stable skip setting. The [collection proof](../cxx/harness/encoder_collections.cc) checks list validation, depth and element caps, and ordered child dispatch for arrays and lists. Legacy stack enumeration, recursive encoding, interpreter stack operations and the underlying allocation and libc implementations still rely on contracts. [Buffer proof](../cxx/harness/encoder_buffer.cc) |
| `int_parse`, `float_parse`, `float_to_string`, `float_round`, `int64_to_string`, `uint64_to_string`, `printf_style_int64_to_string`, `smi_to_string_base_10`, `string_to_utf_16`, `utf_16_to_string`, `byte_array_convert_to_string`, `byte_array_is_valid_string_content`, `crc` | `prim_default` | read blobs through `Blob` (bounds-checked by the `ARGS` macros) and return smis, large integers, doubles, booleans, new strings or new byte arrays; never write existing objects |
| Events `read_state` | `prim_default`; returns a Smi or marked error | ESBMC checks the native primitive and synchronized read-and-clear with modeled OS mutex operations. On ILP32 the source mask must fit a Smi for exact numeric round-trip. [Read-state proof](../cxx/harness/event_read_state.cc) |
| Timer `init`, `delete` | `prim_default`; returns a new group proxy or program null on success | ESBMC checks quota admission and proxy publication on creation, ownership checks before deletion, proxy closure and one-time quota release. Heap allocation, group admission, list registration and native teardown remain trusted. [Group initialization](../cxx/harness/timer_init.cc) · [Timer deletion](../cxx/harness/timer_delete.cc) |
| Timer `create` | `prim_default`; returns a new timer proxy on success | ESBMC checks quota rollback on native allocation failure and registration before proxy publication. The harness assumes allocation and group-list insertion contracts. [Timer creation proof](../cxx/harness/timer_create.cc) |
| Timer `arm` | `prim_default`; program null on success | ESBMC checks the native proxy and integer argument paths and the exact 64-bit deadline passed to the timer queue. For a queue with up to two other timers, the same proof checks stable insertion, rearming, event-state reset, both queue links, unregistration and the decision to signal. The [timer-thread check](../cxx/harness/timer_dispatch.cc) checks one loop iteration from a sorted queue of up to two timers. It proves exact delivery of the due prefix, the pending queue at the next iteration, and the delay when the first timer is in the future. It assumes a nonnegative monotonic clock, live timer groups and serialized queue access. On EC618 the [timed-wait proof](../cxx/harness/freertos_wait.cc) checks the 1 kHz, 32-bit conversion for every signed delay, including saturation before the indefinite-wait sentinel. The [scheduler notification check](../cxx/harness/scheduler_notify.cc) follows a live monitor through two sends, optionally separated by a dequeue. It checks mailbox coalescing, quota counters and ready-queue publication for every receiver state, with at most one preceding message and one ready peer. Arbitrary queue lengths, concurrent queue changes during waits, OS synchronization and worker wakeup still rely on contracts. [Timer arm proof](../cxx/harness/timer_arm.cc) |
| Events `register_monitor_notifier`, `unregister_monitor_notifier` | `prim_default`; program null on success | ESBMC checks typed proxy decoding, closed-resource handling, group ownership, exact calls to the event source, and error propagation. The [monitor lifetime check](../cxx/harness/event_monitor_lifetime.cc) runs native registration, update and cancellation for a single monitor. It checks both allocation failures, removal from the GC root list, and the queued message’s survival until dequeue after cancellation. Allocation and mutex behavior are modeled. The [native scavenge check](../cxx/harness/monitor_scavenge.cc) discharges the lifetime check’s root-update contract for a two-word young monitor object, including reuse of a forwarded global alias. The receive primitive returns the surviving object for a live monitor and program null after cancellation. The [process root traversal](../cxx/annotated/heap/process_roots.render) separately checks enumeration of the slots. The native size calculation reads the loaded class bits. The check covers copying to young space, promotion to old space, and fallback to young space if promotion fails. It verifies each reference’s remembered-set flag and the request for an old-space collection. Valid class metadata, the source extent and allocation results are assumed. Concurrent teardown and arbitrary object graphs remain open. [Native body proofs](../cxx/harness/event_notifiers.cc) |
| bitmap `blit`, `byte_zap` (src/primitive_bitmap.cc) | `prim_default`; only the bytes of the destination byte array change | write inside `MutableBlob` bounds; a byte array stays a byte array |

## 9. Trusted containers on the core (experiment, branch experiment/trusted-on-core)

Results and measurements: EXPERIMENT-trusted.md. Three items make trusted
programs (the system process, first-party code) run on the verified loop
fast. None of them is reachable by an untrusted program.

| Item | Where | Statement | Why it holds / what catches it |
|---|---|---|---|
| Trusted token | `ffi::Accepted::trusted_program` | a trusted program that the launch did not verify enters the verified loop: the loader's `assume_new` of the abstract program, certificate and mode (`trusted == true`) rests on the compiler (its output would be accepted under the trusted rules) | `Interpreter::run_v2` writes `TOIT_V2_TRUSTED` only for a process whose policy is not untrusted; debug builds and `-Xverify` verify trusted format-2 programs at launch (`V2MethodTable::verify_trusted_by_default`); the whole host suite runs with everything in format 2 on the verified loop |
| Epoch | `primitive::gc_call_primitive`, `alloc::gc_allocate_instance`, `alloc::gc_allocate_double` (third result), `Runtime::{call_primitive, allocate_instance, allocate_double}` | `ObjectHeap::v2_epoch_` changes at every collection of the process' heap (`ObjectHeap::gc`) and every task switch (`ObjectHeap::set_task`); epoch unchanged across a C++ call implies that no object moved and the current task and its stack object (and length) are the same, so the core keeps its stack view and machine fields (`primitive::unmoved`) and the state is the step's with a new heap | [Process-heap epoch check](../cxx/harness/gc_process_epoch.cc) verifies the counter update on collection and task publication, including wraparound. Call-site review: every collection of a process heap goes through `ObjectHeap::gc` (scavenge and full GC, also the ones messaging and the scheduler start), the stack object is replaced only by the core's own growth (`toit_v2_grow_stack`, not a C++ primitive) and task switches go through `set_task`; tests: the whole suite on the core (GC-heavy tests, task tests), `TOIT_V2_VALIDATE=1` |
| Unchecked field accesses | `step::trusted_field_accesses` (external_body proof fn), `Program2::unchecked`, `Program::unchecked`, `toit_v2_context::unchecked`; since branch experiment/trusted-fast the unchecked twins of the field accesses (format note 20, opcodes 104..113) instead of a mode tested in the handlers | in the unchecked mode (trusted programs, which may contain the twins) no step reaches a failed unchecked field access (a twin (a receiver other than `this` that is not an instance with the field, a machine-owned task field, a store into the program heap): `unchecked_ok` | we trust the compiler for first-party code; `accepts` allows the mode only with `trusted == true` and `Interpreter::run_v2` sets it only for processes whose policy is not untrusted (TRUSTED: never for an untrusted process); the launch verifier accepts twins only under the trusted rules, so an untrusted program never contains one; the checked handlers untrusted programs run are the ones before the mode existed; the soundness theorem (`theorem_soundness`, `lemma_run_wf`) is stated for programs without the mode, i.e. for every untrusted program |

### Branch experiment/trusted-fast

| Item | Where | Statement | Why it holds / what catches it | Untrusted programs |
|---|---|---|---|---|
| Inline allocation | `Runtime::allocation_window`, `inline_page_metadata` | The VM supplies the owned semispace window and its top and limit slots. For a successful allocation it supplies write permission for a missing card byte. A shared card retains its existing permission and value. On 64-bit targets the object-count bound remains assumed at the model limit. Below that limit, allocation on an already owned card uses no page-metadata assumption. | The allocator checks that the entire remaining semispace window is disjoint from the read-only program heap before writing the object or its sentinel. Verus proves the new address differs from each live header using exclusive word permissions. On 32-bit targets, the number of distinct word-aligned headers whose exclusive end fits in the address space proves that the resulting heap contains fewer than 2^30 objects. It retains the semispace provenance of the allocated words, reindexes exactly the instance or double words into the heap, proves the heap invariant after the append, and preserves existing objects, addresses, content pointers and card marks. The proof establishes that the next word contains the chunk-end sentinel. The layout checker compares its value with the C++ heap walker’s sentinel. | yes, for instance allocation and double boxing |
| Range of `needed` (stack growth) | `step::gc_grow_stack` (requires `needed < GROW_STACK_MAX_NEEDED` = 2^20, discharged at both callers: `step::ensure_room` passes a frame record, the maximal height (< 2^16), the reserve and a finally record; `room::ensure_room_all` less than 2^19), `toit_v2_grow_stack` | the contract held only for `needed` below 2^63 (2^31 on 32-bit): C++ casts it to `word`. Now the precondition bounds it and C++ rejects `needed > Stack::max_length()` explicitly (a stack overflow, which is the truth: no stack has that many free words) before any cast | review; both sides changed (review finding of the coordinator) | yes |
| Ported core primitives | `toit_v2_core_ported` (plain Rust export), `PrimitivePolicy::initialize_core_arities` | none for correctness: the policies' core arities leave out the core primitives without a Rust port, so that their PRIMITIVE calls C++ directly; with or without the mask the step is a completion of the spec's PRIMITIVE (the C++ primitive and its port are the same primitive) | performance only | yes (the untrusted policy's table too) |
