// Copyright (c) 2016, the Dartino project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

// Maintains data outside the heap that the garbage collector needs. Because
// the heap is always allocated from a restricted contiguous address area, the
// tables of the metadata can also be contiguous without needing complicated
// mapping.

#ifndef SRC_VM_GC_METADATA_H_
#define SRC_VM_GC_METADATA_H_

#include <stdint.h>

#include "src/shared/platform.h"
#include "src/shared/utils.h"
#include "src/vm/object_memory.h"

namespace dartino {

class GCMetadata {
 public:
  static void Setup();
  static void TearDown();

  static const int kWordShift = (sizeof(uword) == 8 ? 3 : 2);

  // When calculating the locations of compacted objects we want to use the
  // object starts array, which is arranged in card sizes for the remembered
  // set. Therefore it is currently necessary that each entry in the cumulative
  // mark bits array corresponds to one card of heap.  That means each card
  // should be 32 words long.
  static const int kCardSizeLog2 = 5 + kWordShift;

  // Number of bytes per remembered-set card.
  static const int kCardSize = 1 << kCardSizeLog2;

  static const int kCardSizeInBitsLog2 = kCardSizeLog2 + 3;

  // There is a byte per card, and any two byte values would work here.
  static const int kNoNewSpacePointers = 0;
  static const int kNewSpacePointers = 1;  // Actually any non-zero value.

  // One bit per word of heap, so the size in bytes is 1/8th of that.
  static const int kMarkBitsShift = 3 + kWordShift;

  // One word per uint32 of mark bits, corresponding to 32 words of heap.
  static const int kCumulativeMarkBitsShift = 5;

  static void InitializeStartsForChunk(Chunk* chunk, uword only_above = 0) {
    uword start = chunk->start();
    uword end = chunk->end();
    if (only_above >= end) return;
    if (only_above > start) {
      ASSERT(only_above % kCardSize == 0);
      start = only_above;
    }
    ASSERT(InMetadataRange(start));
    uint8* from = StartsFor(start);
    uint8* to = StartsFor(end);
    memset(from, kNoObjectStart, to - from);
  }

  static void InitializeRememberedSetForChunk(Chunk* chunk,
                                              uword only_above = 0) {
    uword start = chunk->start();
    uword end = chunk->end();
    if (only_above >= end) return;
    if (only_above > start) {
      ASSERT(only_above % kCardSize == 0);
      start = only_above;
    }
    ASSERT(InMetadataRange(start));
    uint8* from = RememberedSetFor(start);
    uint8* to = RememberedSetFor(end);
    memset(from, GCMetadata::kNoNewSpacePointers, to - from);
  }

  static void InitializeOverflowBitsForChunk(Chunk* chunk) {
    ASSERT(InMetadataRange(chunk->start()));
    uint8* from = OverflowBitsFor(chunk->start());
    uint8* to = OverflowBitsFor(chunk->end());
    memset(from, 0, to - from);
  }

  static void ClearMarkBitsFor(Chunk* chunk) {
    ASSERT(InMetadataRange(chunk->start()));
    uword base = chunk->start();
    uword size = chunk->size() >> kMarkBitsShift;
    base = (base >> kMarkBitsShift) + singleton_.mark_bits_bias_;
    memset(reinterpret_cast<uint8*>(base), 0, size);
  }

  static void MarkPagesForChunk(Chunk* chunk, PageType page_type) {
    uword index = chunk->start() - singleton_.lowest_address_;
    if (index >= singleton_.heap_extent_) return;
    uword size = chunk->size() >> Platform::kPageBits;
    memset(singleton_.page_type_bytes_ + (index >> Platform::kPageBits),
           page_type, size);
  }

  // Safe to call with any object, even a Smi.
  static ALWAYS_INLINE PageType GetPageType(Object* object) {
    uword addr = reinterpret_cast<uword>(object);
    uword offset = addr >> 1 | addr << (8 * sizeof(uword) - 1);
    offset -= singleton_.heap_start_munged_;
    if (offset >= singleton_.heap_extent_munged_) return kUnknownSpacePage;
    return static_cast<PageType>(
        singleton_.page_type_bytes_[offset >> (Platform::kPageBits - 1)]);
  }

  // Only safe with an actual address of an old-space or new-space object.
  static inline PageType GetPageType(uword addr) {
    ASSERT((addr & 1) == 0);
    addr -= singleton_.lowest_address_;
    ASSERT(addr < singleton_.heap_extent_);
    return static_cast<PageType>(
        singleton_.page_type_bytes_[addr >> Platform::kPageBits]);
  }

