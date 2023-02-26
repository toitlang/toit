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
static RegionGrantList grants;

static int const SCAN_HOLE = 0;
static int const SCAN_ALLOCATION = 1;
static int const SCAN_RESERVED = 2;

PRIMITIVE(next) {
  PRIVILEGED;
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
  PRIVILEGED;
  ARGS(int, current);
  if (current < 0 || flash_registry_offset_current != current) {
    OUT_OF_BOUNDS;
  }
  const FlashAllocation* allocation = FlashRegistry::allocation(current);
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
  PRIVILEGED;
  ARGS(int, offset, int, size);
  return Smi::from(FlashRegistry::erase_chunk(offset, size));
}

PRIMITIVE(get_id) {
  PRIVILEGED;
  ARGS(int, offset);
  // Load by-value as the ID may be used across multiple segments, and will
  // be cleared in flash when the segment is deleted.
  ByteArray* id = process->object_heap()->allocate_internal_byte_array(FlashAllocation::Header::id_size());
  if (id == null) ALLOCATION_FAILED;
  const FlashAllocation* allocation = FlashRegistry::allocation(offset);
  // Not normally possible, may indicate a bug or a worn flash chip.
  if (!allocation) FILE_NOT_FOUND;
  ByteArray::Bytes bytes(id);
  memcpy(bytes.address(), allocation->id(), FlashAllocation::Header::id_size());
  return id;
}

PRIMITIVE(get_size) {
  PRIVILEGED;
  ARGS(int, offset);
  const FlashAllocation* allocation = FlashRegistry::allocation(offset);
  if (allocation == null) INVALID_ARGUMENT;
  int size = allocation->size() + allocation->assets_size(null, null);
  return Smi::from(size);
}

PRIMITIVE(get_type) {
  PRIVILEGED;
  ARGS(int, offset);
  const FlashAllocation* allocation = FlashRegistry::allocation(offset);
  if (allocation == null) INVALID_ARGUMENT;
  return Smi::from(allocation->type());
}

PRIMITIVE(get_metadata) {
  PRIVILEGED;
  ARGS(int, offset);
  ByteArray* metadata = process->object_heap()->allocate_proxy();
  if (metadata == null) ALLOCATION_FAILED;
  const FlashAllocation* allocation = FlashRegistry::allocation(offset);
  // TODO(lau): Add support invalidation of proxy. The proxy is read-only and backed by flash.
  metadata->set_external_address(FlashAllocation::Header::METADATA_SIZE, const_cast<uint8*>(allocation->metadata()));
  return metadata;
}

PRIMITIVE(reserve_hole) {
  PRIVILEGED;
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

  reservations.insert_before(reservation, [&reservation](Reservation* other_reservation) -> bool {
    return reservation->right() <= other_reservation->left();
  });
  return process->program()->null_object();
}

PRIMITIVE(cancel_reservation) {
  PRIVILEGED;
  ARGS(int, offset);
  ASSERT(Utils::is_aligned(offset, FLASH_PAGE_SIZE));
  Reservation* reservation = reservations.remove_where([&offset](Reservation* reservation) -> bool {
    return reservation->left() == offset;
  });
  ASSERT(reservation != null);
  if (reservation == null) return process->program()->false_object();
  delete reservation;
  return process->program()->true_object();
}

PRIMITIVE(erase_flash_registry) {
  PRIVILEGED;
  return BOOL(FlashRegistry::erase_flash_registry());
}

PRIMITIVE(allocate) {
  PRIVILEGED;
  ARGS(int, offset, int, size, int, type, Blob, id_blob, Blob, metadata_blob);
  for (auto it = reservations.begin(); it != reservations.end(); ++it) {
    Reservation* reservation = *it;
    int reserved_offset = reservation->left();
    if (reserved_offset < offset) continue;
    if (reserved_offset > offset) break;
    ASSERT(reserved_offset == offset);

    uint8 id[UUID_SIZE];
    uint8 metadata[FlashAllocation::Header::METADATA_SIZE];
    if (reservation->size() != size
        || id_blob.length() != sizeof(id)
        || metadata_blob.length() != sizeof(metadata)) {
      INVALID_ARGUMENT;
    }
    memcpy(id, id_blob.address(), sizeof(id));
    memcpy(metadata, metadata_blob.address(), sizeof(metadata));

    if (!FlashAllocation::initialize(offset, type, id, size, metadata)) HARDWARE_ERROR;
    return process->program()->null_object();
  }
  ALREADY_CLOSED;
}

