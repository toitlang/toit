// Copyright (c) 2022, the Dartino project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

#include "../../top.h"

#include <stdio.h>

#include "../../heap_report.h"
#include "../../objects.h"
#include "../../os_page_extent.h"
#include "../../utils.h"

#include "gc_metadata.h"

namespace toit {

#include "overflow_registration.h"

#ifdef TOIT_FREERTOS
// ESP32 has a cache line of 32 bytes, as does Cortex M7 and Cortex M3.
static const uword CACHE_LINE = 32;
#else
// It's OK to round up a little too much on other platforms, even if they have
// a 32 byte cache line.  Intel CPUs tend to have 64 bytes.
static const uword CACHE_LINE = 64;
#endif

GcMetadata GcMetadata::singleton_;

void GcMetadata::tear_down() {
  uint8* reservation = singleton_.metadata_;
  if (!reservation) return;
  uword bytes = singleton_.metadata_size_;
  int heuristics = singleton_.large_heap_heuristics_;
  singleton_ = GcMetadata{};
  singleton_.large_heap_heuristics_ = heuristics;
  OS::ungrab_virtual_memory(reservation, bytes);
}

void GcMetadata::get_metadata_extent(uword* address_return, uword* size_return) {
  *address_return = reinterpret_cast<uword>(singleton_.metadata_);
  *size_return = singleton_.metadata_size_;
}

void GcMetadata::set_up() {
  if (singleton_.metadata_) FATAL("GC metadata already initialized");
  GcMetadata tables{};
  tables.large_heap_heuristics_ = singleton_.large_heap_heuristics_;
  tables.initialize();
  singleton_ = tables;
}

// In internal ESP32 RAM, the low portion is used for C allocations. The
// metadata allocation rounds to 4 KiB, so keep the extra heap coverage
// available within the 12 KiB and 16 KiB metadata sizes.
static inline uword internal_ram_metadata_prefix(uword size) {
  const uword malloc_prefix = 108 * KB;
  const uword small_heap = 148 * KB;
  const uword medium_heap = 200 * KB;
  if (size <= small_heap) return 0;
  uword retained = size < small_heap + malloc_prefix ? small_heap : medium_heap;
  return Utils::min(malloc_prefix, size - retained);
}

void GcMetadata::initialize() {
  OS::HeapMemoryRange range = OS::get_heap_memory_range();

  uword range_address = reinterpret_cast<uword>(range.address);
  OSPageExtent pages;
  if (range.size == 0 || !OSPageExtent::covering(range_address, range.size, TOIT_PAGE_SIZE, &pages) ||
      pages.size > UINTPTR_MAX - pages.start) {
    FATAL("Invalid GC heap range");
  }
  lowest_address_ = pages.start;
  uword size = pages.size;
#ifdef TOIT_ESP32
  if (!OS::use_spiram_for_metadata() && !OS::use_spiram_for_heap()) {
    uword prefix = internal_ram_metadata_prefix(size);
    lowest_address_ += prefix;
    size -= prefix;
  }
#endif
  heap_extent_ = size;
  heap_start_munged_ = (lowest_address_ >> 1) |
                       (static_cast<uword>(1) << (8 * sizeof(uword) - 1));
  heap_extent_munged_ = size >> 1;

  // Round up the byte counts for various uses of Metadata so that there is no
  // false sharing of cache lines.  This is an optimization, and should not
  // affect correctness.
  number_of_cards_ = Utils::round_up(size >> CARD_SIZE_LOG_2, CACHE_LINE);

  uword mark_bits_size = Utils::round_up(size >> MARK_BITS_SHIFT, CACHE_LINE);

  uword mark_stack_overflow_bits_size = Utils::round_up(size >> CARD_SIZE_IN_BITS_LOG_2, CACHE_LINE);

  uword cumulative_mark_bits_size = Utils::round_up(size >> CUMULATIVE_MARK_BITS_SHIFT, CACHE_LINE);

  uword page_type_size = Utils::round_up(size >> TOIT_PAGE_SIZE_LOG2, CACHE_LINE);

  // One mark bit per heap word, then one destination word and two card
  // bytes per 32 heap words, one overflow bit per card, and one page byte.
  uword count_offset = mark_bits_size;
  uword remembered_offset = count_offset + cumulative_mark_bits_size;
  uword starts_offset = remembered_offset + number_of_cards_;
  uword overflow_offset = starts_offset + number_of_cards_;
  uword page_type_offset = overflow_offset + mark_stack_overflow_bits_size;
  metadata_size_ = Utils::round_up(page_type_offset + page_type_size, TOIT_PAGE_SIZE);

  // We create all the metadata with just one allocation.  Otherwise we will
  // lose memory when the malloc rounds a series of big allocations up to 4k
  // page boundaries.
  {
    HeapTagScope scope(ITERATE_CUSTOM_TAGS + TOIT_HEAP_MALLOC_TAG);
    metadata_ = reinterpret_cast<uint8*>(OS::grab_virtual_memory(null, metadata_size_));
  }

  if (metadata_ == null) {
    printf("[toit] ERROR: failed to allocate GC metadata\n");
    abort();
  }

  // Keep the mark bits and destination counts at the start for lazy commitment.
  mark_bits_ = reinterpret_cast<uint32*>(metadata_);

  cumulative_mark_bit_counts_ = reinterpret_cast<uword*>(metadata_ + count_offset);
  remembered_set_ = metadata_ + remembered_offset;
  object_starts_ = metadata_ + starts_offset;
  mark_stack_overflow_bits_ = metadata_ + overflow_offset;
  page_type_bytes_ = metadata_ + page_type_offset;

  // The mark bits and cumulative mark bits are the biggest, so they are not
  // mapped in immediately in order to reduce the memory footprint of very
  // small programs.  We do it when we create pages that need them.
  if (!OS::use_virtual_memory(remembered_set_, number_of_cards_) ||
      !OS::use_virtual_memory(object_starts_, number_of_cards_) ||
      !OS::use_virtual_memory(mark_stack_overflow_bits_, mark_stack_overflow_bits_size) ||
      !OS::use_virtual_memory(page_type_bytes_, page_type_size)) {
    OS::ungrab_virtual_memory(metadata_, metadata_size_);
    printf("[toit] ERROR: failed to commit GC metadata\n");
    abort();
  }
  memset(page_type_bytes_, UNKNOWN_SPACE_PAGE, page_type_size);

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
        // If we arrived here straight after a chunk switch, dest.address is
        // still biased below the chunk start to account for the tail of an
        // object placed in an earlier chunk (see below).  Nothing was placed
        // in this chunk, so its top is its start, and the bias must carry over
        // to the next chunk since the source line is unchanged.
        uword bias = 0;
        if (dest.address < dest.chunk()->start()) {
          bias = dest.chunk()->start() - dest.address;
        }
        dest.chunk()->set_compaction_top(dest.address + bias);
        dest = dest.next_chunk();
        dest.address -= bias;
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
    // We are starting a new destination chunk, but the src is pointing at
    // the start of a line that may start with the tail end of an object that
    // was moved to a different destination chunk. In order for the destination
    // calculation to work the dest address actually needs to point before the
    // start of the chunk, to compensate for the count of live bits that apply
    // to a different destination chunk.
    if (overhang > 0) {
      dest.address -= overhang;
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
  uint32* data = mark_bits_for(object);
  uword words = size >> WORD_SHIFT;

  Utils::mark_bits(data, mask_shift, words);
}

void GcMetadata::mark_stack_overflow(HeapObject* object) {
  uword address = object->_raw();  // Note we need this untagged because we write the low byte into the starts_for.
  // New space may have no recorded start. Recovery must begin at or before
  // every deferred object in this card, including any earlier registration.
  static_assert(CARD_SIZE_LOG_2 <= 8, "object starts fit the low address byte");
  static_assert(NO_OBJECT_START % WORD_SIZE != 0, "aligned object starts differ from the sentinel");
  record_overflow_start(overflow_bits_for(address), starts_for(address),
                        (address >> CARD_SIZE_LOG_2) & 7, static_cast<uint8>(address), NO_OBJECT_START);
}

}  // namespace toit
