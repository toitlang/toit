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
import uuid

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

  on_closed -> none:
    // Do nothing.

  compute_id_ key/string -> string:
    return ids_.get key --init=:
      id := uuid.uuid5 root key
      encoded := base64.encode id.to_byte_array
      // Keys used in nvs must be 15 bytes or less, so we
      // pick the first 12 encoded bytes which correspond
      // to the first 9 bytes of the 16 uuid bytes.
      encoded[..12]

class FlashBucketResource extends BucketResource:
  static group ::= flash_kv_init_ "nvs" "toit" false
  root/string
  constructor provider/StorageServiceProvider client/int .root:
    super provider client

  get key/string -> ByteArray?:
    return flash_kv_read_bytes_ group (compute_id_ key)

  set key/string value/ByteArray -> none:
    flash_kv_write_bytes_ group (compute_id_ key) value

  remove key/string -> none:
    flash_kv_delete_ group (compute_id_ key)

class RamBucketResource extends BucketResource:
  static memory ::= RtcMemory
  root/string

  constructor provider/StorageServiceProvider client/int .root:
    super provider client

  get key/string -> ByteArray?:
    return memory.cache.get (compute_id_ key)

  set key/string value/ByteArray -> none:
    memory.update: it[compute_id_ key] = value

  remove key/string -> none:
    memory.update: it.remove (compute_id_ key)

class RtcMemory:
  // We use a naive encoding strategy, where we re-encode the
  // entire mapping on all updates. It would be possible to
  // do this in a more incremental way, where we update the
  // cache and shuffle the sections of the memory area around.
  bytes_/ByteArray ::= rtc_memory_
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

flash_kv_init_ partition/string volume/string read_only/bool:
  #primitive.flash_kv.init

flash_kv_read_bytes_ group key/string:
  #primitive.flash_kv.read_bytes

flash_kv_write_bytes_ group key/string value/ByteArray:
  #primitive.flash_kv.write_bytes

flash_kv_delete_ group key/string:
  #primitive.flash_kv.delete

rtc_memory_ -> ByteArray:
  #primitive.core.rtc_user_bytes
