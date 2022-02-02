// Copyright (c) 2016, the Dartino project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

// Maintains data outside the heap that the garbage collector needs. Because
// the heap is always allocated from a restricted contiguous address area, the
// tables of the metadata can also be contiguous without needing complicated
// mapping.

#pragma once

#include <stdint.h>

#include "../../top.h"
#include "../../os.h"
#include "../../utils.h"

namespace toit {

class GcMetadata {
 public:
  static void set_up();
  static void tear_down();

  // When calculating the locations of compacted objects we want to use the
  // object starts array, which is arranged in card sizes for the remembered
  // set. Therefore it is currently necessary that each entry in the cumulative
  // mark bits array corresponds to one card of heap.  That means each card
  // should be 32 words long.
  static const int CARD_SIZE_LOG_2 = 5 + WORD_SHIFT;

  // Number of bytes per remembered-set card.
  static const int CARD_SIZE = 1 << CARD_SIZE_LOG_2;

  static const int CARD_SIZE_IN_BITS_LOG_2 = CARD_SIZE_LOG_2 + 3;

  // There is a byte per card, and any two byte values would work here.
  static const int NO_NEW_SPACE_POINTERS = 0;
  static const int NEW_SPACE_POINTERS = 1;  // Actually any non-zero value.

  // One bit per word of heap, so the size in bytes is 1/8th of that.
  static const int MARK_BITS_SHIFT = 3 + WORD_SHIFT;

  // One word per uint32 of mark bits, corresponding to 32 words of heap.
  static const int CUMULATIVE_MARK_BITS_SHIFT = 5;

  static void initialize_start_for_chunk(Chunk* chunk, uword only_above = 0) {
    uword start = chunk->start();
    uword end = chunk->end();
    if (only_above >= end) return;
    if (only_above > start) {
      ASSERT(only_above % CARD_SIZE == 0);
      start = only_above;
    }
    ASSERT(in_metadata_range(start));
    uint8* from = starts_for(start);
    uint8* to = starts_for(end);
    memset(from, NO_OBJECT_START, to - from);
  }

  static void initialize_remembered_set_for_chunk(Chunk* chunk, uword only_above = 0) {
    uword start = chunk->start();
    uword end = chunk->end();
    if (only_above >= end) return;
    if (only_above > start) {
      ASSERT(only_above % CARD_SIZE == 0);
      start = only_above;
    }
    ASSERT(in_metadata_range(start));
    uint8* from = remembered_set_for(start);
    uint8* to = remembered_set_for(end);
    memset(from, GcMetadata::NO_NEW_SPACE_POINTERS, to - from);
  }

  static void initialze_overflow_bits_for_chunk(Chunk* chunk) {
    ASSERT(in_metadata_range(chunk->start()));
    uint8* from = overflow_bits_for(chunk->start());
    uint8* to = overflow_bits_for(chunk->end());
    memset(from, 0, to - from);
  }

  static void clear_mark_bits_for(Chunk* chunk) {
    ASSERT(in_metadata_range(chunk->start()));
    uword base = chunk->start();
    uword size = chunk->size() >> MARK_BITS_SHIFT;
    base = (base >> MARK_BITS_SHIFT) + singleton_.mark_bits_bias_;
    memset(reinterpret_cast<uint8*>(base), 0, size);
  }

  static void mark_pages_for_chunk(Chunk* chunk, PageType page_type) {
    uword index = chunk->start() - singleton_.lowest_address_;
    if (index >= singleton_.heap_extent_) return;
    uword size = chunk->size() >> TOIT_PAGE_SIZE_LOG2;
    memset(singleton_.page_type_bytes_ + (index >> TOIT_PAGE_SIZE_LOG2),
           page_type, size);
  }

