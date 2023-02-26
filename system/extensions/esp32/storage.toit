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
import binary show LITTLE_ENDIAN

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
  // We store the size of the encoded message in the header of the
  // RTC memory. This gives us a way to pass the correctly sized
  // bytes slice to tison.decode and that is essential because
  // the decoder rejects encodings with junk at the end.
  static HEADER_ENCODED_SIZE_OFFSET ::= 0
  static HEADER_SIZE ::= 2 + HEADER_ENCODED_SIZE_OFFSET

  bytes/ByteArray ::= rtc_memory_
  cache/Map := {:}

  constructor:
    // Fill the cache, but be nice and avoid decoding the content
    // of the RTC memory if it was just cleared.
    size := LITTLE_ENDIAN.uint16 bytes HEADER_ENCODED_SIZE_OFFSET
    if size > 0:
      catch:
        cache = tison.decode bytes[HEADER_SIZE .. size + HEADER_SIZE]

  flush -> none:
    // TODO(kasper): We could consider encoding directly
    // into the RTC memory instead of copying it in.
    encoded := tison.encode cache
    bytes.replace HEADER_SIZE encoded
    LITTLE_ENDIAN.put_uint16 bytes HEADER_ENCODED_SIZE_OFFSET encoded.size

// --------------------------------------------------------------------------

rtc_memory_ -> ByteArray:
  #primitive.esp32.rtc_user_bytes
