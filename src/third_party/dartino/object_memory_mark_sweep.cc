// Copyright (c) 2022, the Dartino project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

#include "../../top.h"

#ifndef LEGACY_GC

#include "../../utils.h"
#include "../../objects.h"
#include "mark_sweep.h"
#include "object_memory.h"
#include "two_space_heap.h"

#ifdef _MSC_VER
#include <intrin.h>
#pragma intrinsic(_BitScanForward)
#endif

namespace toit {

OldSpace::OldSpace(Program* program, TwoSpaceHeap* owner)
    : Space(program, CAN_RESIZE, OLD_SPACE_PAGE),
      heap_(owner) {}

OldSpace::~OldSpace() { }

void OldSpace::flush() {
  if (top_ != 0) {
    uword free_size = limit_ - top_;
    free_list_.add_region(top_, free_size);
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
  ASSERT(includes(old_location->_raw()));
  ASSERT(GcMetadata::is_marked(old_location));
  if (compacting_) {
    return HeapObject::from_address(GcMetadata::get_destination(old_location));
  } else {
    return old_location;
  }
}

bool OldSpace::is_alive(HeapObject* old_location) {
  // We can't assert that the object is in old-space, because
  // at the end of a mark-sweep the new-space objects are also
  // marked and can be checked for liveness.  The finalizers
  // for new-space objects can thus be run at the end of a mark-
  // sweep GC.  This removes them from the finalizer list, but
  // they will remain (untouched) in the new-space until the
  // next scavenge.
  return GcMetadata::is_marked(old_location);
}

void OldSpace::use_whole_chunk(Chunk* chunk) {
  top_ = chunk->start();
  limit_ = top_ + chunk->size() - WORD_SIZE;
  *reinterpret_cast<Object**>(limit_) = chunk_end_sentinel();
  if (tracking_allocations_) {
    promoted_track_ = PromotedTrack::initialize(promoted_track_, top_, limit_);
    top_ += PromotedTrack::header_size();
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
    GcMetadata::clear_mark_bits_for_chunk(chunk);
  }
  return chunk;
}

uword OldSpace::allocate_in_new_chunk(uword size) {
  if (allocation_budget_ < 0) return 0;
  ASSERT(top_ == 0);  // Space is flushed.
  // Allocate new chunk.  After a certain heap size we start allocating
  // multi-page chunks to improve fragmentation.
  int tracking_size = tracking_allocations_ ? 0 : PromotedTrack::header_size();
  uword max_expansion = heap_->max_expansion();
  uword smallest_chunk_size = Utils::min(get_default_chunk_size(used()), max_expansion);
  uword max_space_needed = size + tracking_size + WORD_SIZE;  // Make room for sentinel.
  // Toit uses arraylets and external objects, so all objects should fit on a page.
  ASSERT(max_space_needed <= TOIT_PAGE_SIZE);
  uword chunk_size = Utils::max(max_space_needed, smallest_chunk_size);

  if (chunk_size <= max_expansion) {
    chunk_size = Utils::round_up(chunk_size, TOIT_PAGE_SIZE);
    Chunk* chunk = allocate_and_use_chunk(chunk_size);
    while (chunk == null && chunk_size > TOIT_PAGE_SIZE) {
      // If we fail to get a multi-page chunk, try for a smaller chunk.
      chunk_size = Utils::round_up(chunk_size >> 1, TOIT_PAGE_SIZE);
      chunk = allocate_and_use_chunk(chunk_size);
    }
    if (chunk != null) {
      return allocate(size);
    } else {
      heap_->report_malloc_failed();
    }
  }

  // Speed up later attempts during this scavenge to promote objects.
  allocation_budget_ = -1;
  return 0;
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

  FreeListRegion* region = free_list_.get_region(
      tracking_allocations_ ? size + PromotedTrack::header_size() : size);
  if (region != null) {
    top_ = region->_raw();
    limit_ = top_ + region->size();
    // Account all of the region's memory as used for now. When the
    // rest of the freelist region is flushed into the freelist we
    // decrement used_ by the amount still left unused. used_
    // therefore reflects actual memory usage after flush has been
    // called.  (Do this before the tracking info below overwrites
    // the free region's data.)
    used_ += region->size();
    if (tracking_allocations_) {
      promoted_track_ =
          PromotedTrack::initialize(promoted_track_, top_, limit_);
      top_ += PromotedTrack::header_size();
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

  if (needs_garbage_collection()) {
    return 0;
  }

  // Can't use bump allocation. Allocate from free lists.
  uword result = allocate_from_free_list(size);
  if (result == 0) result = allocate_in_new_chunk(size);
  return result;
}

uword OldSpace::used() { return used_; }

void OldSpace::start_tracking_allocations() {
  flush();
  ASSERT(!tracking_allocations_);
  ASSERT(promoted_track_ == null);
  tracking_allocations_ = true;
}

void OldSpace::end_tracking_allocations() {
  ASSERT(tracking_allocations_);
  ASSERT(promoted_track_ == null);
  tracking_allocations_ = false;
}

void OldSpace::compute_compaction_destinations() {
  if (is_empty()) return;
  auto it = chunk_list_.begin();
  GcMetadata::Destination dest(it, it->start(), it->usable_end());
  for (auto chunk : chunk_list_) {
    dest = GcMetadata::calculate_object_destinations(program_, chunk, dest);
  }
  dest.chunk()->set_compaction_top(dest.address);
  while (dest.has_next_chunk()) {
    dest = dest.next_chunk();
    Chunk* unused = dest.chunk();
    unused->set_compaction_top(unused->start());
  }
}

void OldSpace::zap_object_starts() {
  for (auto chunk : chunk_list_) {
    GcMetadata::initialize_starts_for_chunk(chunk);
  }
}

class RememberedSetRebuilder2 : public RootCallback {
 public:
  virtual void do_roots(Object** pointers, int length) override {
    for (int i = 0; i < length; i++) {
      Object* object = pointers[i];
      if (GcMetadata::get_page_type(object) == NEW_SPACE_PAGE) {
        found = true;
        break;
      }
    }
  }

  bool found;
};

class RememberedSetRebuilder : public HeapObjectVisitor {
 public:
  RememberedSetRebuilder(Program* program) : HeapObjectVisitor(program) {}

  virtual uword visit(HeapObject* object) override {
    pointer_callback.found = false;
    object->roots_do(program_, &pointer_callback);
    if (pointer_callback.found) {
      *GcMetadata::remembered_set_for(reinterpret_cast<uword>(object)) = GcMetadata::NEW_SPACE_POINTERS;
    }
    return object->size(program_);
  }

 private:
  RememberedSetRebuilder2 pointer_callback;
};

// Until we have a write barrier we have to iterate the whole
// of old space.
void OldSpace::rebuild_remembered_set() {
  RememberedSetRebuilder rebuilder(program_);
  iterate_objects(&rebuilder);
}

void OldSpace::visit_remembered_set(ScavengeVisitor* visitor) {
  flush();
  for (auto chunk : chunk_list_) {
    // Scan the byte-map for cards that may have new-space pointers.
    uword current = chunk->start();
    uword bytes = reinterpret_cast<uword>(GcMetadata::remembered_set_for(current));
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
          iteration_start += object->size(program_);
        }
        // Reset in case there are no new-space pointers any more.
        *byte = GcMetadata::NO_NEW_SPACE_POINTERS;
        visitor->set_record_new_space_pointers(byte);
        // Iterate objects that start in the relevant card.
        while (iteration_start < current + GcMetadata::CARD_SIZE) {
          if (has_sentinel_at(iteration_start)) break;
          HeapObject* object = HeapObject::from_address(iteration_start);
          object->roots_do(program_, visitor);
          iteration_start += object->size(program_);
        }
        earliest_iteration_start = iteration_start;
      }
      current += GcMetadata::CARD_SIZE;
      bytes++;
    }
  }
}

void OldSpace::unlink_promoted_track() {
  PromotedTrack* promoted = promoted_track_;
  promoted_track_ = null;

  while (promoted) {
    PromotedTrack* previous = promoted;
    promoted = promoted->next();
    previous->zap();
  }
}

void OldSpace::start_scavenge() {
  start_tracking_allocations();
}

// Called multiple times until there is no more work.  Finds objects moved to
// the old-space and traverses them to find and fix more new-space pointers.
bool OldSpace::complete_scavenge(
    ScavengeVisitor* visitor) {
  flush();
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
         traverse += obj->size(program_), obj = HeapObject::from_address(traverse)) {
      visitor->set_record_new_space_pointers(GcMetadata::remembered_set_for(obj->_raw()));
      obj->roots_do(program_, visitor);
    }
    PromotedTrack* previous = promoted;
    promoted = promoted->next();
    previous->zap();
  }
  return found_work;
}

