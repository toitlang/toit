# Toit GC

This is a two-space generational GC heap with scavenge (Cheney semispace
collector) for the new space (young generation) and a mark-sweep heap for
the old space (old generation).  It was originally written by Erik Corry
for Google's Dartino project and has since been adapted for the Toit VM.

The GC never uses more space after GC than before (fragmentation can't get
worse).

The GC never mallocs more space during GC: Compaction and remembered-set data is
constant space and mark stack overflows are handled with low cost and no
extra space.

Object headers are one word.  Metadata including mark bits is stored in a
contiguous area outside the heap.  The remembered set of pointers from
old space to new space is done with card marking.

The heap is handled in chunks of memory, allocated from the operating
system.  These chunks are always at least one page in size and always page
aligned.  They are allocated in a range that is fixed at program
startup.  This enables metadata to be allocated in a contiguous area
that has a linear relationship to the heap memory location.  Pages are
4k on 32 bit systems and 32k on 64 bit systems.

Lines (sometimes called cards in the context of the remembered set) are
32 words long (128 bytes on 32 bit systems, 256 bytes on 64 bit systems).
The objects in a line can always be iterated without having to start from
the beginning of a chunk.  This is used for iterating over the remembered
set to find pointers into new-space.  It is also used for recovering from
mark stack overflow.

Lines are made iterable by having a single byte per line that determines
the offset of the start of one of the objects that starts on that line.
This 'starts' table is updated by allocation with an unconditional byte
write operation that may harmlessly overwrite another valid offset.  In order
to iterate the objects on a line it is necessary to first step backwards to the
previous line and start iterating there.  Objects can span line boundaries.

## New space

Each heap has a single young generation chunk, and there is a common
spare young generation chunk used by all heaps (processes).  A new-space GC
consists of taking the shared spare chunk, copying
surviving objects to that chunk and donating the now-empty semispace
chunk to the system as the new spare chunk.

Allocation in new space is bump allocation and the object-starts data
need not be updated for new space allocations.

Remembered set is one byte per 32-word line in the old space.  For
speed we use a whole byte per line, but we represent only two states -
dirty and clean.  We have a global `static char* remembered_set_bias` and
the write barrier when writing a pointer into a field of an object o is:

```
remembered_set_bias[o >> 7] = 1
```

We can optionally filter so the write barrier is only triggered for
objects in old-space, but it is safe to execute it regardless. However
newly allocated objects are only created in new-space so we don't need a
write barrier for initialization writes.

Objects are promoted to old space when they survive their second GC,
but if old-space allocation fails they can stay longer in new space.

There is no read-barrier.

## Old space

The old generation is a mark-sweep old-space.

Allocation in old space exclusively takes place when surviving objects are
promoted from new-space.  We use worst-fit free-list allocation to get big
regions for fast bump allocation.  This has the effect that objects from the
same cohort (allocated between the same two GCs) tend to stay together when
moved to the old GC.  This gives better locality, but the new-space GCs
scramble allocation order within a given cohort.

The old generation is optionally moving - we can do both mark-sweep and
mark-sweep-compact collections of the old space.  Currently we alternate
between mark-sweep and mark-sweep-compact.  The mark-sweep part is identical,
so we could postpone this decision.

Object order does not change during compaction - all objects just slide down to
squeeze out spaces.  This means that after a compacting GC all chunks are
tightly packed with no waste, except for an area at the end of the chunk that
was too small to contain the first object in the following chunk.

An on-heap chained data structure keeps track of
promoted-and-not-yet-scanned areas during new-space GC.
(This is called PromotedTrack.)

Currently all GCs are stop-the-world, and we don't restart the program until
the complete collection has taken place.  Possible improvements, not yet
implemented:

* Delay sweep after GC.
* Only compact part of the heap (this was tried in Dartino with mediocre results).
* Make marking incremental in shorter stop-the-world increments (the current write barrier can be adapted for incremental marking).
* Run the program between new-space and old-space GC (currently they are back-to-back whenever an old-space GC happens).

