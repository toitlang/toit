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

import ..shared.storage-flash-registry show FlashRegistryBucketResource

class StorageServiceProviderHost extends StorageServiceProvider:
  constructor registry/FlashRegistry:
    super "system/storage/host" registry

  bucket-open client/int --scheme/string --path/string -> BucketResource:
    if scheme == Bucket.SCHEME-RAM:
      return RamBucketResource this client path
    else if scheme == Bucket.SCHEME-FLASH:
      return FlashRegistryBucketResource this client path
    throw "Unsupported '$scheme:' scheme"
