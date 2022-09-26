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

#include "flash_registry.h"
#include "primitive.h"

#include "process.h"
#include "objects_inline.h"

namespace toit {

MODULE_IMPLEMENTATION(flash, MODULE_FLASH_REGISTRY)

static int flash_registry_offset_current = 0;
static int flash_registry_offset_next = 0;
static ReservationList reservations;
static ReservationList::Iterator reservation_scan = ReservationList::Iterator(null);

static int const SCAN_HOLE = 0;
static int const SCAN_ALLOCATION = 1;
static int const SCAN_RESERVED = 2;

PRIMITIVE(next) {
  ARGS(int, current);
  int result;
  if (current == -1) {
    reservation_scan = reservations.begin();
    result = 0;
  } else if (current != flash_registry_offset_current) {
    OUT_OF_BOUNDS;
  } else {
    result = flash_registry_offset_next;
  }

  // Compute the next.
  int next = FlashRegistry::find_next(result, &reservation_scan);
  if (next < 0) return process->program()->null_object();

  // Update current and next -- and return the result.
  flash_registry_offset_current = result;
  flash_registry_offset_next = next;
  return Smi::from(result);
}

PRIMITIVE(info) {
  ARGS(int, current);
  if (current < 0 || flash_registry_offset_current != current) {
    OUT_OF_BOUNDS;
  }
  const FlashAllocation* allocation = FlashRegistry::at(current);
  int page_size = (flash_registry_offset_next - current) >> 12;
  if (allocation == null) {
    if (reservation_scan != reservations.end() && current == reservation_scan->left()) {
      ++reservation_scan;
      return Smi::from(SCAN_RESERVED);
    } else {
      return Smi::from((page_size << 2) | SCAN_HOLE);
    }
  } else {
    int page_size_and_type = (page_size << 8) | allocation->type();
    return Smi::from((page_size_and_type << 2) | SCAN_ALLOCATION);
  }
}

PRIMITIVE(erase) {
  ARGS(int, offset, int, size);
  return Smi::from(FlashRegistry::erase_chunk(offset, size));
}

PRIMITIVE(get_id) {
  ARGS(int, offset);
  // Load by-value as the ID may be used across multiple segments, and will
  // be cleared in flash when the segment is deleted.
  ByteArray* id = process->object_heap()->allocate_internal_byte_array(FlashAllocation::Header::id_size());
  if (id == null) ALLOCATION_FAILED;
  const FlashAllocation* allocation = FlashRegistry::at(offset);
  // Not normally possible, may indicate a bug or a worn flash chip.
  if (!allocation) FILE_NOT_FOUND;
  ByteArray::Bytes bytes(id);
  memcpy(bytes.address(), allocation->id(), FlashAllocation::Header::id_size());
  return id;
}

PRIMITIVE(get_size) {
  ARGS(int, offset);
  const FlashAllocation* allocation = FlashRegistry::at(offset);
  if (allocation == null) INVALID_ARGUMENT;
  int size = allocation->size() + allocation->assets_size(null, null);
  return Smi::from(size);
}

PRIMITIVE(get_type) {
  ARGS(int, offset);
  const FlashAllocation* allocation = FlashRegistry::at(offset);
  if (allocation == null) INVALID_ARGUMENT;
  return Smi::from(allocation->type());
}

PRIMITIVE(get_metadata) {
  ARGS(int, offset);
  ByteArray* metadata = process->object_heap()->allocate_proxy();
  if (metadata == null) ALLOCATION_FAILED;
  const FlashAllocation* allocation = FlashRegistry::at(offset);
  // TODO(lau): Add support invalidation of proxy. The proxy is read-only and backed by flash.
  metadata->set_external_address(FlashAllocation::Header::METADATA_SIZE, const_cast<uint8*>(allocation->metadata()));
  return metadata;
}

PRIMITIVE(reserve_hole) {
  ARGS(int, offset, int, size);
  ASSERT(Utils::is_aligned(offset, FLASH_PAGE_SIZE));
  ASSERT(Utils::is_aligned(size, FLASH_PAGE_SIZE));
  if (size == 0) INVALID_ARGUMENT;
  Reservation* reservation = _new Reservation(offset, size);
  if (reservation == null) MALLOC_FAILED;

  // Check whether reservation overlaps with existing reservations.
  ReservationList::Iterator it = reservations.begin();
  Reservation* previous_reservation = null;
  while (it != reservations.end() && it->left() < reservation->right()) {
    previous_reservation = *it;
    ++it;
  }
  if ((previous_reservation != null && reservation->left() < previous_reservation->right()) ||
      (it != reservations.end() && it->left() < reservation->right())) {
    delete reservation;
    INVALID_ARGUMENT;
  }

  reservations.insert_before(reservation,[&reservation](Reservation* other_reservation) -> bool { return reservation->right() <= other_reservation->left(); });
  return process->program()->null_object();
}

PRIMITIVE(cancel_reservation) {
  ARGS(int, offset);
  ASSERT(Utils::is_aligned(offset, FLASH_PAGE_SIZE));
  Reservation* reservation = reservations.remove_where([&offset](Reservation* reservation) -> bool { return reservation->left() == offset; });
  ASSERT(reservation != null);
  if (reservation == null) return process->program()->false_object();
  delete reservation;
  return process->program()->true_object();
}

PRIMITIVE(erase_flash_registry) {
  PRIVILEGED;
  return BOOL(FlashRegistry::erase_flash_registry());
}

}
