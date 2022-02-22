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

#pragma once

#include "flash_allocation.h"
#include "flash_registry.h"

namespace toit {

// Queue header values.
static const uint8 SKIP_SEGMENT = 0x00;
static const uint8 ELEMENT_CONTINUE = 0x01;
static const uint8 ELEMENT_LAST_SEGMENT = 0x02;
static const uint8 FREE_SEGMENT = 0xFF;

static const int NO_ELEMENT = 17;

// Keep in sync with 'flash_allocations.toit'.
static const int WRITE_FAILED_CODE = -1;
static const int INCONSISTENT_QUEUE_CODE = -2;

// Keep in sync with 'flash_allocations.toit'.
enum elem_ret_code : int {
  OK = 0,
  INSUFFICIENT_CAPACITY = -1,
  EMPTY = -2,
  WRITE_FAILED = -3,
};

class ElementsMetaData {
 public:
  static const int NUMBER_OF_WRITE_SEGMENTS = 238;

  struct Element {
    int offset;
    int length;  // In write segments.
    int used_of_last_segment;

    int byte_length() {
      return (length - 1) * FLASH_SEGMENT_SIZE + used_of_last_segment;
    }
  };

 private:
  int _meta_data_address;
  word _first_segment_address;
  uint8 _header_data[NUMBER_OF_WRITE_SEGMENTS];

 public:
  ElementsMetaData(word address) {
    _meta_data_address = address + sizeof(FlashAllocation::Header);
    _first_segment_address = Utils::round_up(_meta_data_address + NUMBER_OF_WRITE_SEGMENTS, FLASH_SEGMENT_SIZE);
    FlashRegistry::read_raw_chunk(_meta_data_address, _header_data, NUMBER_OF_WRITE_SEGMENTS);
  }

  ~ElementsMetaData() { }

  int tail(int from = 0) {
    for (int i = from; i < NUMBER_OF_WRITE_SEGMENTS; i++) {
      uint8 value = _header_data[i];
      if (value == FREE_SEGMENT) {
        return i;
      }
    }
    return NUMBER_OF_WRITE_SEGMENTS;
  }

  Element find_head(int from = 0);

  bool is_free_range(int from, int length) {
    if (from + length > NUMBER_OF_WRITE_SEGMENTS) return false;

    for (int i = from; i < from + length; i++) {
      if (_header_data[i] != FREE_SEGMENT) {
        return false;
      }
    }
    return true;
  }

  bool mark_insert(int segment_offset, int size, List<uint8_t> buffer);

  bool mark_skip(int segment_offset) {
    return FlashRegistry::write_raw_chunk(&SKIP_SEGMENT, _meta_data_address + segment_offset, 1);
  }

  bool mark_skip(int segment_offset, uint8* segments, int size) {
    ASSERT(NUMBER_OF_WRITE_SEGMENTS);
    memset(segments, SKIP_SEGMENT, size);
    return FlashRegistry::write_raw_chunk(segments, _meta_data_address + segment_offset, size);
  }

  static int number_of_continues(int size) {
    if (size == 0) return 0;
    return Utils::round_down(size - 1, FLASH_SEGMENT_SIZE) / FLASH_SEGMENT_SIZE;
  }

  bool write_element(int offset, const uint8* byte_address, int byte_length);

  void read_element(uint8* bytes_address, int from, int length, int offset=0) {
    void* memory = FlashRegistry::memory(segment_address(from), length);
    memcpy(bytes_address + offset, memory, length);
    return;
  }

  int repair();

  int remove(int from);

 private:
  word segment_address(int segment_offset) {
    return _first_segment_address + segment_offset * FLASH_SEGMENT_SIZE;
  }
};

bool has_capacity(int tail, int element_size);

} // namespace toit
