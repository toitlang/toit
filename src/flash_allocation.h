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

// Keep in sync with system/flash/allocation.toit.
static const uint8 PROGRAM_TYPE = 0;

static const int FLASH_PAGE_SIZE = 4 * KB;
static const int FLASH_SEGMENT_SIZE = 16;

class FlashAllocation {
 public:
  explicit FlashAllocation(uint32 offset);
  FlashAllocation();

  bool is_valid_allocation(const uint32 allocation_offset) const;

  void validate();

  static bool initialize(uint32 offset, uint8 type, const uint8* id, int size, const uint8* metadata);

  class __attribute__ ((__packed__)) Header {
   public:
    static const int METADATA_SIZE = 5;
    static const int FLAGS_HAS_ASSETS_MASK = 1 << 7;

    explicit Header(uint32 allocation_offset);

    Header(uint32 allocation_offset, uint8 type, const uint8* id, const uint8* uuid, int size, const uint8* metadata) {
      _marker = MARKER;
      _me = allocation_offset;
      _type = type;
      ASSERT(Utils::is_aligned(size, FLASH_PAGE_SIZE));
      memcpy(_id, id, id_size());
      _pages_in_flash = static_cast<uint16>(Utils::round_up(size, FLASH_PAGE_SIZE) >> 12);
      memcpy(_metadata, metadata, METADATA_SIZE);
      set_uuid(uuid);
    }

    static int id_size() { return sizeof(_id); }
    const uint8* id() const { return _id; }
    int size() const { return _pages_in_flash << 12; }

   private:
    // Data section for the header.
    uint32 _marker;  // Magic marker.
    uint32 _me;      // Offset in allocation partition for validation.

    uint8 _id[UUID_SIZE];

    uint8 _metadata[METADATA_SIZE];  // Allocation specific meta data (picked to ensure 16 byte alignment).
    uint16 _pages_in_flash;
    uint8 _type;

    uint8 _uuid[UUID_SIZE];

    static const uint32 MARKER = 0xDEADFACE;

    bool is_valid(const uint8* uuid) const;
    uint8 type() const { return _type; }
    const uint8* metadata() const { return _metadata; }

    bool is_valid_allocation(const uint32 allocation_offset) const;

    // Let the image uuid be the last part of the header so that only
    // a complete flash write will mark this allocation as valid.
    void set_uuid(const uint8* uuid);

    void initialize(uint32 allocation_offset, const uint8* uuid, const uint8* id) {
      _marker = MARKER;
      _me = allocation_offset;
      if (id == null) {
        memset(_id, 0, id_size());
      } else {
        memcpy(_id, id, id_size());
      }
      _pages_in_flash = 0;
      memset(_metadata, 0xFF, METADATA_SIZE);
      set_uuid(uuid);
    }

    friend class FlashAllocation;
  };

  void set_header(uint32 allocation_offset, uint8* uuid, const uint8* id = null) {
    _header.initialize(allocation_offset, uuid, id);
  }

  // Returns the size for programs stored in flash.
  int size() const { return _header.size(); }
  uint8 type() const { return _header.type(); }

  bool is_valid(uint32 allocation_offset, const uint8* uuid) const;

  // Returns a pointer to the id of the program.
  const uint8* id() const { return _header.id(); }
  const uint8* metadata() const { return _header.metadata(); }

  // Returns whether the allocation has appended assets.
  bool has_assets() const {
    int flags = _header.metadata()[0];
    return (flags & Header::FLAGS_HAS_ASSETS_MASK) != 0;
  }

  // Get the total size of the appended assets if any.
  int assets_size(uint8** bytes, int* length) const;

 private:
  Header _header;
};

class Reservation;
typedef LinkedList<Reservation> ReservationList;
class Reservation : public ReservationList::Element {
 public:
  Reservation(int offset, int size) : _offset(offset), _size(size) {}

  int left() const { return _offset; }
  int right() const { return _offset + _size; }
  int size() const { return _size; }

 private:
  int _offset;
  int _size;
};

} // namespace toit
