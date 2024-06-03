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

uint32 FlashAllocation::Header::compute_checksum(const void* memory) const {
  // The checksum covers the virtual address of the allocation. This
  // is useful if the allocation contains relocated pointers to parts
  // of itself. In that case, those pointers are only correct if the
  // allocation is always access from the same virtual memory address.
  // We don't need to do that for data as it doesn't have pointers in it.
  uint32 initial = (type_ == FLASH_ALLOCATION_TYPE_REGION)
      ? FORMAT_MARKER
      : Utils::crc32(FORMAT_MARKER, reinterpret_cast<uint8*>(&memory), sizeof(memory));
  // The rest of the header is also covered. This gives a much
  // stronger header validation check and reduces the risk of
  // accidentally treating garbage in the flash as allocations.
  return Utils::crc32(initial, id_, sizeof(Header) - offsetof(Header, id_));
}

FlashAllocation::Header::Header(const void* memory,
                                uint8 type,
                                const uint8* id,
                                word size,
                                const uint8* metadata) {
  marker_ = FORMAT_MARKER;
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
  checksum_ = compute_checksum(memory);
}

word FlashAllocation::size() const {
  word size = size_no_assets();
  if (is_program()) size += program_assets_size(null, null);
  return size;
}

bool FlashAllocation::Header::is_valid(bool embedded) const {
  if (marker_ != FORMAT_MARKER || size_in_pages_ == 0) return false;
  if (embedded) {
    // All programs embedded in the binary have a zero checksum.
    if (checksum_ != 0) return false;
  } else {
    uint32 checksum = compute_checksum(this);
    if (checksum_ != checksum) return false;
    if (type_ == FLASH_ALLOCATION_TYPE_REGION) {
      return memcmp(uuid_, DATA_UUID, UUID_SIZE) == 0;
    }
  }
  if (type_ != FLASH_ALLOCATION_TYPE_PROGRAM) return false;
  return memcmp(uuid_, EmbeddedData::uuid(), UUID_SIZE) == 0;
}

bool FlashAllocation::commit(const void* memory, word size, const Header* header) {
  if (static_cast<unsigned>(size) < sizeof(Header)) return false;
  uint32 offset = FlashRegistry::offset(memory);
  bool success = FlashRegistry::write_chunk(header, offset, sizeof(Header));
  FlashRegistry::flush();
  return success && static_cast<const FlashAllocation*>(memory)->is_valid();
}

int FlashAllocation::program_assets_size(uint8** bytes, word* length) const {
  if (!program_has_assets()) return 0;
  uword allocation_address = reinterpret_cast<uword>(this);
  uword assets_address = allocation_address + size_no_assets();
  int assets_length = *reinterpret_cast<uint32*>(assets_address);
  if (bytes) *bytes = reinterpret_cast<uint8*>(assets_address + sizeof(uint32));
  if (length) *length = assets_length;
  return Utils::round_up(assets_length + sizeof(uint32), FLASH_PAGE_SIZE);
}

}  // namespace toit
