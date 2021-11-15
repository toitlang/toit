// Copyright (C) 2020 Toitware ApS.
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

#include <inttypes.h>
#include <stdint.h>

#include "top.h"

#include "heap_report.h"
#include "sha256.h"
#include "uuid.h"

#ifdef TOIT_FREERTOS

#include "esp_partition.h"
#include "esp_heap_caps.h"
#include <freertos/FreeRTOS.h>

#endif

namespace toit {

#ifdef TOIT_CMPCTMALLOC

void HeapFragmentationDumper::log_allocation(void* allocation, uword size, void* tag) {
  bool is_overhead = reinterpret_cast<word>(tag) == ITERATE_TAG_HEAP_OVERHEAD;

  // This does not affect embedded devices, but prevents the heap dumps from
  // getting too big on desktop machines.
  size = Utils::min(size, (uword)4 * MB);

  uword from = reinterpret_cast<uword>(allocation);
  ASSERT(from == Utils::round_up(from, GRANULARITY));
  uword to = from + Utils::round_up(size, GRANULARITY);
  uword ignore_address = reinterpret_cast<uword>(ignore_address_);
  if (from <= ignore_address && ignore_address < to) return;

  // Iterate over subranges that do not cross page boundaries.
  for (uword subrange = from; subrange < to; subrange = Utils::round_down(subrange + PAGE_SIZE, PAGE_SIZE)) {
    switch_to_page(subrange);
    uword subrange_end = Utils::min(to, subrange + PAGE_SIZE);
    size_t subrange_size = subrange_end - subrange;
    if (!unemitted_8_byte_overhead_ && is_overhead && subrange_size == 8) {
      unemitted_8_byte_overhead_ = true;
    } else {
      word wtag = reinterpret_cast<word>(tag);
      bool is_free = wtag == ITERATE_TAG_FREE;
      bool is_custom = (wtag >= ITERATE_CUSTOM_TAGS && wtag < ITERATE_CUSTOM_TAGS + 16);
      uint8 allocation_type =
          is_free ? FREE_MALLOC_TAG :
          is_overhead ? HEAP_OVERHEAD_MALLOC_TAG :
          is_custom ? (wtag - ITERATE_CUSTOM_TAGS) :
          MISC_MALLOC_TAG;
      write_interval(subrange_size, allocation_type);
      unemitted_8_byte_overhead_ = false;
    }
    end_of_last_allocation_ = subrange_end;
  }
}

void HeapFragmentationDumper::write_interval(uword length, uint8 allocation_type) {
  if (length == 0) {
    if (unemitted_8_byte_overhead_) {
      write_map_byte(HEAP_OVERHEAD_MALLOC_TAG);
    }
  } else {
    while (length > 4 * GRANULARITY) {
      uword extra = Utils::min(MAX_EXTRA, Utils::round_down(length - GRANULARITY, EXTRA_UNIT));
      length -= extra;
      write_map_byte(EXTENSION_BYTE | (extra / EXTRA_UNIT));
    }
    uint8 encoding = unemitted_8_byte_overhead_ ? RANGE_PRECEEDED_BY_HEADER : REGULAR_RANGE;
    write_map_byte(encoding | ((length - GRANULARITY) << 1) | allocation_type);
  }
  unemitted_8_byte_overhead_ = false;
}

void HeapFragmentationDumper::write_start() {
  put_byte('[');
  put_byte('#');
  encoder_.write_int(5);
  encoder_.write_int('X');
  encoder_.write_string(vm_git_version());
  encoder_.write_string(vm_sdk_model());
  // Normally there would be a program UUID here, but this is for the whole system,
  // so there is no particular program.
  encoder_.write_byte_array_header(UUID_SIZE);
  for (int i = 0; i < UUID_SIZE; i++) put_byte(0);
  // Last element is the payload.
  encoder_.write_header(2, 'H');  // H for heap map - see mirror.toit.
  encoder_.write_string(report_reason_);
  put_byte('[');  // Array.
  // We don't know how many pages there are so we don't output the length of the array
  // here - we have to end it with ']' instead.
}

void HeapFragmentationDumper::write_end() {
  switch_to_page(0);
  put_byte(']');  // End the pages array.
  flush();
}

void HeapFragmentationDumper::switch_to_page(uword address) {
  uword page = Utils::round_down(address, PAGE_SIZE);
  if (page != current_page_) {
    pages_++;
    if (current_page_ != 0) {
      write_interval(current_page_ + PAGE_SIZE - end_of_last_allocation_, UNKNOWN_MALLOC_TAG);
      encoder_.write_header(2, 'p');  // 'p' for page - see mirror.toit.
      encoder_.write_int(current_page_);
      encoder_.write_byte_array_header(map_buffer_position_);
      for (uword i = 0; i < map_buffer_position_; i++) put_byte(map_buffer_[i]);
    }
    map_buffer_position_ = 0;
    current_page_ = page;
    if (address != 0) {
      write_interval(address - page, UNKNOWN_MALLOC_TAG);
      end_of_last_allocation_ = address;
    }
  }
}

#ifdef TOIT_FREERTOS

class FlashHeapFragmentationDumper : public HeapFragmentationDumper {
 public:
  FlashHeapFragmentationDumper(const esp_partition_t* partition)
    : HeapFragmentationDumper("Out of memory heap report", null),
      partition_(partition),
      sha256_(null),
      position_(0) {
    // There's a 4 byte size field before the ubjson starts.  We will overwrite
    // this with the real size later.
    put_byte(0xff);
    put_byte(0xff);
    put_byte(0xff);
    put_byte(0xff);
    write_start();
  }

