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

import encoding.base64
import system.assets
import system.services show ServiceResource
import uuid show *

abstract class BucketResource extends ServiceResource:
  // We keep a cache of computed ids around. The ids encode
  // the root name of the bucket, so it is natural to keep
  // these per bucket. This also simplifies cleaning them
  // up as the cache simply goes away when the bucket
  // resource is closed.
  ids_ ::= {:}

  constructor provider/StorageServiceProvider client/int:
    super provider client

  abstract root -> string
  abstract get key/string -> ByteArray?
  abstract set key/string value/ByteArray -> none
  abstract remove key/string -> none

  on-closed -> none:
    // Do nothing.

  compute-id_ key/string -> string:
    return ids_.get key --init=:
      id := Uuid.uuid5 root key
      encoded := base64.encode id.to-byte-array
      // Keys used in nvs must be 15 bytes or less, so we
      // pick the first 12 encoded bytes which correspond
      // to the first 9 bytes of the 16 uuid bytes.
      encoded[..12]

class RamBucketResource extends BucketResource:
  static memory ::= RtcMemory
  root/string

  constructor provider/StorageServiceProvider client/int .root:
    super provider client

  get key/string -> ByteArray?:
    return memory.cache.get (compute-id_ key)

  set key/string value/ByteArray -> none:
    memory.update: it[compute-id_ key] = value

  remove key/string -> none:
    memory.update: it.remove (compute-id_ key)

class RtcMemory:
  // We use a naive encoding strategy, where we re-encode the
  // entire mapping on all updates. It would be possible to
  // do this in a more incremental way, where we update the
  // cache and shuffle the sections of the memory area around.
  bytes_/ByteArray ::= rtc-memory_
  cache_/Map? := null

  cache -> Map:
    map := cache_
    if map: return map
    catch: map = assets.decode bytes_
    map = map or {:}
    cache_ = map
    return map

  update [block] -> none:
    map := cache
    cache_ = null
    block.call map
    encoded := assets.encode map
    if encoded.size > bytes_.size: throw "OUT_OF_SPACE"
    bytes_.replace 0 encoded

// --------------------------------------------------------------------------

rtc-memory_ -> ByteArray:
  #primitive.core.rtc-user-bytes
