// Copyright (c) 2022, the Dartino project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

#include "../../top.h"

#include <stdio.h>

#include "../../utils.h"
#include "../../objects.h"

#include "gc_metadata.h"

namespace toit {

GcMetadata GcMetadata::singleton_;

void GcMetadata::tear_down() {
  OS::free_pages(singleton_.metadata_, singleton_.metadata_size_);
}

void GcMetadata::set_up() { singleton_.set_up_singleton(); }

void GcMetadata::set_up_singleton() {
  OS::HeapMemoryRange range = OS::get_heap_memory_range();

  uword range_address = reinterpret_cast<uword>(range.address);
  lowest_address_ = Utils::round_down(range_address, TOIT_PAGE_SIZE);
  uword size = Utils::round_up(range.size + range_address - lowest_address_, TOIT_PAGE_SIZE);
  heap_extent_ = size;
  heap_start_munged_ = (lowest_address_ >> 1) |
                       (static_cast<uword>(1) << (8 * sizeof(uword) - 1));
  heap_extent_munged_ = size >> 1;

  number_of_cards_ = size >> CARD_SIZE_LOG_2;

  uword mark_bits_size = size >> MARK_BITS_SHIFT;
  // Ensure there is a little slack after the mark bits for the border case
  // where we check a one-word object at the end of a page for blackness.
  // We need everything to stay word-aligned, so we add a full word of padding.
  mark_bits_size += sizeof(uword);

  uword mark_stack_overflow_bits_size = size >> CARD_SIZE_IN_BITS_LOG_2;

  uword cumulative_mark_bits_size = size >> CUMULATIVE_MARK_BITS_SHIFT;

  uword page_type_size_ = size >> TOIT_PAGE_SIZE_LOG2;

  metadata_size_ = Utils::round_up(
                                                               // Overhead on:        32bit   64bit
      number_of_cards_ +                   // One remembered set byte per card.       1/128   1/256
          number_of_cards_ +               // One object start offset byte per card.  1/128   1/256
          mark_bits_size +                 // One mark bit per word.                  1/32    1/64
          cumulative_mark_bits_size +      // One uword per 32 mark bits              1/32    1/32
          mark_stack_overflow_bits_size +  // One bit per card                        1/1024  1/2048
          page_type_size_,                 // One byte per page                       1/4096  1/32768
                                           //            Total:                       7.9%    5.5%
                                           //            Total without mark bits:     1.6%    0.8%
      TOIT_PAGE_SIZE);

  // We create all the metadata with just one allocation.  Otherwise we will
  // lose memory when the malloc rounds a series of big allocations up to 4k
  // page boundaries.
  metadata_ = reinterpret_cast<uint8*>(OS::grab_virtual_memory(null, metadata_size_));

  if (metadata_ == null) {
    printf("[toit] ERROR: failed to allocate GC metadata\n");
    abort();
  }

  // Mark bits must be page aligned so that mark_all detects page boundary
  // crossings, so we do that first.
  mark_bits_ = reinterpret_cast<uint32*>(metadata_);

  cumulative_mark_bit_counts_ = reinterpret_cast<uword*>(metadata_ + mark_bits_size);

  remembered_set_ = metadata_ + mark_bits_size + cumulative_mark_bits_size;

  object_starts_ = remembered_set_ + number_of_cards_;

  mark_stack_overflow_bits_ = object_starts_ + number_of_cards_;

  page_type_bytes_ = mark_stack_overflow_bits_ + mark_stack_overflow_bits_size;

  // The mark bits and cumulative mark bits are the biggest, so they are not
  // mapped in immediately in order to reduce the memory footprint of very
  // small programs.  We do it when we create pages that need them.
  OS::use_virtual_memory(remembered_set_, number_of_cards_);
  OS::use_virtual_memory(object_starts_, number_of_cards_);
  OS::use_virtual_memory(mark_stack_overflow_bits_, mark_stack_overflow_bits_size);
  OS::use_virtual_memory(page_type_bytes_, page_type_size_);
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
    Program* program, Chunk* src_chunk, GcMetadata::Destination dest) {
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
      dest.address += Utils::popcount(*mark_bits) << WORD_SHIFT;
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
      end = end_of_destination_of_last_live_object_starting_before(program, src, src + LINE_SIZE);
    }

