// Copyright (C) 2019 Toitware ApS.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

#include "elements.h"
#include "utils.h"
#include "top.h"
#include <algorithm>

namespace toit {

ElementsMetaData::Element ElementsMetaData::find_head(int from) {
  uint8 element_index = static_cast<uint8>(from);
  bool new_element = true;
  for (uint8 i = from; i < NUMBER_OF_WRITE_SEGMENTS; i++) {
    uint8 next = _header_data[i];
    if (next == SKIP_SEGMENT) {
      element_index = i + 1;
      new_element = true;
    } else if (next == ELEMENT_CONTINUE) {
      if (new_element) {
        element_index = i;
        new_element = false;
      }
    } else if (next == FREE_SEGMENT) {
      return Element {element_index, 0, NO_ELEMENT};
    } else {  // next is 2, ..., or 18.
      ASSERT(ELEMENT_LAST_SEGMENT <= next && next <= ELEMENT_LAST_SEGMENT + FLASH_SEGMENT_SIZE);
      return Element {
        element_index,
        i - element_index + 1,
        next - ELEMENT_LAST_SEGMENT
      };
    }
  }
  return Element {element_index, 0, NO_ELEMENT};
}

bool ElementsMetaData::mark_insert(int segment_offset, int size, List<uint8_t> continues_buffer) {
  ASSERT(continues_buffer.length() == number_of_continues(size));
  // Add the continues to the buffer.
  memset(continues_buffer.begin(), ELEMENT_CONTINUE, continues_buffer.length());
  int flash_segment_address = _metadata_address + segment_offset;
  bool success = FlashRegistry::write_raw_chunk(continues_buffer.begin(), flash_segment_address, continues_buffer.length());
  if (!success) return false;

  // Add the end of element segment value.
  int bytes_in_last_segment = size - continues_buffer.length() * FLASH_SEGMENT_SIZE;
  uint8_t end_segment = ELEMENT_LAST_SEGMENT + bytes_in_last_segment;

  return FlashRegistry::write_raw_chunk(&end_segment, flash_segment_address + continues_buffer.length(), 1);
}

bool ElementsMetaData::write_element(int offset, const uint8* bytes_address, int bytes_length) {
  word address = segment_address(offset);
  ASSERT(Utils::is_aligned(address, FLASH_SEGMENT_SIZE));
  if (bytes_length == 0) {
    // We don't care about the contents of an empty segment. Return immediately.
    return true;
  } else {
    return FlashRegistry::pad_and_write(bytes_address, address, bytes_length);
  }
}

int ElementsMetaData::repair() {
  uint8 all_empty[FLASH_SEGMENT_SIZE];
  memset(all_empty, 0xFF, FLASH_SEGMENT_SIZE);
  int first_free = NUMBER_OF_WRITE_SEGMENTS;
  bool is_inconsistent = false;
  bool needed_repair = false;
  bool consecutive_free_segment = false;

  for (int i = 0; i < NUMBER_OF_WRITE_SEGMENTS; i++) {
    uint8 next = _header_data[i];
    if (next == FREE_SEGMENT && memcmp(FlashRegistry::memory(segment_address(i), FLASH_SEGMENT_SIZE), all_empty, FLASH_SEGMENT_SIZE) != 0) {
      // The segment is marked as free in the header, but has content, i.e. the element was never committed.
      // Repair: Mark as skip.
      bool success = mark_skip(i);
      if (!success) return WRITE_FAILED_CODE;
      _header_data[i] = SKIP_SEGMENT;
      next = SKIP_SEGMENT;
      needed_repair = true;
    }

    if (next == FREE_SEGMENT) {
      // Locate the trailing free part of the queue.
      if (first_free == NUMBER_OF_WRITE_SEGMENTS) {
        // This is the first free segment we see. Record it.
        first_free = i;
        consecutive_free_segment = true;
      } else if (!consecutive_free_segment) {
        // We have already seen the first free segment, but there has been a non-free segment in between.
        is_inconsistent = true;
        first_free = NUMBER_OF_WRITE_SEGMENTS;
      }
    } else {
      consecutive_free_segment = false;
    }
  }
  if (!is_inconsistent) return needed_repair ? INCONSISTENT_QUEUE_CODE : 0;

  // We found non-trailing free segments. We must mark these segments as skip.
  // TODO(Lau): Consider marking everything in the header before first_free as skip.
  for (int i = 0; i < first_free; i++) {
    uint8 next = _header_data[i];
    if (next == FREE_SEGMENT) {
      mark_skip(i);
    }
  }
  return INCONSISTENT_QUEUE_CODE;
}

int ElementsMetaData::remove(int from) {
  Element element = find_head(from);
  if (element.used_of_last_segment == NO_ELEMENT) return EMPTY;

  bool success = mark_skip(element.offset + element.length - 1);
  if (!success) return WRITE_FAILED;

  return element.offset + element.length;
}

bool has_capacity(int tail, int element_byte_size) {
  if (tail == ElementsMetaData::NUMBER_OF_WRITE_SEGMENTS) return false;

  int segment_capacity_needed = std::max(1, Utils::round_up(element_byte_size, FLASH_SEGMENT_SIZE) / FLASH_SEGMENT_SIZE);
  return segment_capacity_needed <= ElementsMetaData::NUMBER_OF_WRITE_SEGMENTS - tail;
}

} // namespace toit
