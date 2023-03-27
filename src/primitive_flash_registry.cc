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

#ifdef TOIT_FREERTOS
#include "esp_partition.h"
#else
#include <string>
#include <unordered_map>
#endif

namespace toit {

MODULE_IMPLEMENTATION(flash, MODULE_FLASH_REGISTRY)

#ifndef TOIT_FREERTOS
static std::unordered_map<std::string, word*> partitions;
#endif

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

PRIMITIVE(get_size) {
  PRIVILEGED;
  ARGS(int, offset);
  const FlashAllocation* allocation = FlashRegistry::allocation(offset);
  if (allocation == null) INVALID_ARGUMENT;
  int size = allocation->size();
  if (allocation->is_program()) size += allocation->program_assets_size(null, null);
  return Smi::from(size);
}

PRIMITIVE(get_header_page) {
  PRIVILEGED;
  ARGS(int, offset);
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;
  FlashAllocation* allocation = FlashRegistry::allocation(offset);
  // Not normally possible, may indicate a bug or a worn flash chip.
  if (!allocation) FILE_NOT_FOUND;
  // TODO(lau): Add support invalidation of proxy. The proxy is read-only and backed by flash.
  proxy->set_external_address(FLASH_PAGE_SIZE, reinterpret_cast<uint8*>(allocation));
  return proxy;
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
  ARGS(int, offset, int, size, int, type, Blob, id, Blob, metadata, Blob, content);
  for (auto reservation : reservations) {
    int reserved_offset = reservation->left();
    if (reserved_offset < offset) continue;
    if (reserved_offset > offset) break;
    ASSERT(reserved_offset == offset);

    if (reservation->size() != size
        || id.length() != FlashAllocation::Header::ID_SIZE
        || metadata.length() != FlashAllocation::Header::METADATA_SIZE) {
      INVALID_ARGUMENT;
    }

    int content_length = content.length();
    if (content_length > 0) {
      int header_offset = sizeof(FlashAllocation::Header);
      if (content_length > FLASH_PAGE_SIZE - header_offset) {
        OUT_OF_BOUNDS;
      }

      if (!FlashRegistry::write_chunk(content.address(), offset + header_offset, content_length)) {
        HARDWARE_ERROR;
      }
    }

    const FlashAllocation::Header header(offset, type, id.address(), size, metadata.address());
    if (!FlashAllocation::commit(offset, size, &header)) HARDWARE_ERROR;
    return process->program()->null_object();
  }
  ALREADY_CLOSED;
}

PRIMITIVE(grant_access) {
  PRIVILEGED;
  ARGS(int, client, int, handle, uword, offset, uword, size);
  RegionGrant* grant = _new RegionGrant(client, handle, offset, size);
  if (!grant) MALLOC_FAILED;
  Locker locker(OS::global_mutex());
  for (auto it : grants) {
    if (it->offset() == offset && it->size() == size) ALREADY_IN_USE;
  }
  grants.prepend(grant);
  return process->program()->null_object();
}

PRIMITIVE(is_accessed) {
  PRIVILEGED;
  ARGS(uword, offset, uword, size);
  Locker locker(OS::global_mutex());
  for (auto it : grants) {
    if (it->offset() == offset && it->size() == size) {
      return BOOL(true);
    }
  }
  return BOOL(false);
}

PRIMITIVE(revoke_access) {
  PRIVILEGED;
  ARGS(int, client, int, handle);
  Locker locker(OS::global_mutex());
  grants.remove_where([&](RegionGrant* grant) -> bool {
    return grant->client() == client && grant->handle() == handle;
  });
  return process->program()->null_object();
}

PRIMITIVE(partition_find) {
  PRIVILEGED;
  ARGS(cstring, path, int, type, uword, size);
  if (size <= 0 || (type < 0x00) || (type > 0xfe)) INVALID_ARGUMENT;
  Array* result = process->object_heap()->allocate_array(2, Smi::zero());
  if (!result) ALLOCATION_FAILED;
#ifdef TOIT_FREERTOS
  const esp_partition_t* partition = esp_partition_find_first(
      static_cast<esp_partition_type_t>(type),
      ESP_PARTITION_SUBTYPE_ANY,
      path);
  if (!partition) FILE_NOT_FOUND;
  uword offset = partition->address;
  size = partition->size;
#else
  std::string key(path);
  auto probe = partitions.find(path);
  word* partition;
  if (probe == partitions.end()) {
    // TODO(kasper): Use mmap and get the right alignment.
    size = Utils::round_up(size, FLASH_PAGE_SIZE);
    partition = static_cast<word*>(malloc(size + sizeof(word)));
    memset(partition + 1, 0xff, size);
    *partition = size;
    AllowThrowingNew host_only;
    partitions[key] = partition;
  } else {
    partition = probe->second;
    size = *partition;
  }
  uword offset = reinterpret_cast<word>(partition + 1);
#endif
  // TODO(kasper): Clean up the offset tagging.
  Object* offset_entry = Primitive::integer(offset + 1, process);
  if (Primitive::is_error(offset_entry)) return offset_entry;
  Object* size_entry = Primitive::integer(size, process);
  if (Primitive::is_error(size_entry)) return size_entry;
  result->at_put(0, offset_entry);
  result->at_put(1, size_entry);
  return result;
}

class FlashRegion : public SimpleResource {
 public:
  TAG(FlashRegion);
  FlashRegion(SimpleResourceGroup* group, uword offset, uword size)
      : SimpleResource(group), offset_(offset), size_(size) {}