  // Safe to call with any object, even a Smi.
  static ALWAYS_INLINE bool InNewOrOldSpace(Object* object) {
    PageType page_type = GetPageType(object);
    return page_type != kUnknownSpacePage;
  }

  static inline uint8* StartsFor(uword address) {
    ASSERT(InMetadataRange(address));
    return reinterpret_cast<uint8*>((address >> kCardSizeLog2) +
                                    singleton_.starts_bias_);
  }

  static inline uint8* RememberedSetFor(uword address) {
    ASSERT(InMetadataRange(address));
    return reinterpret_cast<uint8*>((address >> kCardSizeLog2) +
                                    singleton_.remembered_set_bias_);
  }

  static inline uint8* OverflowBitsFor(uword address) {
    ASSERT(InMetadataRange(address));
    return reinterpret_cast<uint8*>((address >> kCardSizeInBitsLog2) +
                                    singleton_.overflow_bits_bias_);
  }

  static ALWAYS_INLINE uint32* BytewiseMarkBitsFor(HeapObject* object) {
    uword address = reinterpret_cast<uword>(object);
    ASSERT(InMetadataRange(address));
    uword result = (singleton_.mark_bits_bias_ + (address >> kMarkBitsShift));
    return reinterpret_cast<uint32*>(result);
  }

  static ALWAYS_INLINE uint32* MarkBitsFor(HeapObject* object) {
    uword address = reinterpret_cast<uword>(object);
    ASSERT(InMetadataRange(address));
    uword result =
        (singleton_.mark_bits_bias_ + (address >> kMarkBitsShift)) & ~3;
    return reinterpret_cast<uint32*>(result);
  }

  static ALWAYS_INLINE uint32* MarkBitsFor(uword address) {
    ASSERT(InMetadataRange(address));
    return MarkBitsFor(reinterpret_cast<HeapObject*>(address));
  }

  static ALWAYS_INLINE int WordIndexInLine(HeapObject* object) {
    return (reinterpret_cast<uword>(object) >> GCMetadata::kWordShift) & 31;
  }

  static ALWAYS_INLINE uword* CumulativeMarkBitsFor(HeapObject* object) {
    uword address = reinterpret_cast<uword>(object);
    ASSERT(InMetadataRange(address));
    uword result = (singleton_.cumulative_mark_bits_bias_ +
                    (address >> kCumulativeMarkBitsShift)) &
                   ~(sizeof(uword) - 1);
    return reinterpret_cast<uword*>(result);
  }

  static ALWAYS_INLINE uword* CumulativeMarkBitsFor(uword address) {
    ASSERT(InMetadataRange(address));
    return CumulativeMarkBitsFor(reinterpret_cast<HeapObject*>(address));
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

    bool HasNextChunk() {
      Space* owner = chunk()->owner();
      ChunkListIterator new_it = it_;
      ++new_it;
      return new_it != owner->ChunkListEnd();
    }

    Destination NextChunk() {
      ChunkListIterator new_it = it_;
      ++new_it;
      return Destination(new_it, new_it->start(), new_it->usable_end());
    }

    Destination NextSweepingChunk() {
      ChunkListIterator new_it = it_;
      ++new_it;
      return Destination(new_it, new_it->start(), new_it->compaction_top());
    }

    uword address;
    uword limit;

   private:
    ChunkListIterator it_;
  };

  static Destination CalculateObjectDestinations(Chunk* src_chunk,
                                                 Destination dest);

  // Returns true if the object is grey (queued) or black(scanned).
  static inline bool IsMarked(HeapObject* object) {
    uword address = reinterpret_cast<uword>(object);
    address = (singleton_.mark_bits_bias_ + (address >> kMarkBitsShift)) & ~3;
    uint32 mask = 1 << ((reinterpret_cast<uword>(object) >> kWordShift) & 31);
    return (*reinterpret_cast<uint32*>(address) & mask) != 0;
  }

  // Returns true if the object was already grey (queued) or black(scanned).
  static ALWAYS_INLINE bool MarkGreyIfNotMarked(HeapObject* object) {
    uword address = reinterpret_cast<uword>(object);
    address = (singleton_.mark_bits_bias_ + (address >> kMarkBitsShift)) & ~3;
    uint32 mask = 1 << ((reinterpret_cast<uword>(object) >> kWordShift) & 31);
    uint32 bits = *reinterpret_cast<uint32*>(address);
    if ((bits & mask) != 0) return true;
    *reinterpret_cast<uint32*>(address) = bits | mask;
    return false;
  }