  // Safe to call with any object, even a Smi.
  static ALWAYS_INLINE PageType get_page_type(Object* object) {
    uword addr = reinterpret_cast<uword>(object);
    uword offset = addr >> 1 | addr << (8 * sizeof(uword) - 1);
    offset -= singleton_.heap_start_munged_;
    if (offset >= singleton_.heap_extent_munged_) return UNKNOWN_SPACE_PAGE;
    return static_cast<PageType>(
        singleton_.page_type_bytes_[offset >> (TOIT_PAGE_SIZE_LOG2 - 1)]);
  }

  // Only safe with an actual address of an old-space or new-space object.
  static inline PageType get_page_type(uword addr) {
    ASSERT((addr & 1) == 0);
    addr -= singleton_.lowest_address_;
    ASSERT(addr < singleton_.heap_extent_);
    return static_cast<PageType>(
        singleton_.page_type_bytes_[addr >> TOIT_PAGE_SIZE_LOG2]);
  }

  // Safe to call with any object, even a Smi.
  static ALWAYS_INLINE bool in_new_or_old_space(Object* object) {
    PageType page_type = get_page_type(object);
    return page_type != UNKNOWN_SPACE_PAGE;
  }

  static inline uint8* starts_for(uword address) {
    ASSERT(in_metadata_range(address));
    return reinterpret_cast<uint8*>((address >> CARD_SIZE_LOG_2) +
                                    singleton_.starts_bias_);
  }

  static inline uint8* remembered_set_for(uword address) {
    ASSERT(in_metadata_range(address));
    return reinterpret_cast<uint8*>((address >> CARD_SIZE_LOG_2) +
                                    singleton_.remembered_set_bias_);
  }

  static inline uint8* overflow_bits_for(uword address) {
    ASSERT(in_metadata_range(address));
    return reinterpret_cast<uint8*>((address >> CARD_SIZE_IN_BITS_LOG_2) +
                                    singleton_.overflow_bits_bias_);
  }

  static ALWAYS_INLINE uint32* bytewise_mark_bits_for(HeapObject* object) {
    uword address = reinterpret_cast<uword>(object);
    ASSERT(in_metadata_range(address));
    uword result = (singleton_.mark_bits_bias_ + (address >> MARK_BITS_SHIFT));
    return reinterpret_cast<uint32*>(result);
  }

  static ALWAYS_INLINE uint32* mark_bits_for(HeapObject* object) {
    uword address = reinterpret_cast<uword>(object);
    ASSERT(in_metadata_range(address));
    uword result =
        (singleton_.mark_bits_bias_ + (address >> MARK_BITS_SHIFT)) & ~3;
    return reinterpret_cast<uint32*>(result);
  }

  static ALWAYS_INLINE uint32* mark_bits_for(uword address) {
    ASSERT(in_metadata_range(address));
    return mark_bits_for(reinterpret_cast<HeapObject*>(address));
  }

  static ALWAYS_INLINE int word_index_in_line(HeapObject* object) {
    return (reinterpret_cast<uword>(object) >> GcMetadata::WORD_SHIFT) & 31;
  }

  static ALWAYS_INLINE uword* cumulative_mark_bits_for(HeapObject* object) {
    uword address = reinterpret_cast<uword>(object);
    ASSERT(in_metadata_range(address));
    uword result = (singleton_.cumulative_mark_bits_bias_ +
                    (address >> CUMULATIVE_MARK_BITS_SHIFT)) &
                   ~(sizeof(uword) - 1);
    return reinterpret_cast<uword*>(result);
  }

  static ALWAYS_INLINE uword* cumulative_mark_bits_for(uword address) {
    ASSERT(in_metadata_range(address));
    return cumulative_mark_bits_for(reinterpret_cast<HeapObject*>(address));
  }

  class Destination {
   public:
    Destination(ChunkListIterator it, uword a, uword l)
        : address(a), limit(l), it_(it) {}

    Destination(ChunkListIterator it, ChunkListIterator end)
        : address(it == end ? 0 : it->start()),
          limit(it == end ? 0 : it->compaction_top()),
          it_(it) {}

    Chunk* chunk() { return *it_; }

    bool has_next_chunk() {
      Space* owner = chunk()->owner();
      ChunkListIterator new_it = it_;
      ++new_it;
      return new_it != owner->chunk_list_end();
    }

