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

import encoding.tison
import system.storage show Bucket

import ..shared.storage_base
import ...flash.registry

class StorageServiceProvider extends StorageServiceProviderBase:
  constructor registry/FlashRegistry:
    super "system/storage/esp32" registry --major=0 --minor=1

  open_bucket client/int --scheme/string --path/string -> BucketResource:
    if scheme == Bucket.SCHEME_RAM:
      return RamBucketResource this client path
    assert: scheme == Bucket.SCHEME_FLASH
    return FlashBucketResource this client path

class RamBucketResource extends BucketResource:
  static memory ::= RtcMemory
  name/string

  constructor provider/StorageServiceProviderBase client/int .name:
    super provider client

  get key/string -> ByteArray?:
    return memory.cache.get name
        --if_absent=: null
        --if_present=: it.get key

  set key/string value/ByteArray -> none:
    map := memory.cache.get name --init=: {:}
    map[key] = value
    memory.flush

  remove key/string -> none:
    cache := memory.cache
    map := cache.get name
    if not map: return
    map.remove key --if_absent=: return
    if map.is_empty: cache.remove name
    memory.flush

class RtcMemory:
  bytes/ByteArray ::= rtc_memory_
  cache/Map := {:}

  constructor:
    // Fill the cache, but be nice and avoid decoding the content
    // of the RTC memory if it was just cleared.
    catch: if bytes[0] != 0: cache = tison.decode bytes

  flush -> none:
    // TODO(kasper): We could consider encoding directly
    // into the RTC memory instead of copying it in.
    bytes.replace 0 (tison.encode cache)

// --------------------------------------------------------------------------

rtc_memory_ -> ByteArray:
  #primitive.esp32.rtc_user_bytes