void OldSpace::end_scavenge() {
  end_tracking_allocations();
}

void OldSpace::clear_free_list() { free_list_.clear(); }

void OldSpace::mark_chunk_ends_free() {
  chunk_list_.remove_wherever([&](Chunk* chunk) -> bool {
    uword top = chunk->compaction_top();
    if (top == chunk->start()) {
      ObjectMemory::free_chunk(chunk);
      return true;  // Remove empty chunks from list.
    }
    uword end = chunk->usable_end();
    if (top != end) free_list_.add_region(top, end - top);
    top = Utils::round_up(top, GcMetadata::CARD_SIZE);
    GcMetadata::initialize_starts_for_chunk(chunk, top);
    GcMetadata::initialize_remembered_set_for_chunk(chunk, top);
    return false;
  });
}

void FixPointersVisitor::do_roots(Object** start, int length) {
  Object** end = start + length;
  for (Object** current = start; current < end; current++) {
    Object* object = *current;
    if (GcMetadata::get_page_type(object) == OLD_SPACE_PAGE) {
      HeapObject* heap_object = HeapObject::cast(object);
      uword destination = GcMetadata::get_destination(heap_object);
      *current = HeapObject::from_address(destination);
      ASSERT(GcMetadata::get_page_type(*current) == OLD_SPACE_PAGE);
    }
  }
}

