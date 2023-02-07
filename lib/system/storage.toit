// Copyright (C) 2023 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
User-space side of the service API for key-value storage.
*/

import encoding.tison

import system.api.storage show StorageService StorageServiceClient
import system.services show ServiceResourceProxy

_client_/StorageServiceClient? ::= (StorageServiceClient).open
    --if_absent=: null

/**
A storage bucket is a key-value mapping that resides outside the
  current process and that can be persisted across application
  and device restarts.

Buckets are referred to via a schema and a path. The scheme
  indicates the volatility and storage medium of the bucket
  and the path allows separating buckets.
*/
class Bucket extends ServiceResourceProxy:
  static SCHEME_RAM   ::= "ram"
  static SCHEME_FLASH ::= "flash"

  constructor.internal_ client/StorageServiceClient handle/int:
    super client handle

  /**
  Opens a storage bucket with using the schema and path parsed
    from the given $uri.

  The format of the $uri is <scheme>:<path> and it is common to
    use qualified paths that include the domain name of the
    bucket owner, e.g. "flash:toitlang.org/jag".
  */
  static open uri/string -> Bucket:
    split := uri.index_of ":" --if_absent=: throw "No scheme provided"
    return open --scheme=uri[..split] --path=uri[split + 1 ..]

  /**
  Opens a storage bucket using the $SCHEME_RAM scheme and the
    given $path.
  */
  static open --ram/bool path/string -> Bucket:
    if ram != true: throw "Bad Argument"
    return open --scheme=SCHEME_RAM --path=path

  /**
  Opens a storage bucket using the $SCHEME_FLASH scheme and the
    given $path.
  */
  static open --flash/bool path/string -> Bucket:
    if flash != true: throw "Bad Argument"
    return open --scheme=SCHEME_FLASH --path=path

  /**
  Opens a storage bucket using the given $scheme and $path.
  */
  static open --scheme/string --path/string -> Bucket:
    client := _client_
    if not client: throw "UNSUPPORTED"
    path.index_of ":" --if_absent=:
      handle := client.open_bucket --scheme=scheme --path=path
      return Bucket.internal_ client handle
    throw "Paths cannot contain ':'"

  get key/string -> any:
    return get key --if_present=(: it) --if_absent=(: null)

  get key/string [--if_absent] -> any:
    return get key --if_absent=if_absent --if_present=: it

  get key/string [--if_present] -> any:
    return get key --if_present=if_present --if_absent=: null

  get key/string [--if_present] [--if_absent] -> any:
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
