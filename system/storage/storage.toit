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

import system.storage show Bucket Region
import system.services show ServiceHandler ServiceProvider
import system.api.storage show StorageService

import ..flash.registry show FlashRegistry
import .bucket show BucketResource FlashBucketResource RamBucketResource
import .region show FlashRegionResource PartitionRegionResource

class StorageServiceProvider extends ServiceProvider
    implements StorageService ServiceHandler:
  registry/FlashRegistry

  constructor .registry:
    super "system/storage" --major=0 --minor=2
    provides StorageService.SELECTOR --handler=this

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == StorageService.BUCKET_GET_INDEX:
      bucket := (resource client arguments[0]) as BucketResource
      return bucket.get arguments[1]
    else if index == StorageService.BUCKET_SET_INDEX:
      bucket := (resource client arguments[0]) as BucketResource
      return bucket.set arguments[1] arguments[2]
    else if index == StorageService.BUCKET_REMOVE_INDEX:
      bucket := (resource client arguments[0]) as BucketResource
      return bucket.remove arguments[1]
    else if index == StorageService.BUCKET_OPEN_INDEX:
      return bucket_open client --scheme=arguments[0] --path=arguments[1]
    else if index == StorageService.REGION_OPEN_INDEX:
      return region_open client
          --scheme=arguments[0]
          --path=arguments[1]
          --capacity=arguments[2]
    else if index == StorageService.REGION_DELETE_INDEX:
      return region_delete --scheme=arguments[0] --path=arguments[1]
    else if index == StorageService.REGION_LIST_INDEX:
      return region_list --scheme=arguments
    unreachable

  bucket_open client/int --scheme/string --path/string -> BucketResource:
    if scheme == Bucket.SCHEME_RAM:
      return RamBucketResource this client path
    else if scheme == Bucket.SCHEME_FLASH:
      return FlashBucketResource this client path
    throw "Unsupported '$scheme:' scheme"

  region_open client/int --scheme/string --path/string --capacity/int? -> List:
    if scheme == Region.SCHEME_FLASH:
      return FlashRegionResource.open this client --path=path --capacity=capacity
    else if scheme == Region.SCHEME_PARTITION:
      return PartitionRegionResource.open this client --path=path --capacity=capacity
    throw "Unsupported '$scheme:' scheme"

  region_delete --scheme/string --path/string -> none:
    if scheme != Region.SCHEME_FLASH: throw "Unsupported '$scheme:' scheme"
    FlashRegionResource.delete registry --path=path

  region_list --scheme/string -> List:
    if scheme != Region.SCHEME_FLASH: throw "Unsupported '$scheme:' scheme"
    return FlashRegionResource.list registry

  bucket_open --scheme/string --path/string -> int:
    unreachable  // TODO(kasper): Nasty.

  bucket_get bucket/int key/string -> ByteArray?:
    unreachable  // TODO(kasper): Nasty.

  bucket_set bucket/int key/string value/ByteArray -> none:
    unreachable  // TODO(kasper): Nasty.

  bucket_remove bucket/int key/string -> none:
    unreachable  // TODO(kasper): Nasty.

  region_open --scheme/string --path/string --capacity/int? -> int:
    unreachable  // TODO(kasper): Nasty.
