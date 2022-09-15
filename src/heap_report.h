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

#pragma once

#include "top.h"

#include "encoder.h"

namespace toit {

static const uint8 MISC_MALLOC_TAG                = 0;
static const uint8 EXTERNAL_BYTE_ARRAY_MALLOC_TAG = 1;
static const uint8 BIGNUM_MALLOC_TAG              = 2;
static const uint8 EXTERNAL_STRING_MALLOC_TAG     = EXTERNAL_BYTE_ARRAY_MALLOC_TAG;
static const uint8 TOIT_HEAP_MALLOC_TAG           = 4;
static const uint8 FREE_MALLOC_TAG                = 6;
static const uint8 LWIP_MALLOC_TAG                = 7;
static const uint8 HEAP_OVERHEAD_MALLOC_TAG       = 8;
static const uint8 UNKNOWN_MALLOC_TAG             = 9;
static const uint8 OTHER_THREADS_MALLOC_TAG       = 11;
static const uint8 EVENT_SOURCE_MALLOC_TAG        = OTHER_THREADS_MALLOC_TAG;
static const uint8 THREAD_SPAWN_MALLOC_TAG        = OTHER_THREADS_MALLOC_TAG;
static const uint8 NULL_MALLOC_TAG                = 13;
static const uint8 WIFI_MALLOC_TAG                = LWIP_MALLOC_TAG;
static const uint8 NUMBER_OF_MALLOC_TAGS          = 15;

int compute_allocation_type(uword tag);

#ifdef TOIT_CMPCTMALLOC

class HeapFragmentationDumper : public Buffer {
 public:
  HeapFragmentationDumper(const char* reason, void* ignore_address)
    : current_page_(0),
      end_of_last_allocation_(0),
      ignore_address_(ignore_address),
      output_position_(0),
      pages_(0),
      encoder_(this),
      report_reason_(reason),
      unemitted_8_byte_overhead_(false),
      overflowed_(false) {}

  static inline bool log_allocation(void* self, void* tag, void* allocation, size_t size) {
    reinterpret_cast<HeapFragmentationDumper*>(self)->log_allocation(allocation, size, tag);
    return false;
  }

  void log_allocation(void* allocation, uword size, void* tag);
  void write_start();
  void rewrite_start(int size, int pages);
  void write_end();

  void flush() {
    // Fill the last buffer with 'N' which is the Ubjson no-op.
    if (output_position_ != 0) {
      memset(output_buffer_ + output_position_, 'N', WRITE_BLOCK_SIZE_ - output_position_);
      write_buffer(output_buffer_, WRITE_BLOCK_SIZE_);
    }
  }

  virtual void put_byte(uint8 byte) {
    output_buffer_[output_position_++] = byte;
    if (output_position_ == WRITE_BLOCK_SIZE_) {
      write_buffer(output_buffer_, WRITE_BLOCK_SIZE_);
      output_position_ = 0;
    }
  }

  uword pages() const { return pages_; }

  // There can be other allocations going on at the same time, so the predicted
  // size of the output string doesn't always fit.  This lets you query whether
  // the output buffer overflowed so you can retry.
  bool has_overflow() { return overflowed_; }

 protected:
  void set_overflow() { overflowed_ = true; }

  static const int WRITE_BLOCK_SIZE_ = 16;

 private:
  void switch_to_page(uword page);

  void write_map_byte(uint8 byte) {
    ASSERT(map_buffer_position_ < sizeof(map_buffer_));
    map_buffer_[map_buffer_position_++] = byte;
  }

  void write_interval(uword length, uint8 allocation_type);

  virtual void write_buffer(const uint8* str, uword length) = 0;

  static const uword PAGE_SIZE = 0x1000;
  static const uword GRANULARITY = 8;  // Atom of allocation.
  static const uword HEADER_SIZE = 8;  // Minimum header size of allocator.

  static const uword EXTRA_UNIT = GRANULARITY * 4;
  static const uword MAX_EXTRA = 0x7f * EXTRA_UNIT;

  static const uint8 EXTENSION_BYTE = 0x80;
  static const uint8 REGULAR_RANGE = 0x00;
  static const uint8 RANGE_PRECEEDED_BY_HEADER = 0x40;

  uword current_page_;
  uword end_of_last_allocation_;
  void* ignore_address_;
  uint8 output_buffer_[WRITE_BLOCK_SIZE_];
  int output_position_;
  uint8 map_buffer_[1 + PAGE_SIZE / (GRANULARITY + HEADER_SIZE)];
  uword map_buffer_position_;
  uword pages_;
  Encoder encoder_;
  const char* report_reason_;
  bool unemitted_8_byte_overhead_;
  bool overflowed_;
};

class SizeDiscoveryFragmentationDumper : public HeapFragmentationDumper {
 public:
  SizeDiscoveryFragmentationDumper(const char* description) :
      HeapFragmentationDumper(description, null),
      size_(0) {
    write_start();
  }

  virtual void write_buffer(const uint8* str, uword length) {
    size_ += length;
  }

  size_t size() const { return size_; }

 private:
  size_t size_;
};

// Dump a heap fragmentation report to the flash partition for crash dumps.
typedef void output_char_t(char);
extern void dump_heap_fragmentation(output_char_t* output_char_fn);

#endif // def TOIT_CMPCTMALLOC

}
