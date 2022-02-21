// Copyright (c) 2015, the Dartino project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.
// Mark-sweep old-space.
// * Uses worst-fit free-list allocation to get big chunks for fast bump
//   allocation.
// * Non-moving for now.
// * Has on-heap chained data structure keeping track of
//   promoted-and-not-yet-scanned areas.  This is called PromotedTrack.
// * No remembered set yet.  When scavenging we have to scan all of old space.
//   We skip PromotedTrack areas because we know we will get to them later and
//   they contain uninitialized memory.

#include "src/shared/flags.h"
#include "src/shared/utils.h"
#include "src/vm/mark_sweep.h"
#include "src/vm/object_memory.h"
#include "src/vm/object.h"

#ifdef _MSC_VER
#include <intrin.h>
#pragma intrinsic(_BitScanForward)
#endif

namespace dartino {

OldSpace::OldSpace(TwoSpaceHeap* owner)
    : Space(kCanResize, kOldSpacePage),
      heap_(owner),
      free_list_(new FreeList()) {}

OldSpace::~OldSpace() { delete free_list_; }

void OldSpace::Flush() {
  if (top_ != 0) {
    uword free_size = limit_ - top_;
    free_list_->AddChunk(top_, free_size);
    if (tracking_allocations_ && promoted_track_ != NULL) {
      // The latest promoted_track_ entry is set to cover the entire
      // current allocation area, so that we skip it when traversing the
      // stack.  Reset it to cover only the bit we actually used.
      ASSERT(promoted_track_ != NULL);
      ASSERT(promoted_track_->end() >= top_);
      promoted_track_->set_end(top_);
    }
    top_ = 0;
    limit_ = 0;
    used_ -= free_size;
    // Check for 'negative' value.
    ASSERT(static_cast<word>(used_) >= 0);
  }
}

HeapObject* OldSpace::NewLocation(HeapObject* old_location) {
  ASSERT(Includes(old_location->address()));
  ASSERT(GCMetadata::IsMarked(old_location));
  if (compacting_) {
    return HeapObject::FromAddress(GCMetadata::GetDestination(old_location));
  } else {
    return old_location;
  }
}

bool OldSpace::IsAlive(HeapObject* old_location) {
  ASSERT(Includes(old_location->address()));
  return GCMetadata::IsMarked(old_location);
}

void OldSpace::UseWholeChunk(Chunk* chunk) {
  top_ = chunk->start();
  limit_ = top_ + chunk->size() - kPointerSize;
  *reinterpret_cast<Object**>(limit_) = chunk_end_sentinel();
  if (tracking_allocations_) {
    promoted_track_ = PromotedTrack::Initialize(promoted_track_, top_, limit_);
    top_ += PromotedTrack::kHeaderSize;
  }
  // Account all of the chunk memory as used for now. When the
  // rest of the freelist chunk is flushed into the freelist we
  // decrement used_ by the amount still left unused. used_
  // therefore reflects actual memory usage after Flush has been
  // called.
  used_ += chunk->size() - kPointerSize;
}

Chunk* OldSpace::AllocateAndUseChunk(uword size) {
  Chunk* chunk = ObjectMemory::AllocateChunk(this, size);
  if (chunk != NULL) {
    // Link it into the space.
    Append(chunk);
    UseWholeChunk(chunk);
    GCMetadata::InitializeStartsForChunk(chunk);
    GCMetadata::InitializeRememberedSetForChunk(chunk);
    GCMetadata::ClearMarkBitsFor(chunk);
  }
  return chunk;
}

uword OldSpace::AllocateInNewChunk(uword size) {
  ASSERT(top_ == 0);  // Space is flushed.
  // Allocate new chunk that is big enough to fit the object.
  int tracking_size = tracking_allocations_ ? 0 : PromotedTrack::kHeaderSize;
  uword max_expansion = heap_->MaxExpansion();
  uword smallest_chunk_size =
      Utils::Minimum(DefaultChunkSize(Used()), max_expansion);
  uword chunk_size =
      (size + tracking_size + kPointerSize >= smallest_chunk_size)
          ? (size + tracking_size + kPointerSize)  // Make room for sentinel.
          : smallest_chunk_size;

  if (chunk_size <= max_expansion) {
    if (chunk_size + (chunk_size >> 1) > max_expansion) {
      // If we are near the limit, then just get memory up to the limit from
      // the OS to reduce the number of small chunks in the heap, which can
      // cause some fragmentation.
      chunk_size = max_expansion;
    }

    Chunk* chunk = AllocateAndUseChunk(chunk_size);
    if (chunk != NULL) {
      return Allocate(size);
    }
  }

  hard_limit_hit_ = true;
  allocation_budget_ = -1;  // Trigger GC.
  return 0;
}

// Progress is defined as the number of bytes of objects that have been
// successfully allocated since the last GC that was forced by running out of
// memory. If we set the minimum too low then the program will slow down too
// much (effectively, hang) before declaring an out-of-memory situation.  If we
// set the minimum too high then the program will declare OOM when it could
// have continued.  This 1/(1 << 8) is 0.4%, which is a compromise that results
// in OOMs on heaps that are actually 100.4% of the required minimum size. At
// that level the program has slowed down around 30x relative to the running
// speed with unconstrained heap size.
uword OldSpace::MinimumProgress() { return 256 + (used_ >> 8); }

void OldSpace::EvaluatePointlessness() {
  ASSERT(used_ >= used_after_last_gc_);
  uword bytes_collected =
      new_space_garbage_found_since_last_gc_ + used_ - used_after_last_gc_;
  if (hard_limit_hit_ && bytes_collected < MinimumProgress()) {
    successive_pointless_gcs_++;
    if (successive_pointless_gcs_ > 3) {
      FATAL("Out of memory");
    }
  } else {
    successive_pointless_gcs_ = 0;
  }
  new_space_garbage_found_since_last_gc_ = 0;
}

void OldSpace::ReportNewSpaceProgress(uword bytes_collected) {
  uword new_total = new_space_garbage_found_since_last_gc_ + bytes_collected;
  // Guard against wraparound.
  if (new_total > new_space_garbage_found_since_last_gc_) {
    new_space_garbage_found_since_last_gc_ = new_total;
  }
}

uword OldSpace::AllocateFromFreeList(uword size) {
  // Flush the rest of the active chunk into the free list.
  Flush();

  FreeListChunk* chunk = free_list_->GetChunk(
      tracking_allocations_ ? size + PromotedTrack::kHeaderSize : size);
  if (chunk != NULL) {
    top_ = chunk->address();
    limit_ = top_ + chunk->size();
    // Account all of the chunk memory as used for now. When the
    // rest of the freelist chunk is flushed into the freelist we
    // decrement used_ by the amount still left unused. used_
    // therefore reflects actual memory usage after Flush has been
    // called.  (Do this before the tracking info below overwrites
    // the free chunk's data.)
    used_ += chunk->size();
    if (tracking_allocations_) {
      promoted_track_ =
          PromotedTrack::Initialize(promoted_track_, top_, limit_);
      top_ += PromotedTrack::kHeaderSize;
    }
    ASSERT(static_cast<unsigned>(size) <= limit_ - top_);
    return Allocate(size);
  }

  return 0;
}

uword OldSpace::Allocate(uword size) {
  ASSERT(size >= HeapObject::kSize);
  ASSERT(Utils::IsAligned(size, kPointerSize));

  // Fast case bump allocation.
  if (limit_ - top_ >= static_cast<uword>(size)) {
    uword result = top_;
    top_ += size;
    allocation_budget_ -= size;
    GCMetadata::RecordStart(result);
    return result;
  }

  if (!in_no_allocation_failure_scope() && needs_garbage_collection()) {
    return 0;
  }

  // Can't use bump allocation. Allocate from free lists.
  uword result = AllocateFromFreeList(size);
  if (result == 0) result = AllocateInNewChunk(size);
  return result;
}

uword OldSpace::Used() { return used_; }

void OldSpace::StartTrackingAllocations() {
  Flush();
  ASSERT(!tracking_allocations_);
  ASSERT(promoted_track_ == NULL);
  tracking_allocations_ = true;
}

void OldSpace::EndTrackingAllocations() {
  ASSERT(tracking_allocations_);
  ASSERT(promoted_track_ == NULL);
  tracking_allocations_ = false;
}

void OldSpace::ComputeCompactionDestinations() {
  if (is_empty()) return;
  auto it = chunk_list_.Begin();
  GCMetadata::Destination dest(it, it->start(), it->usable_end());
  for (auto chunk : chunk_list_) {
    dest = GCMetadata::CalculateObjectDestinations(chunk, dest);
  }
  dest.chunk()->set_compaction_top(dest.address);
  while (dest.HasNextChunk()) {
    dest = dest.NextChunk();
    Chunk* unused = dest.chunk();
    unused->set_compaction_top(unused->start());
  }
}

void OldSpace::ZapObjectStarts() {
  for (auto chunk : chunk_list_) {
    GCMetadata::InitializeStartsForChunk(chunk);
  }
}

void OldSpace::VisitRememberedSet(GenerationalScavengeVisitor* visitor) {
  Flush();
  for (auto chunk : chunk_list_) {
    // Scan the byte-map for cards that may have new-space pointers.
    uword current = chunk->start();
    uword bytes =
        reinterpret_cast<uword>(GCMetadata::RememberedSetFor(current));
    uword earliest_iteration_start = current;
    while (current < chunk->end()) {
      if (Utils::IsAligned(bytes, sizeof(uword))) {
        uword* words = reinterpret_cast<uword*>(bytes);
        // Skip blank cards n at a time.
        ASSERT(GCMetadata::kNoNewSpacePointers == 0);
        if (*words == 0) {
          do {
            bytes += sizeof *words;
            words++;
            current += sizeof(*words) * GCMetadata::kCardSize;
          } while (current < chunk->end() && *words == 0);
          continue;
        }
      }
      uint8* byte = reinterpret_cast<uint8*>(bytes);
      if (*byte != GCMetadata::kNoNewSpacePointers) {
        uint8* starts = GCMetadata::StartsFor(current);
        // Since there is a dirty object starting in this card, we would like
        // to assert that there is an object starting in this card.
        // Unfortunately, the sweeper does not clean the dirty object bytes,
        // and we don't want to slow down the sweeper, so we cannot make this
        // assertion in the case where a dirty object died and was made into
        // free-list.
        uword iteration_start = current;
        if (starts != GCMetadata::StartsFor(chunk->start())) {
          // If we are not at the start of the chunk, step back into previous
          // card to find a place to start iterating from that is guaranteed to
          // be before the start of the card.  We have to do this because the
          // starts-table can contain the start offset of any object in the
          // card, including objects that have higher addresses than the one(s)
          // with new-space pointers in them.
          do {
            starts--;
            iteration_start -= GCMetadata::kCardSize;
            // Step back across object-start entries that have not been filled
            // in (because of large objects).
          } while (iteration_start > earliest_iteration_start &&
                   *starts == GCMetadata::kNoObjectStart);

          if (iteration_start > earliest_iteration_start) {
            uint8 iteration_low_byte = static_cast<uint8>(iteration_start);
            iteration_start -= iteration_low_byte;
            iteration_start += *starts;
          } else {
            // Do not step back to before the end of an object that we already
            // scanned. This is both for efficiency, and also to avoid backing
            // into a PromotedTrack object, which contains newly allocated
            // objects inside it, which are not yet traversable.
            iteration_start = earliest_iteration_start;
          }
        }
        // Skip objects that start in the previous card.
        while (iteration_start < current) {
          if (HasSentinelAt(iteration_start)) break;
          HeapObject* object = HeapObject::FromAddress(iteration_start);
          iteration_start += object->Size();
        }
        // Reset in case there are no new-space pointers any more.
        *byte = GCMetadata::kNoNewSpacePointers;
        visitor->set_record_new_space_pointers(byte);
        // Iterate objects that start in the relevant card.
        while (iteration_start < current + GCMetadata::kCardSize) {
          if (HasSentinelAt(iteration_start)) break;
          HeapObject* object = HeapObject::FromAddress(iteration_start);
          object->IteratePointers(visitor);
          iteration_start += object->Size();
        }
        earliest_iteration_start = iteration_start;
      }
      current += GCMetadata::kCardSize;
      bytes++;
    }
  }
}

void OldSpace::UnlinkPromotedTrack() {
  PromotedTrack* promoted = promoted_track_;
  promoted_track_ = NULL;

  while (promoted) {
    PromotedTrack* previous = promoted;
    promoted = promoted->next();
    previous->Zap(StaticClassStructures::one_word_filler_class());
  }
}

// Called multiple times until there is no more work.  Finds objects moved to
// the old-space and traverses them to find and fix more new-space pointers.
bool OldSpace::CompleteScavengeGenerational(
    GenerationalScavengeVisitor* visitor) {
  Flush();
  ASSERT(tracking_allocations_);

  bool found_work = false;
  PromotedTrack* promoted = promoted_track_;
  // Unlink the promoted tracking list.  Any new promotions go on a new chain,
  // from now on, which will be handled in the next round.
  promoted_track_ = NULL;

  while (promoted) {
    uword traverse = promoted->start();
    uword end = promoted->end();
    if (traverse != end) {
      found_work = true;
    }
    for (HeapObject *obj = HeapObject::FromAddress(traverse); traverse != end;
         traverse += obj->Size(), obj = HeapObject::FromAddress(traverse)) {
      visitor->set_record_new_space_pointers(
          GCMetadata::RememberedSetFor(obj->address()));
      obj->IteratePointers(visitor);
    }
    PromotedTrack* previous = promoted;
    promoted = promoted->next();
    previous->Zap(StaticClassStructures::one_word_filler_class());
  }
  return found_work;
}

void OldSpace::ClearFreeList() { free_list_->Clear(); }

void OldSpace::MarkChunkEndsFree() {
  for (auto chunk : chunk_list_) {
    uword top = chunk->compaction_top();
    uword end = chunk->usable_end();
    if (top != end) free_list_->AddChunk(top, end - top);
    top = Utils::RoundUp(top, GCMetadata::kCardSize);
    GCMetadata::InitializeStartsForChunk(chunk, top);
    GCMetadata::InitializeRememberedSetForChunk(chunk, top);
  }
}

void FixPointersVisitor::VisitBlock(Object** start, Object** end) {
  for (Object** current = start; current < end; current++) {
    Object* object = *current;
    if (GCMetadata::GetPageType(object) == kOldSpacePage) {
      HeapObject* heap_object = HeapObject::cast(object);
      uword destination = GCMetadata::GetDestination(heap_object);
      *current = HeapObject::FromAddress(destination);
      ASSERT(GCMetadata::GetPageType(*current) == kOldSpacePage);
    }
  }
}

// This is faster than the builtin memmove because we know the source and
// destination are aligned and we know the size is at least 2 words.  Also
// we know that any overlap is only in one direction.
static void ALWAYS_INLINE ObjectMemMove(uword dest, uword source, uword size) {
  ASSERT(source > dest);
  ASSERT(size >= kWordSize * 2);
  uword t0 = *reinterpret_cast<uword*>(source);
  uword t1 = *reinterpret_cast<uword*>(source + kWordSize);
  *reinterpret_cast<uword*>(dest) = t0;
  *reinterpret_cast<uword*>(dest + kWordSize) = t1;
  uword end = source + size;
  source += kWordSize * 2;
  dest += kWordSize * 2;
  while (source != end) {
    *reinterpret_cast<uword*>(dest) = *reinterpret_cast<uword*>(source);
    source += kWordSize;
    dest += kWordSize;
  }
}

static int ALWAYS_INLINE FindFirstSet(uint32 x) {
#ifdef _MSC_VER
  unsigned long index;  // NOLINT
  bool non_zero = _BitScanForward(&index, x);
  return index + non_zero;
#else
  return __builtin_ffs(x);
#endif
}

CompactingVisitor::CompactingVisitor(OldSpace* space,
                                     FixPointersVisitor* fix_pointers_visitor)
    : used_(0),
      dest_(space->ChunkListBegin(), space->ChunkListEnd()),
      fix_pointers_visitor_(fix_pointers_visitor) {}

uword CompactingVisitor::Visit(HeapObject* object) {
  uint32* bits_addr = GCMetadata::MarkBitsFor(object);
  int pos = GCMetadata::WordIndexInLine(object);
  uint32 bits = *bits_addr >> pos;
  if ((bits & 1) == 0) {
    // Object is unmarked.
    if (bits != 0) return (FindFirstSet(bits) - 1) << GCMetadata::kWordShift;
    // If all the bits in this mark word are zero, then let's see if we can
    // skip a bit more.
    uword next_live_object =
        object->address() + ((32 - pos) << GCMetadata::kWordShift);
    // This never runs over the end of the chunk because the last word in the
    // chunk (the sentinel) is artificially marked live.
    while (*++bits_addr == 0) next_live_object += GCMetadata::kCardSize;
    next_live_object += (FindFirstSet(*bits_addr) - 1)
                        << GCMetadata::kWordShift;
    ASSERT(next_live_object - object->address() >= (uword)object->Size());
    return next_live_object - object->address();
  }

  // Object is marked.
  uword size = object->Size();
  // Unless we have large objects and small chunks max one iteration of this
  // loop is needed to move on to the next destination chunk.
  while (dest_.address + size > dest_.limit) {
    dest_ = dest_.NextSweepingChunk();
  }
  ASSERT(dest_.address == GCMetadata::GetDestination(object));
  GCMetadata::RecordStart(dest_.address);
  if (object->address() != dest_.address) {
    ObjectMemMove(dest_.address, object->address(), size);

    if (*GCMetadata::RememberedSetFor(object->address()) !=
        GCMetadata::kNoNewSpacePointers) {
      *GCMetadata::RememberedSetFor(dest_.address) =
          GCMetadata::kNewSpacePointers;
    }
  }

  fix_pointers_visitor_->set_source_address(object->address());
  HeapObject::FromAddress(dest_.address)
      ->IteratePointers(fix_pointers_visitor_);
  used_ += size;
  dest_.address += size;
  return size;
}

SweepingVisitor::SweepingVisitor(OldSpace* space)
    : free_list_(space->free_list()), free_start_(0), used_(0) {
  // Clear the free list. It will be rebuilt during sweeping.
  free_list_->Clear();
}

void SweepingVisitor::AddFreeListChunk(uword free_end) {
  if (free_start_ != 0) {
    uword free_size = free_end - free_start_;
    free_list_->AddChunk(free_start_, free_size);
    free_start_ = 0;
  }
}

uword SweepingVisitor::Visit(HeapObject* object) {
  if (GCMetadata::IsMarked(object)) {
    AddFreeListChunk(object->address());
    GCMetadata::RecordStart(object->address());
    uword size = object->Size();
    used_ += size;
    return size;
  }
  uword size = object->Size();
  if (free_start_ == 0) free_start_ = object->address();
  return size;
}

void FixPointersVisitor::AboutToVisitStack(Stack* stack) {
  if (source_address_ != 0) {
    stack->UpdateFramePointers(stack->address() - source_address_);
  }
}

void OldSpace::ProcessWeakPointers() {
  WeakPointer::Process(&weak_pointers_, this);
}

#ifdef DEBUG
void OldSpace::Verify() {
  // Verify that the object starts table contains only legitimate object start
  // addresses for each chunk in the space.
  for (auto chunk : chunk_list_) {
    uword base = chunk->start();
    uword limit = chunk->end();
    uint8* starts = GCMetadata::StartsFor(base);
    for (uword card = base; card < limit;
         card += GCMetadata::kCardSize, starts++) {
      if (*starts == GCMetadata::kNoObjectStart) continue;
      // Replace low byte of card address with the byte from the object starts
      // table, yielding some correct object start address.
      uword object_address = GCMetadata::ObjectAddressFromStart(card, *starts);
      HeapObject* obj = HeapObject::FromAddress(object_address);
      ASSERT(obj->get_class()->IsClass());
      ASSERT(obj->Size() > 0);
      if (object_address + obj->Size() > card + 2 * GCMetadata::kCardSize) {
        // If this object stretches over the whole of the next card then the
        // next entry in the object starts table must be invalid.
        ASSERT(starts[1] == GCMetadata::kNoObjectStart);
      }
    }
  }
  // Verify that the remembered set table is marked for all objects that
  // contain new-space pointers.
  for (auto chunk : chunk_list_) {
    uword current = chunk->start();
    while (!HasSentinelAt(current)) {
      HeapObject* object = HeapObject::FromAddress(current);
      if (object->ContainsPointersTo(heap_->space())) {
        ASSERT(*GCMetadata::RememberedSetFor(current));
      }
      current += object->Size();
    }
  }
}
#endif

void MarkingStack::Empty(PointerVisitor* visitor) {
  while (!IsEmpty()) {
    HeapObject* object = *--next_;
    GCMetadata::MarkAll(object, object->Size());
    object->IteratePointers(visitor);
  }
}

void MarkingStack::Process(PointerVisitor* visitor, Space* old_space,
                           Space* new_space) {
  while (!IsEmpty() || IsOverflowed()) {
    Empty(visitor);
    if (IsOverflowed()) {
      ClearOverflow();
      old_space->IterateOverflowedObjects(visitor, this);
      new_space->IterateOverflowedObjects(visitor, this);
    }
  }
}

}  // namespace dartino
