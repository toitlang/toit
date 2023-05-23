// Copyright (C) 2023 Toitware ApS.
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

import .storage show StorageServiceProvider

import binary show LITTLE_ENDIAN
import encoding.tison
import system.services show ServiceResource
import system.storage show Region
import uuid

import ..flash.allocation
import ..flash.registry

class RegionResource extends ServiceResource:
  client_/int
  handle_/int? := null

  constructor provider/StorageServiceProvider .client_ --offset/int --size/int --writable/bool:
    super provider client_
    try:
      handle := serialize_for_rpc
      flash_grant_access_ client_ handle offset size writable
      handle_ = handle
    finally: | is_exception _ |
      if is_exception: close

  revoke -> none:
    if not handle_: return
    flash_revoke_access_ client_ handle_
    handle_ = null

  on_closed -> none:
    revoke

class FlashRegionResource extends RegionResource:
  static NAMESPACE ::= "flash:region"

  constructor provider/StorageServiceProvider client/int --offset/int --size/int --writable/bool:
    super provider client --offset=offset --size=size --writable=writable

  static open provider/StorageServiceProvider client/int -> List
      --path/string
      --capacity/int?
      --writable/bool:
    registry := provider.registry
    id := uuid.uuid5 NAMESPACE path
    allocation := find_allocation_ registry --id=id --if_absent=:
      if not capacity: throw "FILE_NOT_FOUND"
      // Allocate enough space for the requested capacity. We need
      // an extra page for the flash allocation header, which is
      // also where we store additional properties for the region.
      new_allocation_ registry --id=id --path=path --size=capacity + FLASH_REGISTRY_PAGE_SIZE
    offset := allocation.offset + FLASH_REGISTRY_PAGE_SIZE
    size := allocation.size - FLASH_REGISTRY_PAGE_SIZE
    if capacity and size < capacity: throw "Existing region is too small"
    resource := FlashRegionResource provider client --offset=offset --size=size --writable=writable
    return [
      resource.serialize_for_rpc,
      offset,
      size,
      FLASH_REGISTRY_PAGE_SIZE_LOG2,
      Region.MODE_WRITE_CAN_CLEAR_BITS_
    ]

  static delete registry/FlashRegistry -> none
      --path/string:
    id := uuid.uuid5 NAMESPACE path
    allocation := find_allocation_ registry --id=id --if_absent=: return
    offset := allocation.offset + FLASH_REGISTRY_PAGE_SIZE
    size := allocation.size - FLASH_REGISTRY_PAGE_SIZE
    if flash_is_accessed_ offset size: throw "ALREADY_IN_USE"
    registry.free allocation

  static list registry/FlashRegistry -> List:
    result := []
    registry.do: | allocation/FlashAllocation |
      if allocation.type != FLASH_ALLOCATION_TYPE_REGION: continue.do
      properties_size := LITTLE_ENDIAN.uint16 allocation.metadata 0
      catch:
        properties := tison.decode allocation.content[..properties_size]
        result.add properties["path"]
    return result

  static find_allocation_ registry/FlashRegistry [--if_absent] -> FlashAllocation
      --id/uuid.Uuid:
    registry.do: | allocation/FlashAllocation |
      if allocation.type != FLASH_ALLOCATION_TYPE_REGION: continue.do
      if allocation.id == id: return allocation
    return if_absent.call

  static new_allocation_ registry/FlashRegistry -> FlashAllocation
      --id/uuid.Uuid
      --path/string
      --size/int:
    properties := tison.encode { "path": "flash:$path" }
    reservation := registry.reserve size
    if not reservation: throw "OUT_OF_SPACE"
    metadata := ByteArray 5: 0xff
    LITTLE_ENDIAN.put_uint16 metadata 0 properties.size
    return registry.allocate reservation
        --type=FLASH_ALLOCATION_TYPE_REGION
        --id=id
        --metadata=metadata
        --content=properties

class PartitionRegionResource extends RegionResource:
  // On the ESP32, we use partition type 0x40 for the
  // flash registry and 0x41 for region partitions.
  static ESP32_PARTITION_TYPE ::= 0x41
  static ESP32_PARTITION_TYPE_ANY ::= 0xff

  // On host platforms, we automatically create an
  // in-memory partition if we do not find an existing
  // one. This is useful primarily for testing.
  static HOST_DEFAULT_SIZE ::= 64 * 1024

  constructor provider/StorageServiceProvider client/int --offset/int --size/int --writable/bool:
    super provider client --offset=offset --size=size --writable=writable

  static open provider/StorageServiceProvider client/int -> List
      --path/string
      --capacity/int?
      --writable/bool:
    size := capacity or HOST_DEFAULT_SIZE
    // We allow read-only access to all partitions.
    type := writable ? ESP32_PARTITION_TYPE : ESP32_PARTITION_TYPE_ANY
    partition := flash_partition_find_ path type size
    offset := partition[0]
    size = partition[1]
    if capacity and size < capacity: throw "Existing region is too small"
    resource := PartitionRegionResource provider client --offset=offset --size=size --writable=writable
    return [
      resource.serialize_for_rpc,
      offset,
      size,
      FLASH_REGISTRY_PAGE_SIZE_LOG2,
      Region.MODE_WRITE_CAN_CLEAR_BITS_
    ]

// --------------------------------------------------------------------------

flash_grant_access_ client handle offset size writable:
  #primitive.flash.grant_access

flash_is_accessed_ offset size:
  #primitive.flash.is_accessed

flash_revoke_access_ client handle:
  #primitive.flash.revoke_access

flash_partition_find_ path type size -> List:
  #primitive.flash.partition_find