  uword offset() const { return offset_; }
  uword size() const { return size_; }

 private:
  uword offset_;
  uword size_;
};

PRIMITIVE(region_open) {
  ARGS(SimpleResourceGroup, group, int, client, int, handle, uword, offset, uword, size);

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

static bool is_within_bounds(FlashRegion* resource, word from, uword size) {
  word to = from + size;
  return 0 <= from && from < to && static_cast<uword>(to) <= resource->size();
}

PRIMITIVE(region_read) {
  ARGS(FlashRegion, resource, word, from, MutableBlob, bytes);
  uword size = bytes.length();
  if (!is_within_bounds(resource, from, size)) OUT_OF_BOUNDS;
  word offset = resource->offset();
  if ((offset & 1) == 0) {
    FlashRegistry::flush();
    const uint8* region = FlashRegistry::region(offset, resource->size());
    memcpy(bytes.address(), region + from, size);
  } else {
#ifdef TOIT_FREERTOS
    uword region = offset - 1;
    uword source = region + from;
    uint8* destination = bytes.address();
    if (esp_flash_read(NULL, destination, source, size) != ESP_OK) {
      HARDWARE_ERROR;
    }
#else
    uint8* region = reinterpret_cast<uint8*>(offset - 1);
    memcpy(bytes.address(), region + from, size);
#endif
  }
  return process->program()->null_object();
}

PRIMITIVE(region_write) {
  ARGS(FlashRegion, resource, word, from, Blob, bytes);
  uword size = bytes.length();
  if (!is_within_bounds(resource, from, size)) OUT_OF_BOUNDS;
  uword offset = resource->offset();
  if ((offset & 1) == 0) {
    if (!FlashRegistry::write_chunk(bytes.address(), from + offset, size)) {
      HARDWARE_ERROR;
    }
  } else {
#ifdef TOIT_FREERTOS
    uword region = offset - 1;
    uword destination = region + from;
    const uint8* source = bytes.address();
    if (esp_flash_write(NULL, source, destination, size) != ESP_OK) {
      HARDWARE_ERROR;
    }
#else
    uint8* region = reinterpret_cast<uint8*>(offset - 1);
    uint8* destination = region + from;
    const uint8* source = bytes.address();
    for (uword i = 0; i < size; i++) destination[i] &= source[i];
#endif
  }
  return process->program()->null_object();
}

PRIMITIVE(region_is_erased) {
  ARGS(FlashRegion, resource, word, from, uword, size);
  if (!is_within_bounds(resource, from, size)) OUT_OF_BOUNDS;
  uword offset = resource->offset();
  if ((offset & 1) == 0) {
    return BOOL(FlashRegistry::is_erased(from + offset, size));
  } else {
#ifdef TOIT_FREERTOS
    static const uword BUFFER_SIZE = 256;
    AllocationManager allocation(process);
    uint8* buffer = allocation.alloc(BUFFER_SIZE);
    if (!buffer) ALLOCATION_FAILED;
    uword region = offset - 1;
    word to = from + size;
    while (true) {
      uword remaining = to - from;
      if (remaining == 0) return BOOL(true);
      uword n = Utils::min(remaining, BUFFER_SIZE);
      if (esp_flash_read(NULL, buffer, region + from, n) != ESP_OK) {
        HARDWARE_ERROR;
      }
      for (uword i = 0; i < n; i++) {
        if (buffer[i] != 0xff) return BOOL(false);
      }
      from += n;
    }
#else
    uint8* region = reinterpret_cast<uint8*>(offset - 1);
    for (uword i = 0; i < size; i++) {
      if (region[i] != 0xff) return BOOL(false);
    }
    return BOOL(true);
#endif
  }
}

PRIMITIVE(region_erase) {
  ARGS(FlashRegion, resource, word, from, uword, size);
  if (!is_within_bounds(resource, from, size)) OUT_OF_BOUNDS;
  if (!Utils::is_aligned(from, FLASH_PAGE_SIZE)) INVALID_ARGUMENT;
  if (!Utils::is_aligned(size, FLASH_PAGE_SIZE)) INVALID_ARGUMENT;
  uword offset = resource->offset();
  if ((offset & 1) == 0) {
    if (!FlashRegistry::erase_chunk(from + offset, size)) {
      HARDWARE_ERROR;
    }
  } else {
#ifdef TOIT_FREERTOS
    uword region = offset - 1;
    uword destination = region + from;
    if (esp_flash_erase_region(NULL, destination, size) != ESP_OK) {
      HARDWARE_ERROR;
    }
#else
    uint8* region = reinterpret_cast<uint8*>(offset - 1);
    memset(region + from, 0xff, size);
#endif
  }
  return process->program()->null_object();
}

}
