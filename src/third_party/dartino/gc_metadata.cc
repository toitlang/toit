// Copyright (c) 2016, the Dartino project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

#include "src/vm/gc_metadata.h"

#include <stdio.h>

#include "src/shared/assert.h"
#include "src/shared/flags.h"
#include "src/vm/object.h"

namespace toit {

GcMetadata GcMetadata::singleton_;

void GcMetadata::tear_down() {
  Platform::free_pages(singleton_.metadata_, singleton_.metadata_size_);
}

void GcMetadata::set_up() { singleton_.set_up_singleton(); }

void GcMetadata::set_up_singleton() {
  const int RANGES = 4;
  Platform::HeapMemoryRange ranges[RANGES];
  int range_count = Platform::get_heap_memory_pages(ranges, RANGES);
  ASSERT(range_count > 0);

  // Find the largest area.
  int largest_index = 0;
  uword largest_size = ranges[0].size;
  for (int i = 1; i < range_count; i++) {
    if (ranges[i].size > largest_size) {
      largest_size = ranges[i].size;
      largest_index = i;
    }
  }

  heap_allocation_arena_ = 1 << largest_index;

  lowest_address_ = reinterpret_cast<uword>(ranges[largest_index].address);
  uword size = ranges[largest_index].size;
  heap_extent_ = size;
  heap_start_munged_ = (lowest_address_ >> 1) |
                       (static_cast<uword>(1) << (8 * sizeof(uword) - 1));
  heap_extent_munged_ = size >> 1;

  number_of_cards_ = size >> CARD_SIZE_LOG_2;

  uword mark_bits_size = size >> MARK_BITS_SHIFT;
  uword mark_stack_overflow_bits_size = size >> CARD_SIZE_IN_BITS_LOG_2;

  uword cumulative_mark_bits_size = size >> CUMULATIVE_MARK_BITS_SHIFT;

  uword page_type_size_ = size >> TOIT_PAGE_SIZE_LOG2;

  // We have two bytes per card: one for remembered set, and one for object
  // start offset.
  metadata_size_ = Utils::round_up(
      number_of_cards_ * 2 + mark_bits_size + cumulative_mark_bits_size +
          mark_stack_overflow_bits_size + page_type_size_,
      TOIT_PAGE_SIZE);

  metadata_ = reinterpret_cast<uint8*>(
      Platform::allocate_pages(metadata_size_, Platform::kAnyArena));
  remembered_set_ = metadata_;
  object_starts_ = metadata_ + number_of_cards_;
  mark_bits_ = reinterpret_cast<uint32*>(metadata_ + 2 * number_of_cards_);
  cumulative_mark_bit_counts_ = reinterpret_cast<uword*>(
      reinterpret_cast<uword>(mark_bits_) + mark_bits_size);
  mark_stack_overflow_bits_ =
      reinterpret_cast<uint8_t*>(cumulative_mark_bit_counts_) +
      cumulative_mark_bits_size;
  page_type_bytes_ = mark_stack_overflow_bits_ + mark_stack_overflow_bits_size;

  memset(page_type_bytes_, UNKNOWN_SPACE_PAGE, page_type_size_);

  uword start = reinterpret_cast<uword>(object_starts_);
  uword lowest = lowest_address_;
  uword shifted = lowest >> CARD_SIZE_LOG_2;
  starts_bias_ = start - shifted;

  start = reinterpret_cast<uword>(remembered_set_);
  remembered_set_bias_ = start - shifted;

  shifted = lowest >> MARK_BITS_SHIFT;
  start = reinterpret_cast<uword>(mark_bits_);
  mark_bits_bias_ = start - shifted;

  shifted = lowest >> CARD_SIZE_IN_BITS_LOG_2;
  start = reinterpret_cast<uword>(mark_stack_overflow_bits_);
  overflow_bits_bias_ = start - shifted;

  shifted = lowest >> CUMULATIVE_MARK_BITS_SHIFT;
  start = reinterpret_cast<uword>(cumulative_mark_bit_counts_);
  cumulative_mark_bits_bias_ = start - shifted;
}

// Impossible end-of-object address, since they are aligned.
static const uword NO_END_FOUND = 3;
static const uword LINE_SIZE = 32 * sizeof(word);

// All objects have been marked black. This means that the bits corresponding
// to all words in the object are marked with 1's (not just the first word).
// We divide the memory up into compaction "lines" of 32 words, corresponding
// to one 32 bit word of mark bits.
//
// We can use the mark bits to calculate for each line, where an object
// starting at the start of that line should be moved.  This is called the
// 'cumulative mark bits' because it is calculated by counting mark bits, but
// it is actually a destination address, not just a count.  To calculate the
// actual destination of each object we combine the cumulative mark bits for
// its line with the count of 1's to the left of the object in the line's 32
// bit mark word.
GcMetadata::Destination GcMetadata::calculate_object_destinations(
    Chunk* src_chunk, GcMetadata::Destination dest) {
  uword src_start = src_chunk->start();
  uword src_limit = src_chunk->end();
  uword src = src_chunk->start();
  // Gets rid of some edge cases.
  *starts_for(src) = src;
restart:
  uint32* mark_bits = mark_bits_for(src);
  uword* dest_table = cumulative_mark_bits_for(reinterpret_cast<HeapObject*>(src));
  while (true) {
    // The main loop only looks at the metadata, not the objects, for speed.
    ASSERT(dest.address <= dest.limit && src <= src_limit);
    while (dest.address <= dest.limit) {
      if (src == src_limit) {
        return dest;
      }
      *dest_table = dest.address;
      dest.address += pop_count(*mark_bits) << WORD_SHIFT;
      src += LINE_SIZE;
      mark_bits++;
      dest_table++;
    }
    // We went over the end of the destination chunk.  We have to back-track,
    // and this time we will have to look at the actual objects, which is
    // slower, but prevents us from splitting an object over two different
    // destination chunks.
    // We need to find a recent source line, where all the objects that
    // start in that card still fit in the destination.
    uword end = NO_END_FOUND;
    while (end == NO_END_FOUND || end > dest.limit) {
      if (src == src_start) {
        // We went back to the start of source data we were trying to fit in
        // the destination chunk, and not even the first line could fit.  Time
        // to move to the next destination chunk.
        dest.chunk()->set_compaction_top(dest.address);
        dest = dest.next_chunk();
        goto restart;
      }
      dest_table--;
      mark_bits--;
      src -= LINE_SIZE;
      dest.address = *dest_table;
      end = end_of_destination_of_last_live_object_starting_before(src, src + LINE_SIZE);
    }

    // Found a source line that has a real starts entry where all objects from
    // that line fit in the current destination chunk. But because of the way
    // the starts array works, we may have stepped too far back.  This is
    // because the first few object in the line (which may be the only live
    // ones) can only be iterated using the starts array for a previous line.
    uword end_of_last_src_line_that_fits =
        last_line_that_fits(src, dest.limit) + LINE_SIZE;
    uword end_of_last_source_object_moved = 0;
    uword dest_end = end_of_destination_of_last_live_object_starting_before(
        src, end_of_last_src_line_that_fits, &end_of_last_source_object_moved);

    src = end_of_last_src_line_that_fits;
    mark_bits = mark_bits_for(src);
    dest_table = cumulative_mark_bits_for(src);

    ASSERT(dest_end != NO_END_FOUND);
    dest.chunk()->set_compaction_top(dest_end);
    dest = dest.next_chunk();
    int overhang =
        end_of_last_source_object_moved - end_of_last_src_line_that_fits;
    overhang >>= WORD_SHIFT;
    if (overhang > 0) {
      // We are starting a new destination chunk, but the src is pointing at
      // the start of a line that may start with the tail end of an object that
      // was moved to a different destination chunk. This confuses the
      // destination calculation, and it turns out that the easiest way to
      // handle this is to zap the bits associated with the tail of the already
      // moved object. This can have the effect of making a black object look
      // grey, but we are done marking so that would only affect asserts.
      uint32* overhang_bits =
          mark_bits_for(end_of_last_source_object_moved - WORD_SIZE);
      ASSERT((*overhang_bits & 1) != 0);
      *overhang_bits &= ~((1 << overhang) - 1);
    }
    src_start = src;
  }
}

uword GcMetadata::end_of_destination_of_last_live_object_starting_before(
    uword line, uword limit, uword* src_end_return) {
  uint8 start = *starts_for(line);
  if (start == NO_OBJECT_START) return NO_END_FOUND;
  uword object_address = object_address_from_start(line, start);
  uword result = NO_END_FOUND;
  while (!has_sentinel_at(object_address) && object_address < limit) {
    // Uses cumulative mark bits!
    uword size = HeapObject::from_address(object_address)->Size();
    if (is_marked(HeapObject::from_address(object_address))) {
      result = get_destination(HeapObject::from_address(object_address)) + size;
      if (src_end_return != NULL) *src_end_return = object_address + size;
    }
    object_address += size;
  }
  return result;
}

uword GcMetadata::last_line_that_fits(uword line, uword dest_limit) {
  uint8 start = *starts_for(line);
  ASSERT(start != NO_OBJECT_START);
  HeapObject* object =
      HeapObject::from_address(object_address_from_start(line, start));
  uword dest = get_destination(object);  // Uses cumulative mark bits!
  ASSERT(!has_sentinel_at(object->address()));
  while (!has_sentinel_at(object->address()) &&
         (dest + object->Size() <= dest_limit || !is_marked(object))) {
    object = HeapObject::from_address(object->address() + object->Size());
    dest = get_destination(object);  // Uses cumulative mark bits!
  }
  uword last_line = object->address() & ~(LINE_SIZE - 1);
  if (has_sentinel_at(object->address())) {
    return last_line;
  }
  // The last line did not fit, so return the previous one.
  ASSERT(last_line > line);
  return last_line - LINE_SIZE;
}

uword GcMetadata::object_address_from_start(uword card, uint8 start) {
  uword object_address = (card & ~0xff) | start;
  ASSERT(object_address >> GcMetadata::CARD_SIZE_LOG_2 ==
         card >> GcMetadata::CARD_SIZE_LOG_2);
  return object_address;
}

// Mark all bits of an object whose mark bits cross a 32 bit boundary.
void GcMetadata::slow_mark(HeapObject* object, uword size) {
  int mask_shift = ((reinterpret_cast<uword>(object) >> WORD_SHIFT) & 31);
  uint32* bits = mark_bits_for(object);

  ASSERT(mask_shift < 32);
  uint32 mask = 0xffffffffu << mask_shift;
  *bits |= mask;

  bits++;
  uint32 words = size >> WORD_SHIFT;
  ASSERT(words + mask_shift >= 32);
  for (words -= 32 - mask_shift; words >= 32; words -= 32)
    *bits++ = 0xffffffffu;
  *bits |= (1 << words) - 1;
}

void GcMetadata::mark_stack_overflow(HeapObject* object) {
  uword address = object->address();
  uint8* overflow_bits = overflow_bits_for(address);
  *overflow_bits |= 1 << ((address >> CARD_SIZE_LOG_2) & 7);
  // We can have a mark stack overflow in new-space where we do not normally
  // maintain object starts. By updating the object starts for this card we
  // can be sure that the necessary objects in this card are walkable.
  uint8* start = starts_for(address);
  ASSERT(CARD_SIZE_LOG_2 <= 8);
  uint8 low_byte = static_cast<uint8>(address);
  // We only overwrite the object start if we didn't have object start info
  // before or if this object is before the previous object start, which
  // would mean we would not scan the necessary object.
  if (*start == NO_OBJECT_START || *start > low_byte) *start = low_byte;
}

}  // namespace toit
