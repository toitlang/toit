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

import encoding.tison
import io show LITTLE-ENDIAN
import system.services show ServiceResource
import system.storage show Region
import uuid show *

import ..flash.allocation
import ..flash.registry

class RegionResource extends ServiceResource:
  client_/int
  handle_/int? := null

  constructor provider/StorageServiceProvider .client_ --offset/int --size/int --writable/bool:
    super provider client_
    try:
      handle := serialize-for-rpc
      flash-grant-access_ client_ handle offset size writable
      handle_ = handle
    finally: | is-exception _ |
      if is-exception: close

  revoke -> none:
    if not handle_: return
    flash-revoke-access_ client_ handle_
    handle_ = null

  on-closed -> none:
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
    id := Uuid.uuid5 NAMESPACE path
    allocation := find-allocation_ registry --id=id --if-absent=:
      if not capacity: throw "FILE_NOT_FOUND"
      // Allocate enough space for the requested capacity. We need
      // an extra page for the flash allocation header, which is
      // also where we store additional properties for the region.
      new-allocation_ registry --id=id --path=path --size=capacity + FLASH-REGISTRY-PAGE-SIZE
    offset := allocation.offset + FLASH-REGISTRY-PAGE-SIZE
    size := allocation.size - FLASH-REGISTRY-PAGE-SIZE
    if capacity and size < capacity: throw "Existing region is too small"
    resource := FlashRegionResource provider client --offset=offset --size=size --writable=writable
    return [
      resource.serialize-for-rpc,
      offset,
      size,
      FLASH-REGISTRY-PAGE-SIZE-LOG2,
      Region.MODE-WRITE-CAN-CLEAR-BITS_
    ]

  static delete registry/FlashRegistry -> none
      --path/string:
    id := Uuid.uuid5 NAMESPACE path
    allocation := find-allocation_ registry --id=id --if-absent=: return
    offset := allocation.offset + FLASH-REGISTRY-PAGE-SIZE
    size := allocation.size - FLASH-REGISTRY-PAGE-SIZE
    if flash-is-accessed_ offset size: throw "ALREADY_IN_USE"
    registry.free allocation

  static list registry/FlashRegistry -> List:
    result := []
    registry.do: | allocation/FlashAllocation |
      if allocation.type != FLASH-ALLOCATION-TYPE-REGION: continue.do
      properties-size := LITTLE-ENDIAN.uint16 allocation.metadata 0
      catch:
        properties := tison.decode allocation.content[..properties-size]
        result.add properties["path"]
    return result

  static find-allocation_ registry/FlashRegistry [--if-absent] -> FlashAllocation
      --id/Uuid:
    registry.do: | allocation/FlashAllocation |
      if allocation.type != FLASH-ALLOCATION-TYPE-REGION: continue.do
      if allocation.id == id: return allocation
    return if-absent.call

  static new-allocation_ registry/FlashRegistry -> FlashAllocation
      --id/Uuid
      --path/string
      --size/int:
    properties := tison.encode { "path": "flash:$path" }
    reservation := registry.reserve size
    if not reservation: throw "OUT_OF_SPACE"
    metadata := ByteArray 5: 0xff
    LITTLE-ENDIAN.put-uint16 metadata 0 properties.size
    return registry.allocate reservation
        --type=FLASH-ALLOCATION-TYPE-REGION
        --id=id
        --metadata=metadata
        --content=properties

class PartitionRegionResource extends RegionResource:
  // On the ESP32, we use partition type 0x40 for the
  // flash registry and 0x41 for region partitions.
  static ESP32-PARTITION-TYPE ::= 0x41
  static ESP32-PARTITION-TYPE-ANY ::= 0xff

  // On host platforms, we automatically create an
  // in-memory partition if we do not find an existing
  // one. This is useful primarily for testing.
  static HOST-DEFAULT-SIZE ::= 64 * 1024

  constructor provider/StorageServiceProvider client/int --offset/int --size/int --writable/bool:
    super provider client --offset=offset --size=size --writable=writable

  static open provider/StorageServiceProvider client/int -> List
      --path/string
      --capacity/int?
      --writable/bool:
    size := capacity or HOST-DEFAULT-SIZE
    // We allow read-only access to all partitions.
    type := writable ? ESP32-PARTITION-TYPE : ESP32-PARTITION-TYPE-ANY
    partition := flash-partition-find_ path type size
    offset := partition[0]
    size = partition[1]
    if capacity and size < capacity: throw "Existing region is too small"
    resource := PartitionRegionResource provider client --offset=offset --size=size --writable=writable
    return [
      resource.serialize-for-rpc,
      offset,
      size,
      FLASH-REGISTRY-PAGE-SIZE-LOG2,
      Region.MODE-WRITE-CAN-CLEAR-BITS_
    ]

// --------------------------------------------------------------------------

flash-grant-access_ client handle offset size writable:
  #primitive.flash.grant-access

flash-is-accessed_ offset size:
  #primitive.flash.is-accessed

flash-revoke-access_ client handle:
  #primitive.flash.revoke-access

flash-partition-find_ path type size -> List:
  #primitive.flash.partition-find
