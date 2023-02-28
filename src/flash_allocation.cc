// Copyright (C) 2018 Toitware ApS.
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

#include "flash_registry.h"
#include "flash_allocation.h"
#include "embedded_data.h"
#include "uuid.h"

namespace toit {

// Flash allocations that only contain data can be tagged with
// the special constructed UUID. This allows future versions
// of the SDK to continue to read those allocations as long as
// the Header::FORMAT_VERSION hasn't changed.
static const uint8 DATA_UUID[UUID_SIZE] = {
  0x3d,
  0x29 ^ FlashAllocation::Header::FORMAT_VERSION,
  0x85, 0x96, 0x63, 0x7f, 0x43, 0x9c,
  0xb6, 0x51, 0x90, 0xfd, 0xcb, 0xc0, 0xdf, 0x9a
};

static void initialize(void* dst, const void* src, size_t size) {
  if (src != null) {
    memcpy(dst, src, size);
  } else {
    memset(dst, 0, size);
  }
}

FlashAllocation::Header::Header(uint32 offset,
                                uint8 type,
                                const uint8* id,
                                int size,
                                const uint8* metadata) {

  marker_ = FORMAT_MARKER;
  me_ = offset;
  initialize(id_, id, sizeof(id_));
  initialize(metadata_, metadata, sizeof(metadata_));
  ASSERT(Utils::is_aligned(size, FLASH_PAGE_SIZE));
  type_ = type;
  size_in_pages_ = static_cast<uint16>(Utils::round_up(size, FLASH_PAGE_SIZE) >> 12);
  if (type == FLASH_ALLOCATION_TYPE_REGION) {
    memcpy(uuid_, DATA_UUID, sizeof(uuid_));
  } else {
    memcpy(uuid_, EmbeddedData::uuid(), sizeof(uuid_));
  }
}

bool FlashAllocation::Header::is_valid(uint32 offset) const {
  if (marker_ != FORMAT_MARKER || me_ != offset) return false;
  if (type_ == FLASH_ALLOCATION_TYPE_REGION) {
    return memcmp(uuid_, DATA_UUID, UUID_SIZE) == 0;
  } else {
    return memcmp(uuid_, EmbeddedData::uuid(), UUID_SIZE) == 0;
  }
}

bool FlashAllocation::is_valid(uint32 offset) const {
  return header_.is_valid(((offset & 1) == 0) ? offset : 0);
}

bool FlashAllocation::commit(uint32 offset, int size, const Header* header) {
  if (static_cast<unsigned>(size) < sizeof(Header)) return false;
  void* result = FlashRegistry::region(offset, size);
  bool success = FlashRegistry::write_chunk(header, offset, sizeof(Header));
  FlashRegistry::flush();
  return success && static_cast<FlashAllocation*>(result)->is_valid(offset);
}

int FlashAllocation::program_assets_size(uint8** bytes, int* length) const {
  if (!program_has_assets()) return 0;
  uword allocation_address = reinterpret_cast<uword>(this);
  uword assets_address = allocation_address + size();
  int assets_length = *reinterpret_cast<uint32*>(assets_address);
  if (bytes) *bytes = reinterpret_cast<uint8*>(assets_address + sizeof(uint32));
  if (length) *length = assets_length;
  return Utils::round_up(assets_length + sizeof(uint32), FLASH_PAGE_SIZE);
}

}  // namespace toit