    // Found a source line that has a real starts entry where all objects from
    // that line fit in the current destination chunk. But because of the way
    // the starts array works, we may have stepped too far back.  This is
    // because the first few object in the line (which may be the only live
    // ones) can only be iterated using the starts array for a previous line.
    uword end_of_last_src_line_that_fits =
        last_line_that_fits(program, src, dest.limit) + LINE_SIZE;
    uword end_of_last_source_object_moved = 0;
    uword dest_end = end_of_destination_of_last_live_object_starting_before(
        program, src, end_of_last_src_line_that_fits, &end_of_last_source_object_moved);

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
      *overhang_bits &= ~((1U << overhang) - 1);
    }
    src_start = src;
  }
}

uword GcMetadata::end_of_destination_of_last_live_object_starting_before(
    Program* program, uword line, uword limit, uword* src_end_return) {
  uint8 start = *starts_for(line);
  if (start == NO_OBJECT_START) return NO_END_FOUND;
  uword object_address = object_address_from_start(line, start);
  uword result = NO_END_FOUND;
  while (!has_sentinel_at(object_address) && object_address < limit) {
    // Uses cumulative mark bits!
    uword size = HeapObject::from_address(object_address)->size(program);
    if (is_marked(HeapObject::from_address(object_address))) {
      result = get_destination(HeapObject::from_address(object_address)) + size;
      if (src_end_return != null) *src_end_return = object_address + size;
    }
    object_address += size;
  }
  return result;
}

uword GcMetadata::last_line_that_fits(Program* program, uword line, uword dest_limit) {
  uint8 start = *starts_for(line);
  ASSERT(start != NO_OBJECT_START);
  HeapObject* object =
      HeapObject::from_address(object_address_from_start(line, start));
  uword dest = get_destination(object);  // Uses cumulative mark bits!
  ASSERT(!has_sentinel_at(object->_raw()));
  while (!has_sentinel_at(object->_raw()) &&
         (dest + object->size(program) <= dest_limit || !is_marked(object))) {
    object = HeapObject::from_address(object->_raw() + object->size(program));
    dest = get_destination(object);  // Uses cumulative mark bits!
  }
  uword last_line = object->_raw() & ~(LINE_SIZE - 1);
  if (has_sentinel_at(object->_raw())) {
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

// Mark all bits of an object whose mark bits may cross a 32 bit boundary.
// This routine only uses aligned 32 bit operations for the marking.
void GcMetadata::slow_mark(HeapObject* object, uword size) {
  int mask_shift = ((reinterpret_cast<uword>(object) >> WORD_SHIFT) & 31);
  uint32* bits = mark_bits_for(object);
  uint32 words = size >> WORD_SHIFT;

  if (words + mask_shift >= 32) {
    // Handle the first word of marking where some bits at the start of the 32
    // bit word are not set.
    uint32 mask = 0xffffffff;
    *bits |= mask << mask_shift;
  } else {
    // This is the case where the marked area both starts and ends in the same
    // 32 bit word.
    uint32 mask = 1;
    mask = (mask << words) - 1;
    *bits |= mask << mask_shift;
    return;
  }

  bits++;
  ASSERT(words + mask_shift >= 32);
  for (words -= 32 - mask_shift; words >= 32; words -= 32) {
    // Full words where all 32 bits are marked.
    *bits++ = 0xffffffff;
  }
  if (words != 0) {
    // The last word where some bits near the end of the word are not marked.
    *bits |= (1U << words) - 1;
  }
}

void GcMetadata::mark_stack_overflow(HeapObject* object) {
  uword address = object->_raw();
  uint8* overflow_bits = overflow_bits_for(address);
  *overflow_bits |= 1U << ((address >> CARD_SIZE_LOG_2) & 7);
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