    Destination next_chunk() {
      ChunkListIterator new_it = it_;
      ++new_it;
      return Destination(new_it, new_it->start(), new_it->usable_end());
    }

    Destination next_sweeping_chunk() {
      ChunkListIterator new_it = it_;
      ++new_it;
      return Destination(new_it, new_it->start(), new_it->compaction_top());
    }

    uword address;
    uword limit;

   private:
    ChunkListIterator it_;
  };

  static Destination calculate_object_destinations(Chunk* src_chunk, Destination dest);

  // Returns true if the object is grey (queued) or black(scanned).
  static inline bool is_marked(HeapObject* object) {
    uword address = reinterpret_cast<uword>(object);
    address = (singleton_.mark_bits_bias_ + (address >> MARK_BITS_SHIFT)) & ~3;
    uint32 mask = 1 << ((reinterpret_cast<uword>(object) >> WORD_SHIFT) & 31);
    return (*reinterpret_cast<uint32*>(address) & mask) != 0;
  }

  // Returns true if the object was already grey (queued) or black(scanned).
  static ALWAYS_INLINE bool mark_grey_if_not_marked(HeapObject* object) {
    uword address = reinterpret_cast<uword>(object);
    address = (singleton_.mark_bits_bias_ + (address >> MARK_BITS_SHIFT)) & ~3;
    uint32 mask = 1 << ((reinterpret_cast<uword>(object) >> WORD_SHIFT) & 31);
    uint32 bits = *reinterpret_cast<uint32*>(address);
    if ((bits & mask) != 0) return true;
    *reinterpret_cast<uint32*>(address) = bits | mask;
    return false;
  }

  // Returns true if the object is grey (queued), but not black (scanned).
  // This is used when scanning the heap after mark stack overflow, looking for
  // objects that are conceptually queued, but which are missing from the
  // explicit marking queue.
  static bool is_grey(HeapObject* object) {
    return is_marked(object) &&
           !is_marked(reinterpret_cast<HeapObject*>(
               reinterpret_cast<uword>(object) + sizeof(uword)));
  }

  // Marks an object grey, which normally means it has been queued on the mark
  // stack.
  static inline void mark(HeapObject* object) {
    uint32* bits = mark_bits_for(object);
    uint32 mask = 1 << ((reinterpret_cast<uword>(object) >> WORD_SHIFT) & 31);
    *bits |= mask;
  }

  // Marks all the bits (1 bit per word) that correspond to a live object.
  // This marks the object black (scanned) and sets up the bitmap data we need
  // for compaction.
  static void mark_all(HeapObject* object, uword size) {
    // If there were 1-word live objects we could not see the difference
    // between grey objects (only first word is marked) and black objects (all
    // words are marked).
    ASSERT(size > sizeof(uword));
#ifdef NO_UNALIGNED_ACCESS
    const int mask_mask = 31;
#else
    const int mask_mask = 7;
#endif
    int mask_shift =
        ((reinterpret_cast<uword>(object) >> WORD_SHIFT) & mask_mask);
    uword size_in_words = size >> WORD_SHIFT;
    // Jump to the slow case routine to handle crossing an int32_t boundary.
    // If we have unaligned access then this slow case never happens for
    // objects < 24 words in size. Otherwise it can happen for small objects
    // that straddle a 32-word boundary.
    if (mask_shift + size_in_words > 31) return slow_mark(object, size);

    uint32 mask = ((1 << size_in_words) - 1) << mask_shift;

#ifdef NO_UNALIGNED_ACCESS
    uint32* bits = mark_bits_for(object);
#else
    uint32* bits = bytewise_mark_bits_for(object);
#endif
    *bits |= mask;
  }

