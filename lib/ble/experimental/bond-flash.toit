// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import system.api.storage show StorageServiceClient
import system.services show ServiceResourceProxy
import .bond-storage show Records

/**
Raw flash-bucket adapter for protected candidate storage.

Uses the storage service's bytes API directly: the general Bucket wrapper
  treats invalid TISON as absence, which would hide record corruption. This
  namespace must be reserved for these raw records. ESP32 writes and deletes
  propagate NVS commit errors. Power-loss behavior needs backend-specific tests;
  successful RPC/read-back is not a general crash-consistency guarantee.
*/
class FlashRecords extends ServiceResourceProxy implements Records:
  path_/string

  constructor path/string:
    if path.size == 0 or path.to-byte-array.size > 58 or path.contains ":":
      throw "INVALID_ARGUMENT"
    path_ = path
    super storage-client_ (storage-client_.bucket-open --scheme="flash" --path=path)

  namespace -> ByteArray: return "flash:$path_".to-byte-array

  read name/string -> ByteArray?:
    return storage-client_.bucket-get handle_ name

  write name/string bytes/ByteArray -> none:
    storage-client_.bucket-set handle_ name bytes

  remove name/string -> none:
    storage-client_.bucket-remove handle_ name

storage-client_ ::= (StorageServiceClient).open as StorageServiceClient
