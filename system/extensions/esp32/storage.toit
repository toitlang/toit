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

import system.storage show Bucket

import ...flash.registry show FlashRegistry
import ...storage show StorageServiceProvider
import ...storage.bucket show BucketResource RamBucketResource

class StorageServiceProviderEsp32 extends StorageServiceProvider:
  constructor registry/FlashRegistry:
    super "system/storage/esp32" registry

  bucket-open client/int --scheme/string --path/string -> BucketResource:
    if scheme == Bucket.SCHEME-RAM:
      return RamBucketResource this client path
    else if scheme == Bucket.SCHEME-FLASH:
      return FlashBucketResourceEsp32 this client path
    throw "Unsupported '$scheme:' scheme"

class FlashBucketResourceEsp32 extends BucketResource:
  static group ::= flash-kv-init_ "nvs" "toit" false
  root/string
  constructor provider/StorageServiceProvider client/int .root:
    super provider client

  get key/string -> ByteArray?:
    return flash-kv-read-bytes_ group (compute-id_ key)

  set key/string value/ByteArray -> none:
    flash-kv-write-bytes_ group (compute-id_ key) value

  remove key/string -> none:
    flash-kv-delete_ group (compute-id_ key)

// --------------------------------------------------------------------------

flash-kv-init_ partition/string volume/string read-only/bool:
  #primitive.flash-kv.init

flash-kv-read-bytes_ group key/string:
  #primitive.flash-kv.read-bytes

flash-kv-write-bytes_ group key/string value/ByteArray:
  #primitive.flash-kv.write-bytes

flash-kv-delete_ group key/string:
  #primitive.flash-kv.delete
