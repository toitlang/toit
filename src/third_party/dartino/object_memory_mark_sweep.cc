// Copyright (c) 2015, the Dartino project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.
// Mark-sweep old-space.
// * Uses worst-fit free-list allocation to get big regions for fast bump
//   allocation.
// * Non-moving for now.
// * Has on-heap chained data structure keeping track of
//   promoted-and-not-yet-scanned areas.  This is called PromotedTrack.
// * No remembered set yet.  When scavenging we have to scan all of old space.
//   We skip PromotedTrack areas because we know we will get to them later and
//   they contain uninitialized memory.

#include "../../utils.h"
#include "../../object.h"
#include "mark_sweep.h"
#include "object_memory.h"

#ifdef _MSC_VER
#include <intrin.h>
#pragma intrinsic(_BitScanForward)
#endif

namespace toit {

OldSpace::OldSpace(TwoSpaceHeap* owner)
    : Space(CAN_RESIZE, OLD_SPACE_PAGE),
      heap_(owner),
      free_list_(new FreeList()) {}

OldSpace::~OldSpace() { delete free_list_; }

void OldSpace::flush() {
  if (top_ != 0) {
    uword free_size = limit_ - top_;
    free_list_->add_region(top_, free_size);
    if (tracking_allocations_ && promoted_track_ != null) {
      // The latest promoted_track_ entry is set to cover the entire
      // current allocation area, so that we skip it when traversing the
      // stack.  Reset it to cover only the bit we actually used.
      ASSERT(promoted_track_ != null);
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

HeapObject* OldSpace::new_location(HeapObject* old_location) {
  ASSERT(includes(old_location->address()));
  ASSERT(GcMetadata::is_marked(old_location));
  if (compacting_) {
    return HeapObject::from_address(GcMetadata::get_destination(old_location));
  } else {
    return old_location;
  }
}

bool OldSpace::is_alive(HeapObject* old_location) {
  ASSERT(includes(old_location->address()));
  return GcMetadata::is_marked(old_location);
}

void OldSpace::use_whole_chunk(Chunk* chunk) {
  top_ = chunk->start();
  limit_ = top_ + chunk->size() - WORD_SIZE;
  *reinterpret_cast<Object**>(limit_) = chunk_end_sentinel();
  if (tracking_allocations_) {
    promoted_track_ = PromotedTrack::initialize(promoted_track_, top_, limit_);
    top_ += PromotedTrack::HEADER_SIZE;
  }
  // Account all of the chunk memory as used for now. When the
  // rest of the freelist chunk is flushed into the freelist we
  // decrement used_ by the amount still left unused. used_
  // therefore reflects actual memory usage after flush has been
  // called.
  used_ += chunk->size() - WORD_SIZE;
}

Chunk* OldSpace::allocate_and_use_chunk(uword size) {
  Chunk* chunk = ObjectMemory::allocate_chunk(this, size);
  if (chunk != null) {
    // Link it into the space.
    append(chunk);
    use_whole_chunk(chunk);
    GcMetadata::initialize_starts_for_chunk(chunk);
    GcMetadata::initialize_remembered_set_for_chunk(chunk);
    GcMetadata::clear_mark_bits_for(chunk);
  }
  return chunk;
}

uword OldSpace::allocate_in_new_chunk(uword size) {
  ASSERT(top_ == 0);  // Space is flushed.
  // Allocate new chunk that is big enough to fit the object.
  int tracking_size = tracking_allocations_ ? 0 : PromotedTrack::HEADER_SIZE;
  uword max_expansion = heap_->max_expansion();
  uword smallest_chunk_size =
      Utils::min(default_chunk_size(used()), max_expansion);
  uword chunk_size =
      (size + tracking_size + WORD_SIZE >= smallest_chunk_size)
          ? (size + tracking_size + WORD_SIZE)  // Make room for sentinel.
          : smallest_chunk_size;

  if (chunk_size <= max_expansion) {
    if (chunk_size + (chunk_size >> 1) > max_expansion) {
      // If we are near the limit, then just get memory up to the limit from
      // the OS to reduce the number of small chunks in the heap, which can
      // cause some fragmentation.
      chunk_size = max_expansion;
    }

    Chunk* chunk = allocate_and_use_chunk(chunk_size);
    if (chunk != null) {
      return allocate(size);
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
uword OldSpace::minimum_progress() { return 256 + (used_ >> 8); }

void OldSpace::evaluate_pointlessness() {
  ASSERT(used_ >= used_after_last_gc_);
  uword bytes_collected =
      new_space_garbage_found_since_last_gc_ + used_ - used_after_last_gc_;
  if (hard_limit_hit_ && bytes_collected < minimum_progress()) {
    successive_pointless_gcs_++;
    if (successive_pointless_gcs_ > 3) {
      FATAL("Out of memory");
    }
  } else {
    successive_pointless_gcs_ = 0;
  }
  new_space_garbage_found_since_last_gc_ = 0;
}

void OldSpace::report_new_space_progress(uword bytes_collected) {
  uword new_total = new_space_garbage_found_since_last_gc_ + bytes_collected;
  // Guard against wraparound.
  if (new_total > new_space_garbage_found_since_last_gc_) {
    new_space_garbage_found_since_last_gc_ = new_total;
  }
}

uword OldSpace::allocate_from_free_list(uword size) {
  // Flush the rest of the active region into the free list.
  flush();

  FreeListRegion* region = free_list_->get_region(
      tracking_allocations_ ? size + PromotedTrack::HEADER_SIZE : size);
  if (region != null) {
    top_ = region->address();
    limit_ = top_ + region->size();
    // Account all of the region's memory as used for now. When the
    // rest of the freelist region is flushed into the freelist we
    // decrement used_ by the amount still left unused. used_
    // therefore reflects actual memory usage after Flush has been
    // called.  (Do this before the tracking info below overwrites
    // the free region's data.)
    used_ += region->size();
    if (tracking_allocations_) {
      promoted_track_ =
          PromotedTrack::initialize(promoted_track_, top_, limit_);
      top_ += PromotedTrack::HEADER_SIZE;
    }
    ASSERT(static_cast<unsigned>(size) <= limit_ - top_);
    return allocate(size);
  }

  return 0;
}

uword OldSpace::allocate(uword size) {
  ASSERT(size >= HeapObject::SIZE);
  ASSERT(Utils::is_aligned(size, WORD_SIZE));

  // Fast case bump allocation.
  if (limit_ - top_ >= static_cast<uword>(size)) {
    uword result = top_;
    top_ += size;
    allocation_budget_ -= size;
    GcMetadata::record_start(result);
    return result;
  }

  if (!in_no_allocation_failure_scope() && needs_garbage_collection()) {
    return 0;
  }

  // Can't use bump allocation. Allocate from free lists.
  uword result = allocate_from_free_list(size);
  if (result == 0) result = allocate_in_new_region(size);
  return result;
}

uword OldSpace::used() { return used_; }

void OldSpace::StartTrackingAllocations() {
  Flush();
  ASSERT(!tracking_allocations_);
  ASSERT(promoted_track_ == null);
  tracking_allocations_ = true;
}

void OldSpace::EndTrackingAllocations() {
  ASSERT(tracking_allocations_);
  ASSERT(promoted_track_ == null);
  tracking_allocations_ = false;
}

void OldSpace::ComputeCompactionDestinations() {
  if (is_empty()) return;
  auto it = chunk_list_.begin();
  GcMetadata::Destination dest(it, it->start(), it->usable_end());
  for (auto chunk : chunk_list_) {
    dest = GcMetadata::CalculateObjectDestinations(chunk, dest);
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
    GcMetadata::initialize_starts_for_chunk(chunk);
  }
}

void OldSpace::VisitRememberedSet(GenerationalScavengeVisitor* visitor) {
  Flush();
  for (auto chunk : chunk_list_) {
    // Scan the byte-map for cards that may have new-space pointers.
    uword current = chunk->start();
    uword bytes =
        reinterpret_cast<uword>(GcMetadata::remembered_set_for(current));
    uword earliest_iteration_start = current;
    while (current < chunk->end()) {
      if (Utils::is_aligned(bytes, sizeof(uword))) {
        uword* words = reinterpret_cast<uword*>(bytes);
        // Skip blank cards n at a time.
        ASSERT(GcMetadata::NO_NEW_SPACE_POINTERS == 0);
        if (*words == 0) {
          do {
            bytes += sizeof *words;
            words++;
            current += sizeof(*words) * GcMetadata::CARD_SIZE;
          } while (current < chunk->end() && *words == 0);
          continue;
        }
      }
      uint8* byte = reinterpret_cast<uint8*>(bytes);
      if (*byte != GcMetadata::NO_NEW_SPACE_POINTERS) {
        uint8* starts = GcMetadata::starts_for(current);
        // Since there is a dirty object starting in this card, we would like
        // to assert that there is an object starting in this card.
        // Unfortunately, the sweeper does not clean the dirty object bytes,
        // and we don't want to slow down the sweeper, so we cannot make this
        // assertion in the case where a dirty object died and was made into
        // free-list.
        uword iteration_start = current;
        if (starts != GcMetadata::starts_for(chunk->start())) {
          // If we are not at the start of the chunk, step back into previous
          // card to find a place to start iterating from that is guaranteed to
          // be before the start of the card.  We have to do this because the
          // starts-table can contain the start offset of any object in the
          // card, including objects that have higher addresses than the one(s)
          // with new-space pointers in them.
          do {
            starts--;
            iteration_start -= GcMetadata::CARD_SIZE;
            // Step back across object-start entries that have not been filled
            // in (because of large objects).
          } while (iteration_start > earliest_iteration_start &&
                   *starts == GcMetadata::NO_OBJECT_START);

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
          if (has_sentinel_at(iteration_start)) break;
          HeapObject* object = HeapObject::from_address(iteration_start);
          iteration_start += object->size();
        }
        // Reset in case there are no new-space pointers any more.
        *byte = GcMetadata::NO_NEW_SPACE_POINTERS;
        visitor->set_record_new_space_pointers(byte);
        // Iterate objects that start in the relevant card.
        while (iteration_start < current + GcMetadata::CARD_SIZE) {
          if (has_sentinel_at(iteration_start)) break;
          HeapObject* object = HeapObject::from_address(iteration_start);
          object->roots_do(program_, visitor);
          iteration_start += object->size();
        }
        earliest_iteration_start = iteration_start;
      }
      current += GcMetadata::CARD_SIZE;
      bytes++;
    }
  }
}

void OldSpace::UnlinkPromotedTrack() {
  PromotedTrack* promoted = promoted_track_;
  promoted_track_ = null;

  while (promoted) {
    PromotedTrack* previous = promoted;
    promoted = promoted->next();
    previous->Zap(StaticClassStructures::one_word_filler_class());
  }
}

// Called multiple times until there is no more work.  Finds objects moved to
// the old-space and traverses them to find and fix more new-space pointers.
bool OldSpace::complete_scavenge_generational(
    GenerationalScavengeVisitor* visitor) {
  Flush();
  ASSERT(tracking_allocations_);

  bool found_work = false;
  PromotedTrack* promoted = promoted_track_;
  // Unlink the promoted tracking list.  Any new promotions go on a new chain,
  // from now on, which will be handled in the next round.
  promoted_track_ = null;

  while (promoted) {
    uword traverse = promoted->start();
    uword end = promoted->end();
    if (traverse != end) {
      found_work = true;
    }
    for (HeapObject *obj = HeapObject::from_address(traverse); traverse != end;
         traverse += obj->size(), obj = HeapObject::from_address(traverse)) {
      visitor->set_record_new_space_pointers(
          GcMetadata::remembered_set_for(obj->address()));
      obj->roots_do(program_, visitor);
    }
    PromotedTrack* previous = promoted;
    promoted = promoted->next();
    previous->Zap(StaticClassStructures::one_word_filler_class());
  }
  return found_work;
}

void OldSpace::clear_free_list() { free_list_->clear(); }

void OldSpace::mark_chunk_ends_free() {
  for (auto chunk : chunk_list_) {
    uword top = chunk->compaction_top();
    uword end = chunk->usable_end();
    if (top != end) free_list_->add_region(top, end - top);
    top = Utils::round_up(top, GcMetadata::CARD_SIZE);
    GcMetadata::initialize_starts_for_chunk(chunk, top);
    GcMetadata::initialize_remembered_set_for_chunk(chunk, top);
  }
}

void FixPointersVisitor::visit_block(Object** start, Object** end) {
  for (Object** current = start; current < end; current++) {
    Object* object = *current;
    if (GcMetadata::GetPageType(object) == OLD_SPACE_PAGE) {
      HeapObject* heap_object = HeapObject::cast(object);
      uword destination = GcMetadata::get_destination(heap_object);
      *current = HeapObject::from_address(destination);
      ASSERT(GcMetadata::GetPageType(*current) == OLD_SPACE_PAGE);
    }
  }
}

// This is faster than the builtin memmove because we know the source and
// destination are aligned and we know the size is at least 2 words.  Also
// we know that any overlap is only in one direction.
static void INLINE object_mem_move(uword dest, uword source, uword size) {
  ASSERT(source > dest);
  ASSERT(size >= WORD_SIZE * 2);
  uword t0 = *reinterpret_cast<uword*>(source);
  uword t1 = *reinterpret_cast<uword*>(source + WORD_SIZE);
  *reinterpret_cast<uword*>(dest) = t0;
  *reinterpret_cast<uword*>(dest + WORD_SIZE) = t1;
  uword end = source + size;
  source += WORD_SIZE * 2;
  dest += WORD_SIZE * 2;
  while (source != end) {
    *reinterpret_cast<uword*>(dest) = *reinterpret_cast<uword*>(source);
    source += WORD_SIZE;
    dest += WORD_SIZE;
  }
}

static int INLINE find_first_set(uint32 x) {
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

uword CompactingVisitor::visit(HeapObject* object) {
  uint32* bits_addr = GcMetadata::mark_bits_for(object);
  int pos = GcMetadata::word_index_in_line(object);
  uint32 bits = *bits_addr >> pos;
  if ((bits & 1) == 0) {
    // Object is unmarked.
    if (bits != 0) return (find_first_set(bits) - 1) << WORD_SIZE_LOG_2;
    // If all the bits in this mark word are zero, then let's see if we can
    // skip a bit more.
    uword next_live_object =
        object->address() + ((32 - pos) << WORD_SIZE_LOG_2);
    // This never runs over the end of the chunk because the last word in the
    // chunk (the sentinel) is artificially marked live.
    while (*++bits_addr == 0) next_live_object += GcMetadata::CARD_SIZE;
    next_live_object += (find_first_set(*bits_addr) - 1) << WORD_SIZE_LOG_2;
    ASSERT(next_live_object - object->address() >= (uword)object->size());
    return next_live_object - object->address();
  }

  // Object is marked.
  uword size = object->size();
  // Unless we have large objects and small chunks max one iteration of this
  // loop is needed to move on to the next destination chunk.
  while (dest_.address + size > dest_.limit) {
    dest_ = dest_.next_sweeping_chunk();
  }
  ASSERT(dest_.address == GcMetadata::get_destination(object));
  GcMetadata::record_start(dest_.address);
  if (object->address() != dest_.address) {
    object_mem_move(dest_.address, object->address(), size);

    if (*GcMetadata::remembered_set_for(object->address()) !=
        GcMetadata::NO_NEW_SPACE_POINTERS) {
      *GcMetadata::remembered_set_for(dest_.address) =
          GcMetadata::NEW_SPACE_POINTERS;
    }
  }

  fix_pointers_visitor_->set_source_address(object->address());
  HeapObject::from_address(dest_.address)->roots_do(program_, fix_pointers_visitor_);
  used_ += size;
  dest_.address += size;
  return size;
}

SweepingVisitor::SweepingVisitor(OldSpace* space)
    : free_list_(space->free_list()), free_start_(0), used_(0) {
  // Clear the free list. It will be rebuilt during sweeping.
  free_list_->clear();
}

void SweepingVisitor::add_free_list_region(uword free_end) {
  if (free_start_ != 0) {
    uword free_size = free_end - free_start_;
    free_list_->add_region(free_start_, free_size);
    free_start_ = 0;
  }
}

uword SweepingVisitor::visit(HeapObject* object) {
  if (GcMetadata::is_marked(object)) {
    add_free_list_region(object->address());
    GcMetadata::record_start(object->address());
    uword size = object->size();
    used_ += size;
    return size;
  }
  uword size = object->size();
  if (free_start_ == 0) free_start_ = object->address();
  return size;
}

void OldSpace::process_weak_pointers() {
  WeakPointer::process(&weak_pointers_, this);
}

#ifdef DEBUG
void OldSpace::verify() {
  // Verify that the object starts table contains only legitimate object start
  // addresses for each chunk in the space.
  for (auto chunk : chunk_list_) {
    uword base = chunk->start();
    uword limit = chunk->end();
    uint8* starts = GcMetadata::starts_for(base);
    for (uword card = base; card < limit;
         card += GcMetadata::CARD_SIZE, starts++) {
      if (*starts == GcMetadata::NO_OBJECT_START) continue;
      // Replace low byte of card address with the byte from the object starts
      // table, yielding some correct object start address.
      uword object_address = GcMetadata::object_address_from_start(card, *starts);
      HeapObject* obj = HeapObject::from_address(object_address);
      ASSERT(obj->get_class()->is_class());
      ASSERT(obj->size() > 0);
      if (object_address + obj->size() > card + 2 * GcMetadata::CARD_SIZE) {
        // If this object stretches over the whole of the next card then the
        // next entry in the object starts table must be invalid.
        ASSERT(starts[1] == GcMetadata::NO_OBJECT_START);
      }
    }
  }
  // Verify that the remembered set table is marked for all objects that
  // contain new-space pointers.
  for (auto chunk : chunk_list_) {
    uword current = chunk->start();
    while (!has_sentinel_at(current)) {
      HeapObject* object = HeapObject::from_address(current);
      if (object->contains_pointers_to(heap_->space())) {
        ASSERT(*GcMetadata::remembered_set_for(current));
      }
      current += object->size();
    }
  }
}
#endif

void MarkingStack::empty(RootCallback* visitor) {
  while (!is_empty()) {
    HeapObject* object = *--next_;
    GcMetadata::mark_all(object, object->size());
    object->roots_do(program_, visitor);
  }
}

void MarkingStack::process(RootCallback* visitor, Space* old_space,
                           Space* new_space) {
  while (!is_empty() || is_overflowed()) {
    empty(visitor);
    if (is_overflowed()) {
      clear_overflow();
      old_space->iterate_overflowed_objects(visitor, this);
      new_space->iterate_overflowed_objects(visitor, this);
    }
  }
}

}  // namespace toit