Marking proceeds with the usual white-grey-black coloring.  Objects start white,
and are marked grey when they are determined to be live.  When they are marked
grey they are also pushed on the marking stack so they can be scanned.  When they are
popped from the marking stack they are marked black and their pointers are scanned.

If we grey an object when the marking stack is full we cannot push the object
and we have a mark stack overflow.  We have a rule against allocating during
GC (when malloc is often exhausted), so we can't expand the stack.  Instead,
this is handled by marking the 32-word line
with a flag that shows there are unstacked grey objects on the line. At a later
point we scan the line for grey objects, blackening and scanning the objects we
find in the same way we would if they were found on the mark stack.  This is
surprisingly efficient because overflow bits are contiguous and a single byte of
overflow bits can tell us that 8 lines (1k or 2k) of heap have no overflowed
objects.

Marking grey consists of setting the mark bit corresponding to the header of
the object.  Marking black consists of setting the mark bit for every word of
the object.  Mark bits are out of line and take up one bit per word of heap.

At the end of a mark-sweep or mark-sweep-compact GC there are mark bits in the
new space, which we ignore.  This means that the new space can harmlessly
contain unreachable objects with broken pointers in them.

### Sweeping old-space

After marking, if we are not compacting, we can sweep to find free memory for
allocation.  This mainly takes place in the mark bits which are much smaller
than the total heap.  Because black objects have all bits marked the mark
bits contain all the information we need to construct a free list for allocation.
However, the heap needs to stay iterable for the remembered set and we
need to be able to skip dead objects when iterating the remembered set, so we
have to insert free area markings on the heap itself.  In the future it might be
possible to postpone this work, doing it just-in-time only on the lines in the
remembered set during new-space GC.

### Compacting old-space

If we are compacting we make use of the mark bits to determine the location each
object is sliding to.  By iterating over the mark bits and counting the 1s, we
can determine for each line the offset its live objects will be moved to.
Positioning of an object within the line can be done by some masking, shifting
and counting of 1s.  Most CPUs have a popcount instruction for this.  The data
needed to translate the old object location to the new object location is entirely
outside the object, so once all locations have been computed with an
almost-linear pass over the metadata we need only a single linear pass over the
heap to move objects and fix their pointers to point to the new locations.  The
memory needed to fix the pointers is entirely preallocated so that no allocations
take place during GC.

## Heap metadata overview

The heap metadata is a fixed amount of memory for every page that can
possibly be used for the heap.  On embedded targets we have a simple fixed
memory map and it is relatively easy to predict the location of heap chunk
allocations.  On targets with virtual memory this is a little more involved:
We reserve some space in the virtual memory space for metadata and only map
it into the process when a heap chunk allocation indicates that it is needed.

|                     Overhead on:                | 32bit |  64bit     |
|-------------------------------------------------|-------|------------|
| One remembered set byte per card.               | 1/128 |  1/256     |
| One object start offset byte per card.          | 1/128 |  1/256     |
| One mark bit per word.                          | 1/32  |  1/64      |
| One uword per 32 mark bits (sum of mark bits).  | 1/32  |  1/32      |
| One bit per card (overflow).                    | 1/1024|  1/2048    |
| One byte per page (page type).                  | 1/4096|  1/32768   |
| One remembered set byte per card.               | 1/128 |  1/256     |
|-------------------------------------------------|-------|------------|
| Total:                                          |  7.9% |  5.5%      |

We could reduce the metadata overhead on 32 bit platforms by about 35% to about
5.2% by rounding all object sizes up to a multiple of two words. This would
make it impossible to tell the difference between grey and black objects
for small objects that are only 2 words long, but these objects can only contain
a single pointer so they can be scanned without pushing them on the marking
stack, using iteration.  This lets them go straight from white to black without
an intermediate grey stage.