  virtual void write_end() {
    HeapFragmentationDumper::write_end();
    // After write_end, the last bit of data has been written out, and the output buffer
    // has been flushed.
    uword size = position_;
    uint8 checksum[Sha256::HASH_LENGTH];
    sha256_.get(checksum);
    write_buffer(checksum, Sha256::HASH_LENGTH);
    uint8 size_field[4];
    size_field[0] = size & 0xff;
    size_field[1] = (size >> 8) & 0xff;
    size_field[2] = (size >> 16) & 0xff;
    size_field[3] = (size >> 24) & 0xff;
    esp_partition_write(partition_, 0, size_field, 4);
  }

  virtual void write_buffer(const uint8* str, uword len) {
    ASSERT(len % WRITE_BLOCK_SIZE_ == 0);
    if (position_ == 0) {
      // We don't checksum the first 4 bytes, since this is not ubjson, it's
      // the length field, and it's incorrect (we go back and write it at the
      // end when we know the size).
      sha256_.add(str + 4, len - 4);
    } else {
      sha256_.add(str, len);
    }
    for (size_t i = 0; i < len; i += WRITE_BLOCK_SIZE_) {
      if (position_ >= partition_->size) {
        set_overflow();
        break;
      }
      if ((position_ & 0xfff) == 0) {
        int err = esp_partition_erase_range(partition_, position_, 0x1000);
        if (err != ESP_OK) return;
      }
      esp_partition_write(partition_, position_, str + i, WRITE_BLOCK_SIZE_);
      position_ += WRITE_BLOCK_SIZE_;
    }
  }

 private:
  const esp_partition_t* partition_;
  Sha256 sha256_;
  size_t position_;
};

class SerialFragmentationDumper : public HeapFragmentationDumper {
 public:
  SerialFragmentationDumper(output_char_t* output_char_fn)
    : HeapFragmentationDumper("Out of memory heap report", null)
    , output_char_fn_(output_char_fn) {
    write_start();
  }

  virtual void write_end() {
    HeapFragmentationDumper::write_end();
    encoder_.finish([&](uint8 c) {
      output_char_fn_(c);
    });
    output_char_fn_('\n');
  }

  virtual void write_buffer(const uint8* str, uword len) {
    encoder_.encode(str, len, [&](uint8 c) {
      output_char_fn_(c);
    });
  }

 private:
  output_char_t* output_char_fn_;
  Base64Encoder encoder_;
};

void dump_heap_fragmentation(output_char_t* output_char_fn) {
  const char* p = "toit serial decode ";
  while (*p) output_char_fn(*p++);

  SerialFragmentationDumper dumper(output_char_fn);

  int flags = MALLOC_ITERATE_ALL_ALLOCATIONS | MALLOC_ITERATE_UNALLOCATED | MALLOC_ITERATE_UNLOCKED;
  heap_caps_iterate_tagged_memory_areas(&dumper, null, HeapFragmentationDumper::log_allocation, flags);
  if (!dumper.has_overflow()) {
    dumper.write_end();  // Also writes length field at start.
  }
}

#endif

#endif // def TOIT_CMPCTMALLOC

}
