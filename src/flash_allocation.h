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

#include "linked.h"
#include "utils.h"
#include "uuid.h"

namespace toit {

// Keep in sync with flash_allocation.toit.
static const uint8 QUEUE_TYPE = 1;
static const uint8 PROGRAM_TYPE = 2;
static const uint8 KEY_VALUE_STORE_TYPE = 3;

static const int FLASH_PAGE_SIZE = 4 * KB;
static const int FLASH_SEGMENT_SIZE = 16;

class FlashAllocation {
 public:
  explicit FlashAllocation(uint32 offset);
  FlashAllocation();

  bool is_valid_allocation(const uint32 allocation_offset) const;

  void validate();

  static bool initialize(uint32 offset, uint8 type, const uint8* id, int size, uint8* meta_data);

  class __attribute__ ((__packed__)) Header {
   public:
    explicit Header(uint32 allocation_offset);

    Header(uint32 allocation_offset, uint8 type, const uint8* id, const uint8* uuid, int size, uint8* meta_data) {
      _marker = MARKER;
      _me = allocation_offset;
      _type = type;
      ASSERT(Utils::is_aligned(size, FLASH_PAGE_SIZE));
      memcpy(_id, id, id_size());
      _pages_in_flash = static_cast<uint16>(Utils::round_up(size, FLASH_PAGE_SIZE) >> 12);
      memcpy(_meta_data, meta_data, meta_data_size());
      set_uuid(uuid);
    }

    static int meta_data_size() { return sizeof(_meta_data); }
    static int id_size() { return sizeof(_id); }

   private:
    // Data section for the header.
    uint32 _marker;  // Magic marker.
    uint32 _me;      // Offset in allocation partition for validation.

    uint8 _id[16];

    uint8 _meta_data[5];  // Allocation specific meta data (picked to ensure 16 byte alignment).
    uint16 _pages_in_flash;
    uint8 _type;

    uint8 _uuid[UUID_SIZE];

    static const uint32 MARKER = 0xDEADFACE;

    bool is_valid(const uint8* uuid) const;
    const uint8* id() const { return _id; }
    uint8 type() const { return _type; }
    const uint8* meta_data() const { return _meta_data; }

    int size() const { return _pages_in_flash << 12; }

    bool is_valid_allocation(const uint32 allocation_offset) const;

    // Let the checksum be the last part of the header so that only
    // a complete flash write will mark this allocation as valid.
    void set_uuid(const uint8* uuid);

    void initialize(uint32 allocation_offset, const uint8* uuid) {
      _marker = MARKER;
      _me = allocation_offset;
      memset(_id, 0, id_size());
      _pages_in_flash = 0;
      memset(_meta_data, 0xFF, meta_data_size());
      set_uuid(uuid);
    }

    friend class FlashAllocation;
  };

  void set_header(uint32 allocation_offset, uint8* uuid) {
    _header.initialize(allocation_offset, uuid);
  }

  // Returns the size for programs stored in flash.
  int size() const { return _header.size(); }
  uint8 type() const { return _header.type(); }

  bool is_valid(uint32 allocation_offset, const uint8* uuid) const;

  // Returns a pointer to the id of the program.
  const uint8* id() const { return _header.id(); }
  const uint8* meta_data() const { return _header.meta_data(); }

 private:
  Header _header;
};

class Reservation;
typedef LinkedList<Reservation> ReservationList;
class Reservation : public ReservationList::Element {
 public:
  Reservation(int offset, int size) : _offset(offset), _size(size) {}

  const int left() const { return _offset; }
  const int right() const { return _offset + _size; }
  const int size() const { return _size; }

 private:
  int _offset;
  int _size;
};

} // namespace toit
