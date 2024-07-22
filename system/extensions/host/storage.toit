// Copyright (C) 2024 Toitware ApS.
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

import system.assets
import system.storage show Bucket
import uuid show *

import ...flash.allocation show
    FlashAllocation
    FLASH-ALLOCATION-HEADER-SIZE
    FLASH-ALLOCATION-TYPE-REGION

import ...flash.registry show FlashRegistry FLASH-REGISTRY-PAGE-SIZE
import ...storage show StorageServiceProvider
import ...storage.bucket show BucketResource RamBucketResource

class StorageServiceProviderHost extends StorageServiceProvider:
  constructor registry/FlashRegistry:
    super "system/storage/host" registry

  bucket-open client/int --scheme/string --path/string -> BucketResource:
    if scheme == Bucket.SCHEME-RAM:
      return RamBucketResource this client path
    else if scheme == Bucket.SCHEME-FLASH:
      return FlashBucketResourceHost this client path
    throw "Unsupported '$scheme:' scheme"

class FlashBucketResourceHost extends BucketResource:
  root/string
  bucket/FlashBucket? := ?

  constructor provider/StorageServiceProvider client/int .root:
    bucket = FlashBucket root --registry=provider.registry
    super provider client

  get key/string -> ByteArray?:
    return bucket.get key

  set key/string value/ByteArray -> none:
    bucket.set key value

  remove key/string -> none:
    bucket.remove key

  on-closed -> none:
    bucket.unuse root
    bucket = null

/**
The $FlashBucket represents a single bucket in flash. It is shared
  by all resources for the same bucket, so the caching works.
*/
class FlashBucket:
  static NAMESPACE ::= "flash:bucket"

  id/Uuid
  registry/FlashRegistry

  cache-allocation_/FlashAllocation? := null
  cache-entries_/Map? := null
  users_/int := 0

  static instances_ := {:}  // Map<string, FlashBucket>

  constructor.internal_ --.id --.registry:
    allocation := find-allocation_ --id=id --registry=registry
    if allocation:
      cache-allocation_ = allocation
      pages := flash-get-all-pages_ allocation.offset
      entries := assets.decode pages[FLASH-ALLOCATION-HEADER-SIZE..]
      // The found entry values point into the flash. To avoid issues,
      // when we free the currently cached allocation, we copy them to
      // RAM.
      cache_entries_ = entries.map: | key value | value.copy

  constructor root/string --registry/FlashRegistry:
    instance := instances_.get root --init=:
      id := Uuid.uuid5 NAMESPACE root
      FlashBucket.internal_ --id=id --registry=registry
    return instance.use

  use -> FlashBucket:
    users_++
    return this

  unuse root/string -> none:
    if users_-- > 1: return
    instances_.remove root

  get key/string -> ByteArray?:
    entries := cache-entries_
    return entries and entries.get key --if-present=:
      // Wrap the entry in a slice, so we're sure that the
      // cached entry isn't neutered when we send it back.
      ByteArraySlice_ it 0 it.size

  set key/string value/ByteArray -> none:
    update_ --extend: it[key] = value

  remove key/string -> none:
    update_ --no-extend: it.remove key --if-absent=: return

  update_ --extend/bool [block] -> none:
    entries := cache-entries_
    if not entries:
      if not extend: return
      entries = {:}
      cache-entries_ = entries
    block.call entries
    existing := cache-allocation_
    if entries.is-empty:
      cache-entries_ = null
      cache-allocation_ = null
    else:
      encoded := assets.encode entries
      size := FLASH-ALLOCATION-HEADER-SIZE + encoded.size
      reservation := registry.reserve size
      if not reservation: throw "OUT_OF_SPACE"
      metadata := ByteArray 5: 0xff
      cutoff := FLASH-REGISTRY-PAGE-SIZE - FLASH-ALLOCATION-HEADER-SIZE
      if encoded.size > cutoff:
        flash-write-non-header-pages_ reservation.offset encoded[cutoff..]
      else:
        cutoff = encoded.size
      cache-allocation_ = registry.allocate reservation
          --type=FLASH-ALLOCATION-TYPE-REGION
          --id=id
          --metadata=metadata
          --content=encoded[..cutoff]
    if existing: registry.free existing

  static find-allocation_ --id/Uuid --registry/FlashRegistry -> FlashAllocation?:
    registry.do: | allocation/FlashAllocation |
      if allocation.type != FLASH-ALLOCATION-TYPE-REGION: continue.do
      // Buckets and regions have different ids, because they use
      // separate UUID namespaces.
      if allocation.id == id: return allocation
    return null

// --------------------------------------------------------------------------

flash-get-all-pages_ offset/int -> ByteArray:
  #primitive.flash.get-all-pages

flash-write-non-header-pages_ offset/int content/ByteArray -> none:
  #primitive.flash.write-non-header-pages
