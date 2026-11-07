// Copyright (C) 2026 Toit contributors.
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
import io show LITTLE-ENDIAN
import uuid show *

import ...flash.allocation show
    FlashAllocation
    FLASH-ALLOCATION-HEADER-SIZE
    FLASH-ALLOCATION-TYPE-REGION

import ...flash.registry show FlashRegistry FLASH-REGISTRY-PAGE-SIZE
import ...storage show StorageServiceProvider
import ...storage.bucket show BucketResource

class FlashRegistryBucketResource extends BucketResource:
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
  static GENERATION-FORMAT_ ::= 1

  id/Uuid
  registry/FlashRegistry

  cache-allocation_/FlashAllocation? := null
  cache-entries_/Map? := null
  users_/int := 0

  static instances_ := {:}  // Map<string, FlashBucket>

  constructor.internal_ --.id --.registry:
    candidates := []
    registry.do: | candidate/FlashAllocation |
      if candidate.type == FLASH-ALLOCATION-TYPE-REGION and candidate.id == id:
        candidates.add candidate
    allocation/FlashAllocation? := null
    generation/int? := null
    candidates.do: | candidate/FlashAllocation |
      candidate-generation := generation_ candidate
      if not allocation:
        allocation = candidate
        generation = candidate-generation
      else if candidate-generation == generation:
        // Legacy duplicates cannot be ordered: do not silently discard data.
        throw "Ambiguous bucket generations"
      else if candidate-generation:
        if generation:
          difference := (candidate-generation - generation) & 0xffff_ffff
          if difference == 0x8000_0000: throw "Ambiguous bucket generations"
          if difference > 0x8000_0000: continue.do
        allocation = candidate
        generation = candidate-generation
    if allocation:
      cache-allocation_ = allocation
      pages := flash-get-all-pages_ allocation.offset
      entries := assets.decode pages[FLASH-ALLOCATION-HEADER-SIZE..]
      // The found entry values point into flash. Copy them to RAM before the
      // currently cached allocation can be freed.
      cache-entries_ = entries.map: | key value | value.copy
      // A reset after publishing the new header can leave its predecessor
      // behind. Keep the winner intact while reclaiming every stale copy.
      candidates.do: | candidate/FlashAllocation |
        if candidate != allocation: registry.free candidate

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
      // Avoid neutering the cached entry when it is sent to a client.
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
    else:
      // A rejected write must not change what existing bucket handles read.
      // Entry values are immutable here; only the map needs a private copy.
      entries = entries.copy
    block.call entries
    existing := cache-allocation_
    if entries.is-empty:
      cache-allocation_ = null
    else:
      encoded := assets.encode entries
      size := FLASH-ALLOCATION-HEADER-SIZE + encoded.size
      reservation := registry.reserve size
      if not reservation: throw "OUT_OF_SPACE"
      try:
        metadata := ByteArray 5
        metadata[0] = GENERATION-FORMAT_
        generation := existing and (generation_ existing)
        LITTLE-ENDIAN.put-uint32 metadata 1 (((generation or 0) + 1) & 0xffff_ffff)
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
      finally:
        reservation.close
    cache-entries_ = entries.is-empty ? null : entries
    if existing: registry.free existing

  static generation_ allocation/FlashAllocation -> int?:
    metadata := allocation.metadata
    if metadata == #[0xff, 0xff, 0xff, 0xff, 0xff]: return null
    if metadata[0] != GENERATION-FORMAT_: throw "Unsupported bucket metadata"
    return LITTLE-ENDIAN.uint32 metadata 1

// --------------------------------------------------------------------------

flash-get-all-pages_ offset/int -> ByteArray:
  #primitive.flash.get-all-pages

flash-write-non-header-pages_ offset/int content/ByteArray -> none:
  #primitive.flash.write-non-header-pages