// This is faster than the builtin memmove because we know the source and
// destination are aligned and we know the size is at least 1 word.  Also
// we know that any overlap is only in one direction.
// TODO(Erik): Check this is still true on ESP32.
static void INLINE object_mem_move(uword dest, uword source, uword size) {
  ASSERT(source > dest);
  ASSERT(size >= WORD_SIZE);
  uword t0 = *reinterpret_cast<uword*>(source);
  *reinterpret_cast<uword*>(dest) = t0;
  uword end = source + size;
  source += WORD_SIZE;
  dest += WORD_SIZE;
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

CompactingVisitor::CompactingVisitor(Program* program,
                                     OldSpace* space,
                                     FixPointersVisitor* fix_pointers_visitor)
    : HeapObjectVisitor(program),
      used_(0),
      dest_(space->chunk_list_begin(), space->chunk_list_end()),
      fix_pointers_visitor_(fix_pointers_visitor) {}

uword CompactingVisitor::visit(HeapObject* object) {
  uint32* bits_addr = GcMetadata::mark_bits_for(object);
  int pos = GcMetadata::word_index_in_line(object);
  uint32 bits = *bits_addr >> pos;
  if ((bits & 1) == 0) {
    // Object is unmarked.
    if (bits != 0) {
      return (find_first_set(bits) - 1) << WORD_SIZE_LOG_2;
    }
    // If all the bits in this mark word are zero, then let's see if we can
    // skip a bit more.
    uword next_live_object = object->_raw() + ((32 - pos) << WORD_SIZE_LOG_2);
    // This never runs over the end of the chunk because the last word in the
    // chunk (the sentinel) is artificially marked live.
    while (*++bits_addr == 0) next_live_object += GcMetadata::CARD_SIZE;
    next_live_object += (find_first_set(*bits_addr) - 1) << WORD_SIZE_LOG_2;
    ASSERT(next_live_object - object->_raw() >= (uword)object->size(program_));
    return next_live_object - object->_raw();
  }

  // Object is marked.
  uword size = object->size(program_);
  // Unless we have large objects and small chunks max one iteration of this
  // loop is needed to move on to the next destination chunk.
  while (dest_.address + size > dest_.limit) {
    dest_ = dest_.next_sweeping_chunk();
  }
  ASSERT(dest_.address == GcMetadata::get_destination(object));
  GcMetadata::record_start(dest_.address);
  if (object->_raw() != dest_.address) {
    object_mem_move(dest_.address, object->_raw(), size);

    if (*GcMetadata::remembered_set_for(object->_raw()) !=
        GcMetadata::NO_NEW_SPACE_POINTERS) {
      *GcMetadata::remembered_set_for(dest_.address) =
          GcMetadata::NEW_SPACE_POINTERS;
    }
  }

  HeapObject::from_address(dest_.address)->roots_do(program_, fix_pointers_visitor_);
  used_ += size;
  dest_.address += size;
  return size;
}

// Sweep method that mostly looks at the mark bits.  For speed it doesn't touch
// the live objects, but writes freelist structures in the gaps between them.
uword OldSpace::sweep() {
  // Clear the free list. It will be rebuilt during sweeping.
  free_list_.clear();
  uword used = 0;
  const word SINGLE_FREE_WORD = -44;
  ASSERT(reinterpret_cast<Object*>(SINGLE_FREE_WORD) == FreeListRegion::single_free_word_header());
  for (auto chunk : chunk_list_) {
    uword line = chunk->start();
    uword end = line + chunk->size();
    uint32* mark_bits = GcMetadata::mark_bits_for(chunk->start());
    while (line < end) {
      ASSERT(mark_bits == GcMetadata::mark_bits_for(line));
      // Only put complete empty lines on the freelist.
      uint32 bits = *mark_bits;
      if (bits != 0) {
        if (bits != 0xffffffff) {
          // Not entirely free.  Zap any free words with single-word marker.
          // We may end up zapping the tail of a free area here, but that's
          // OK because the FreeListRegion header is only 3 words and the free
          // areas are at least 32 words long.
          // The object starts may end up pointing at one of these single free
          // word things, but that's OK because they are iterable.
          // TODO: Use fast SIMD instructions to write these 32 pointers.
          for (int i = 0; i < GcMetadata::CARD_SIZE / WORD_SIZE; i++) {
            if ((bits & (1u << i)) == 0) {
              *reinterpret_cast<word*>(line + (i << WORD_SIZE_LOG_2)) = SINGLE_FREE_WORD;
            }
          }
        }
        line += GcMetadata::CARD_SIZE;
        mark_bits++;
        ASSERT(mark_bits == GcMetadata::mark_bits_for(line));
        used += Utils::popcount(bits);
        continue;
      }
      // All 32 bits are zero so we have found a free area at least 32 words long.
      uword start_of_free = line;
      uint8* object_start_location = GcMetadata::starts_for(line);
      if (line != chunk->start()) {
        // Free area may have started in previous line.
        uint32 previous_mark_bits = mark_bits[-1];
        if ((previous_mark_bits & 0x80000000) == 0) {  // Check last bit.
          ASSERT(previous_mark_bits != 0);
          // Count most significant zeros to get free bytes at end of previous line.
          start_of_free -= Utils::clz(previous_mark_bits) << WORD_SIZE_LOG_2;
          // Object starts may be pointing into the free area, which we have to
          // fix.
          uint8* previous_object_start_location = object_start_location - 1;
          ASSERT(previous_object_start_location == GcMetadata::starts_for(start_of_free));
          // The object starts may point to the middle of this free area, which
          // is not the valid start of an object.  So we reset it to the start of
          // the free area, which is a place we can always iterate from.
          *previous_object_start_location = start_of_free;
        }
      }
      // Scan to find the end of the free area.
      while (bits == 0) {
        ASSERT(object_start_location == GcMetadata::starts_for(line));
        *object_start_location++ = GcMetadata::NO_OBJECT_START;
        line += GcMetadata::CARD_SIZE;
        mark_bits++;
        ASSERT(object_start_location == GcMetadata::starts_for(line));
        ASSERT(mark_bits == GcMetadata::mark_bits_for(line));
        if (line == end) {
          // The last free space must end one word earlier to make space for
          // the end-of-chunk sentinel.
          free_list_.add_region(start_of_free, end - start_of_free - WORD_SIZE);
          goto end_of_chunk;
        }
        bits = *mark_bits;
      }
      // Found a mark bit indicating the end of the free area.
      ASSERT(bits == *mark_bits);
      ASSERT(mark_bits == GcMetadata::mark_bits_for(line));
      used += Utils::popcount(bits);
      int free_words_at_start = Utils::ctz(bits);
      if (bits + (1u << free_words_at_start) != 0) {
        // The bits don't follow the pattern 1*0*, so we have to zap more
        // free areas in this line.
        for (int i = free_words_at_start; i < 32; i++) {
          if ((bits & (1u << i)) == 0) {
            *reinterpret_cast<word*>(line + (i << WORD_SIZE_LOG_2)) = SINGLE_FREE_WORD;
          }
        }
      }
      uword end_of_free = line + (free_words_at_start << WORD_SIZE_LOG_2);
      free_list_.add_region(start_of_free, end_of_free - start_of_free);
      // We set the object starts for this card to NO_OBJECT_START, but
      // that's not very helpful.  Repair it to point to the end of the
      // free area, which is a valid place to iterate from.
      uint8* end_starts_location = GcMetadata::starts_for(end_of_free);
      ASSERT(end_of_free < end);
      *end_starts_location = end_of_free;
      line += GcMetadata::CARD_SIZE;
      mark_bits++;
    }
    end_of_chunk:
    // Repair sentinel in case it was zapped by a marking bitmap.
    *reinterpret_cast<Object**>(end - WORD_SIZE) = chunk_end_sentinel();
#ifdef DEBUG
    validate_sweep(chunk);
#endif
    GcMetadata::clear_mark_bits_for_chunk(chunk);
  }
  return used << WORD_SIZE_LOG_2;
}

#ifdef DEBUG
// Check that all dead objects are replaced with freelist objects and
// that starts point at valid iteration points.
void OldSpace::validate_sweep(Chunk* chunk) {
  uword line = chunk->start();
  uword object_iterator = line;
  uword end = line + chunk->size();
  while (line != end && object_iterator != end - WORD_SIZE) {
    uint32* mark_bits = GcMetadata::mark_bits_for(object_iterator);
    uint8* starts = GcMetadata::starts_for(object_iterator);
    HeapObject* object = HeapObject::from_address(object_iterator);
    uword size = object->size(program_);
    bool alive = (*mark_bits & (1 << ((object_iterator - line) / WORD_SIZE))) != 0;
    ASSERT(GcMetadata::all_mark_bits_are(object, size, alive ? 1 : 0));
    ASSERT(object->is_a_free_object() == !alive);
    if (*starts != GcMetadata::NO_OBJECT_START) {
      ASSERT(*starts < GcMetadata::CARD_SIZE);
      uword location = *starts | (object_iterator & ~0xffll);
      if (alive) {
        // Starts can't point to the middle of a live object.
        ASSERT(location <= object_iterator || location >= object_iterator + size);
      } else {
        // Starts can point to the middle of a free object as long as there are
        // nested free objects that end at the same point.
        if (location > object_iterator && location < object_iterator + size) {
          uword stepping = location;
          while (stepping < object_iterator + size) {
            HeapObject* free_object = HeapObject::from_address(stepping);
            ASSERT(free_object->is_a_free_object());
            stepping += free_object->size(program_);
          }
          ASSERT(stepping == object_iterator + size);
        }
      }
    }
    uword new_line = Utils::round_down(object_iterator + size, GcMetadata::CARD_SIZE);
    if (new_line != line) {
      for (line += GcMetadata::CARD_SIZE; line < new_line; line += GcMetadata::CARD_SIZE) {
        ASSERT(*GcMetadata::starts_for(line) == GcMetadata::NO_OBJECT_START);
      }
      ASSERT(line == new_line);
    }
    object_iterator += size;
  }
}

void OldSpace::validate() {
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
      ASSERT(obj->size(program_) > 0);
      if (object_address + obj->size(program_) > card + 2 * GcMetadata::CARD_SIZE) {
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
      if (object->contains_pointers_to(program_, heap_->new_space())) {
        ASSERT(*GcMetadata::remembered_set_for(current));
      }
      current += object->size(program_);
    }
    ASSERT(current == chunk->end() - WORD_SIZE);
  }
}
#endif

void MarkingStack::empty(RootCallback* visitor) {
  while (!is_empty()) {
    HeapObject* object = *--next_;
    GcMetadata::mark_all(object, object->size(program_));
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

PromotedTrack* PromotedTrack::initialize(PromotedTrack* next, uword location, uword end) {
  ASSERT(end - location > header_size());
  auto self = reinterpret_cast<PromotedTrack*>(HeapObject::from_address(location));

  GcMetadata::record_start(location);
  // We mark the PromotedTrack object as dirty (containing new-space
  // pointers). This is because the remembered-set scanner mainly looks at
  // these dirty-bytes.  It ensures that the remembered-set scanner does not
  // skip past the PromotedTrack object header and start scanning newly
  // allocated objects inside the PromotedTrack area before they are
  // traversable.
  GcMetadata::insert_into_remembered_set(location);

  self->_set_header(Smi::from(PROMOTED_TRACK_CLASS_ID), PROMOTED_TRACK_TAG);
  self->_at_put(NEXT_OFFSET, next);
  self->_word_at_put(END_OFFSET, end);
  return self;
}

}  // namespace toit

#endif  // LEGACY_GC
