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
import .bucket show BucketResource RamBucketResource
import .region show FlashRegionResource PartitionRegionResource

abstract class StorageServiceProvider extends ServiceProvider
    implements StorageService ServiceHandler:
  registry/FlashRegistry

  constructor name/string .registry:
    super name --major=0 --minor=2
    provides StorageService.SELECTOR --handler=this

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == StorageService.BUCKET-GET-INDEX:
      bucket := (resource client arguments[0]) as BucketResource
      return bucket.get arguments[1]
    else if index == StorageService.BUCKET-SET-INDEX:
      bucket := (resource client arguments[0]) as BucketResource
      return bucket.set arguments[1] arguments[2]
    else if index == StorageService.BUCKET-REMOVE-INDEX:
      bucket := (resource client arguments[0]) as BucketResource
      return bucket.remove arguments[1]
    else if index == StorageService.BUCKET-OPEN-INDEX:
      return bucket-open client --scheme=arguments[0] --path=arguments[1]
    else if index == StorageService.REGION-OPEN-INDEX:
      return region-open client
          --scheme=arguments[0]
          --path=arguments[1]
          --capacity=arguments[2]
          --writable=arguments[3]
    else if index == StorageService.REGION-DELETE-INDEX:
      return region-delete --scheme=arguments[0] --path=arguments[1]
    else if index == StorageService.REGION-LIST-INDEX:
      return region-list --scheme=arguments
    unreachable

  abstract bucket-open client/int --scheme/string --path/string -> BucketResource

  region-open client/int --scheme/string --path/string --capacity/int? --writable/bool -> List:
    if scheme == Region.SCHEME-FLASH:
      return FlashRegionResource.open this client
          --path=path
          --capacity=capacity
          --writable=writable
    else if scheme == Region.SCHEME-PARTITION:
      return PartitionRegionResource.open this client
          --path=path
          --capacity=capacity
          --writable=writable
    throw "Unsupported '$scheme:' scheme"

  region-delete --scheme/string --path/string -> none:
    if scheme != Region.SCHEME-FLASH: throw "Unsupported '$scheme:' scheme"
    FlashRegionResource.delete registry --path=path

  region-list --scheme/string -> List:
    if scheme != Region.SCHEME-FLASH: throw "Unsupported '$scheme:' scheme"
    return FlashRegionResource.list registry

  bucket-open --scheme/string --path/string -> int:
    unreachable  // TODO(kasper): Nasty.

  bucket-get bucket/int key/string -> ByteArray?:
    unreachable  // TODO(kasper): Nasty.

  bucket-set bucket/int key/string value/ByteArray -> none:
    unreachable  // TODO(kasper): Nasty.

  bucket-remove bucket/int key/string -> none:
    unreachable  // TODO(kasper): Nasty.

  region-open --scheme/string --path/string --capacity/int? --writable/bool -> int:
    unreachable  // TODO(kasper): Nasty.