  // Returns true if the object is grey (queued), but not black (scanned).
  // This is used when scanning the heap after mark stack overflow, looking for
  // objects that are conceptually queued, but which are missing from the
  // explicit marking queue.
  static bool IsGrey(HeapObject* object) {
    return IsMarked(object) &&
           !IsMarked(reinterpret_cast<HeapObject*>(
               reinterpret_cast<uword>(object) + sizeof(uword)));
  }

  // Marks an object grey, which normally means it has been queued on the mark
  // stack.
  static inline void Mark(HeapObject* object) {
    uint32* bits = MarkBitsFor(object);
    uint32 mask = 1 << ((reinterpret_cast<uword>(object) >> kWordShift) & 31);
    *bits |= mask;
  }

  // Marks all the bits (1 bit per word) that correspond to a live object.
  // This marks the object black (scanned) and sets up the bitmap data we need
  // for compaction.
  static void MarkAll(HeapObject* object, size_t size) {
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
        ((reinterpret_cast<uword>(object) >> kWordShift) & mask_mask);
    size_t size_in_words = size >> kWordShift;
    // Jump to the slow case routine to handle crossing an int32_t boundary.
    // If we have unaligned access then this slow case never happens for
    // objects < 24 words in size. Otherwise it can happen for small objects
    // that straddle a 32-word boundary.
    if (mask_shift + size_in_words > 31) return SlowMark(object, size);

    uint32 mask = ((1 << size_in_words) - 1) << mask_shift;

#ifdef NO_UNALIGNED_ACCESS
    uint32* bits = MarkBitsFor(object);
#else
    uint32* bits = BytewiseMarkBitsFor(object);
#endif
    *bits |= mask;
  }

  static ALWAYS_INLINE uword GetDestination(HeapObject* pre_compaction) {
    size_t word_position =
        (reinterpret_cast<uword>(pre_compaction) >> kWordShift) & 31;
    uint32 mask = ~(0xffffffffu << word_position);
    uint32 bits = *MarkBitsFor(pre_compaction) & mask;
    uword base = *CumulativeMarkBitsFor(pre_compaction);
    return base + (PopCount(bits) << kWordShift);
  }

  static int heap_allocation_arena() {
    return singleton_.heap_allocation_arena_;
  }

  static uword lowest_old_space_address() { return singleton_.lowest_address_; }

  static uword heap_extent() { return singleton_.heap_extent_; }

  static bool InMetadataRange(uword address) {
    uword lowest = singleton_.lowest_address_;
    return address >= lowest && address - lowest <= singleton_.heap_extent_;
  }

  static uword remembered_set_bias() { return singleton_.remembered_set_bias_; }

  // Unaligned, so cannot clash with a real object start.
  static const int kNoObjectStart = 2;

  // We need to track the start of an object for each card, so that we can
  // iterate just part of the heap.  This does that for newly allocated objects
  // in old-space.  The cards are less than 256 bytes large (see the assert
  // below), so writing the last byte of the object start address is enough to
  // uniquely identify the address.
  inline static void RecordStart(uword address) {
    uint8* start = StartsFor(address);
    ASSERT(kCardSizeLog2 <= 8);
    *start = static_cast<uint8>(address);
  }

  // An object at this address may contain a pointer from old-space to
  // new-space.
  inline static void InsertIntoRememberedSet(uword address) {
    address >>= kCardSizeLog2;
    address += singleton_.remembered_set_bias_;
    *reinterpret_cast<uint8*>(address) = kNewSpacePointers;
  }

  // May this card contain pointers from old-space to new-space?
  inline static bool IsMarkedDirty(uword address) {
    address >>= kCardSizeLog2;
    address += singleton_.remembered_set_bias_;
    return *reinterpret_cast<uint8*>(address) != kNoNewSpacePointers;
  }

  // The object was marked grey and we tried to push it on the mark stack, but
  // the stack overflowed. Here we record enough information that we can find
  // these objects later.
  static void MarkStackOverflow(HeapObject* object);

  static uword ObjectAddressFromStart(uword line, uint8 start);

 private:
  GCMetadata() {}
  ~GCMetadata() {}

  static GCMetadata singleton_;

  void SetupSingleton();

  static void SlowMark(HeapObject* object, size_t size);
  static uword EndOfDestinationOfLastLiveObjectStartingBefore(
      uword line, uword limit, uword* src_end_return = NULL);
  static uword LastLineThatFits(uword line, uword dest_limit);

  static ALWAYS_INLINE int PopCount(uint32 x) {
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
  unsigned char* metadata_;
  unsigned char* remembered_set_;
  unsigned char* object_starts_;
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

}  // namespace dartino

#endif  // SRC_VM_GC_METADATA_H_
