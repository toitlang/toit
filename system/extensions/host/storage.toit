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

import ..shared.storage_base

class StorageServiceProvider extends StorageServiceProviderBase:
  constructor:
    super "system/storage/host" --major=0 --minor=1

  open_bucket client/int --scheme/string --path/string -> BucketResource:
    // On host platforms, we always use non-volatile buckets
    // because they are actually backed by somewhat volatile
    // memory that is lost when the host process terminates.
    // The memory is preserved across simulated deep sleep.
    return FlashBucketResource this client "$scheme:$path"