PRIMITIVE(grant_access) {
  PRIVILEGED;
  ARGS(int, client, int, handle, int, offset, int, size);
  RegionGrant* grant = _new RegionGrant(client, handle, offset, size);
  if (!grant) MALLOC_FAILED;
  Locker locker(OS::global_mutex());
  grants.prepend(grant);
  return process->program()->null_object();
}

PRIMITIVE(revoke_access) {
  PRIVILEGED;
  ARGS(int, client, int, handle);
  Locker locker(OS::global_mutex());
  grants.remove_where([&](RegionGrant* grant) -> bool {
    return grant->client() == client && grant->handle();
  });
  return process->program()->null_object();
}

class FlashRegion : public SimpleResource {
 public:
  TAG(FlashRegion);
  FlashRegion(SimpleResourceGroup* group, int offset, int size)
      : SimpleResource(group), offset_(offset), size_(size) {}

  int offset() const { return offset_; }
  int size() const { return size_; }

 private:
  int offset_;
  int size_;
};

PRIMITIVE(region_open) {
  ARGS(SimpleResourceGroup, group, int, client, int, handle, int, offset, int, size);

  bool found = false;
  { Locker locker(OS::global_mutex());
    for (auto it : grants) {
      if (it->client() == client && it->handle() == handle &&
          it->offset() == offset && it->size() == size) {
        found = true;
        break;
      }
    }
  }

  if (!found) PERMISSION_DENIED;
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (!proxy) ALLOCATION_FAILED;
  FlashRegion* resource = _new FlashRegion(group, offset, size);
  if (!resource) MALLOC_FAILED;
  proxy->set_external_address(resource);
  return proxy;
}

PRIMITIVE(region_close) {
  ARGS(FlashRegion, resource);
  resource->resource_group()->unregister_resource(resource);
  resource_proxy->clear_external_address();
  return process->program()->null_object();
}

static bool is_within_bounds(FlashRegion* resource, int from, int size) {
  if (from < 0 || size < 0) return false;
  int to = from + size;
  if (to < from || to > resource->size()) return false;
  return true;
}

PRIMITIVE(region_read) {
  ARGS(FlashRegion, resource, int, from, MutableBlob, bytes);
  int size = bytes.length();
  if (!is_within_bounds(resource, from, size)) OUT_OF_BOUNDS;
  FlashRegistry::flush();
  const uint8* region = FlashRegistry::region(resource->offset(), resource->size());
  memcpy(bytes.address(), region + from, size);
  return process->program()->null_object();
}

PRIMITIVE(region_write) {
  ARGS(FlashRegion, resource, int, from, Blob, bytes);
  int size = bytes.length();
  if (!is_within_bounds(resource, from, size)) OUT_OF_BOUNDS;
  if (!FlashRegistry::write_chunk(bytes.address(), from + resource->offset(), size)) {
    HARDWARE_ERROR;
  }
  return process->program()->null_object();
}

PRIMITIVE(region_is_erased) {
  ARGS(FlashRegion, resource, int, from, int, size);
  if (!is_within_bounds(resource, from, size)) OUT_OF_BOUNDS;
  return BOOL(FlashRegistry::is_erased(from + resource->offset(), size));
}

PRIMITIVE(region_erase) {
  ARGS(FlashRegion, resource, int, from, int, size);
  if (!is_within_bounds(resource, from, size)) OUT_OF_BOUNDS;
  if (!Utils::is_aligned(from, FLASH_PAGE_SIZE)) INVALID_ARGUMENT;
  if (!Utils::is_aligned(size, FLASH_PAGE_SIZE)) INVALID_ARGUMENT;
  if (!FlashRegistry::erase_chunk(from + resource->offset(), size)) {
    HARDWARE_ERROR;
  }
  return process->program()->null_object();
}

}
