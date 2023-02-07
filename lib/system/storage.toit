// Copyright (C) 2023 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
User-space side of the RPC API for key-value storage...
*/

import encoding.tison

import system.api.storage show StorageService StorageServiceClient
import system.services show ServiceResourceProxy

_client_/StorageServiceClient? ::= (StorageServiceClient).open
    --if_absent=: null

class Bucket extends ServiceResourceProxy:
  constructor.internal_ client/StorageServiceClient handle/int:
    super client handle

  static open name/string -> Bucket:
    client := _client_
    if not client: throw "UNSUPPORTED"
    return Bucket.internal_ client (client.open_bucket name)

  get key/string:
    return get key --if_present=(: it) --if_absent=(: null)

  get key/string [--if_absent]:
    return get key --if_absent=if_absent --if_present=: it

  get key/string [--if_present]:
    return get key --if_present=if_present --if_absent=: null

  get key/string [--if_present] [--if_absent]:
    bytes := (client_ as StorageServiceClient).get handle_ key
    if not bytes: return if_absent.call key
    return if_present.call (tison.decode bytes)

  get key/string [--init]:
    return get key
      --if_absent=:
        initial_value := init.call
        this[key] = initial_value
        return initial_value
      --if_present=: it

  operator [] key/string -> any:
    return get key --if_present=(: it) --if_absent=(: throw "key not found")

  operator []= key/string value/any -> none:
    (client_ as StorageServiceClient).set handle_ key (tison.encode value)

  remove key/string -> none:
    (client_ as StorageServiceClient).remove handle_ key
