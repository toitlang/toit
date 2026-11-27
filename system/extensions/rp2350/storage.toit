// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
import system.storage show Bucket

import ...flash.registry show FlashRegistry
import ...storage show StorageServiceProvider
import ...storage.bucket show BucketResource RamBucketResource
import ..shared.storage-flash-registry show FlashRegistryBucketResource

class StorageServiceProviderRp2350 extends StorageServiceProvider:
  constructor registry/FlashRegistry:
    super "system/storage/rp2350" registry

  bucket-open client/int --scheme/string --path/string -> BucketResource:
    if scheme == Bucket.SCHEME-RAM:
      return RamBucketResource this client path
    if scheme == Bucket.SCHEME-FLASH:
      return FlashRegistryBucketResource this client path
    throw "Unsupported '$scheme:' scheme"