  static ALWAYS_INLINE uword get_destination(HeapObject* pre_compaction) {
    uword word_position =
        (reinterpret_cast<uword>(pre_compaction) >> WORD_SHIFT) & 31;
    uint32 mask = ~(0xffffffffu << word_position);
    uint32 bits = *mark_bits_for(pre_compaction) & mask;
    uword base = *cumulative_mark_bits_for(pre_compaction);
    return base + (pop_count(bits) << WORD_SHIFT);
  }

  static int heap_allocation_arena() {
    return singleton_.heap_allocation_arena_;
  }

  static uword lowest_old_space_address() { return singleton_.lowest_address_; }

  static uword heap_extent() { return singleton_.heap_extent_; }

  static bool in_metadata_range(uword address) {
    uword lowest = singleton_.lowest_address_;
    return address >= lowest && address - lowest <= singleton_.heap_extent_;
  }

  static uword remembered_set_bias() { return singleton_.remembered_set_bias_; }

  // Unaligned, so cannot clash with a real object start.
  static const int NO_OBJECT_START = 2;

  // We need to track the start of an object for each card, so that we can
  // iterate just part of the heap.  This does that for newly allocated objects
  // in old-space.  The cards are less than 256 bytes large (see the assert
  // below), so writing the last byte of the object start address is enough to
  // uniquely identify the address.
  inline static void record_start(uword address) {
    uint8* start = starts_for(address);
    ASSERT(CARD_SIZE_LOG_2 <= 8);
    *start = static_cast<uint8>(address);
  }

  // An object at this address may contain a pointer from old-space to
  // new-space.
  inline static void insert_into_remembered_set(uword address) {
    address >>= CARD_SIZE_LOG_2;
    address += singleton_.remembered_set_bias_;
    *reinterpret_cast<uint8*>(address) = NEW_SPACE_POINTERS;
  }

  // May this card contain pointers from old-space to new-space?
  inline static bool is_marked_dirty(uword address) {
    address >>= CARD_SIZE_LOG_2;
    address += singleton_.remembered_set_bias_;
    return *reinterpret_cast<uint8*>(address) != NO_NEW_SPACE_POINTERS;
  }

  // The object was marked grey and we tried to push it on the mark stack, but
  // the stack overflowed. Here we record enough information that we can find
  // these objects later.
  static void mark_stack_overflow(HeapObject* object);

  static uword object_address_from_start(uword line, uint8 start);

 private:
  GcMetadata() {}
  ~GcMetadata() {}

  static GcMetadata singleton_;

  void set_up_singleton();

  static void slow_mark(HeapObject* object, uword size);
  static uword end_of_destination_of_last_live_object_starting_before(
      uword line, uword limit, uword* src_end_return = NULL);
  static uword last_line_that_fits(uword line, uword dest_limit);

  static ALWAYS_INLINE int pop_count(uint32 x) {
    x = (x & 0x55555555) + ((x >> 1) & 0x55555555);
    // x has 16 2-bit sums.
    x = (x & 0x33333333) + ((x >> 2) & 0x33333333);
    // x has 8 4-bit sums from 0-4.
    x = (x & 0x0f0f0f0f) + ((x >> 4) & 0x0f0f0f0f);
    // x has 4 8-bit sums from 0-8, so only occupying 3 bits.
    x += x >> 8;
    // x has 2 8-bit sums from 0-16 in the 2nd and 4th bytes.
    x += x >> 16;
    return x & 63;  // 0 to 32.
  }

  // Heap metadata (remembered set etc.).
  uword lowest_address_;
  uword heap_extent_;
  uword heap_start_munged_;
  uword heap_extent_munged_;
  uword number_of_cards_;
  uword metadata_size_;
  int heap_allocation_arena_;
  uint8* metadata_;
  uint8* remembered_set_;
  uint8* object_starts_;
  uint32* mark_bits_;
  uint8_t* mark_stack_overflow_bits_;
  uint8_t* page_type_bytes_;
  uword* cumulative_mark_bit_counts_;
  uword starts_bias_;
  uword remembered_set_bias_;
  uword mark_bits_bias_;
  uword overflow_bits_bias_;
  uword cumulative_mark_bits_bias_;
};

}  // namespace toit
