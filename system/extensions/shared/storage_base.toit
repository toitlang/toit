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

import uuid

import system.storage show Bucket
import system.services show ServiceHandler ServiceProvider ServiceResource
import system.api.storage show StorageService

abstract class StorageServiceProviderBase extends ServiceProvider
    implements StorageService ServiceHandler:
  constructor name/string --major/int --minor/int:
    super name --major=major --minor=minor
    provides StorageService.SELECTOR --handler=this

  handle pid/int client/int index/int arguments/any -> any:
    if index == StorageService.GET_INDEX:
      bucket := (resource client arguments[0]) as BucketResource
      return bucket.get arguments[1]
    else if index == StorageService.SET_INDEX:
      bucket := (resource client arguments[0]) as BucketResource
      return bucket.set arguments[1] arguments[2]
    else if index == StorageService.REMOVE_INDEX:
      bucket := (resource client arguments[0]) as BucketResource
      return bucket.remove arguments[1]
    else if index == StorageService.OPEN_BUCKET_INDEX:
      scheme := arguments[0]
      if scheme != Bucket.SCHEME_RAM and scheme != Bucket.SCHEME_FLASH:
        throw "Unsupported '$scheme:' scheme"
      return open_bucket client --scheme=scheme --path=arguments[1]
    unreachable

  abstract open_bucket client/int --scheme/string --path/string -> BucketResource

  open_bucket --scheme/string --path/string -> int:
    unreachable  // TODO(kasper): Nasty.

  get bucket/int key/string -> ByteArray?:
    unreachable  // TODO(kasper): Nasty.

  set bucket/int key/string value/ByteArray -> none:
    unreachable  // TODO(kasper): Nasty.

  remove bucket/int key/string -> none:
    unreachable  // TODO(kasper): Nasty.

abstract class BucketResource extends ServiceResource:
  constructor provider/StorageServiceProviderBase client/int:
    super provider client

  abstract get key/string -> ByteArray?
  abstract set key/string value/ByteArray -> none
  abstract remove key/string -> none

  on_closed -> none:
    // Do nothing.

class FlashBucketResource extends BucketResource:
  static group ::= flash_kv_init_ "nvs" "toit" false
  root/string
  paths ::= {:}

  constructor provider/StorageServiceProviderBase client/int .root:
    super provider client

  get key/string -> ByteArray?:
    return flash_kv_read_bytes_ group (compute_path_ key)

  set key/string value/ByteArray -> none:
    flash_kv_write_bytes_ group (compute_path_ key) value

  remove key/string -> none:
    flash_kv_delete_ group (compute_path_ key)

  compute_path_ key/string -> string:
    return paths.get key --init=: (uuid.uuid5 root key).stringify[..13]

// --------------------------------------------------------------------------

flash_kv_init_ partition/string volume/string read_only/bool:
  #primitive.flash_kv.init

flash_kv_read_bytes_ group key/string:
  #primitive.flash_kv.read_bytes

flash_kv_write_bytes_ group key/string value/ByteArray:
  #primitive.flash_kv.write_bytes

flash_kv_delete_ group key/string:
  #primitive.flash_kv.delete
