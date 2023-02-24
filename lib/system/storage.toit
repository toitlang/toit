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

/**
...
*/
class Region extends ServiceResourceProxy:
  // TODO(kasper): Change this. It is not accurate.
  static SCHEME_FLASH ::= "flash"

  // The region holds onto a resource that acts as a capability
  // that allows the region to manipulate the storage.
  resource_ := ?

  /**
  ...
  */
  size/int

  /**
  ...
  */
  sector_size/int

  /**
  ...
  */
  erase_byte/int

  constructor.internal_ client/StorageServiceClient handle/int
      --resource
      --.size
      --.sector_size
      --.erase_byte:
    resource_ = resource
    super client handle

  /**
  Opens a storage region with using the schema and path parsed
    from the given $uri.

  The format of the $uri is <scheme>:<path> and it is common to
    use qualified paths that include the domain name of the
    region owner, e.g. "flash:toitlang.org/jag".
  */
  static open uri/string --size/int -> Region:
    split := uri.index_of ":" --if_absent=: throw "No scheme provided"
    return open --scheme=uri[..split] --path=uri[split + 1 ..] --size=size

  /**
  Opens a storage region using the $SCHEME_FLASH scheme and the
    given $path.
  */
  static open --flash/bool path/string --size/int -> Region:
    if flash != true: throw "Bad Argument"
    return open --scheme=SCHEME_FLASH --path=path --size=size

  /**
  Opens a storage region using the given $scheme and $path.
  */
  static open --scheme/string --path/string --size/int -> Region:
    client := _client_
    if not client: throw "UNSUPPORTED"
    path.index_of ":" --if_absent=:
      region := client.open_region --scheme=scheme --path=path --size=size
      handle := region[0]
      size = region[2]
      resource := flash_region_open_
          resource_freeing_module_
          client.id
          handle
          region[1]
          size
      return Region.internal_ client handle
          --resource=resource
          --size=size
          --sector_size=region[3]
          --erase_byte=region[4]
    throw "Paths cannot contain ':'"

  /**
  ...
  */
  read --from/int bytes/ByteArray -> none:
    flash_region_read_ resource_ from bytes

  /**
  ...
  */
  read --from/int --to/int -> ByteArray:
    bytes := ByteArray (to - from)
    read --from=from bytes
    return bytes

  /**
  ...
  */
  write --from/int bytes/ByteArray -> none:
    flash_region_write_ resource_ from bytes

  /**
  ...
  */
  erase --from/int=0 --to/int=size -> none:
    if (round_down from sector_size) != from: throw "xxx"
    if (round_down to sector_size) != to: throw "xxx"
    flash_region_erase_ resource_ from (to - from)

  /**
  ...
  */
  close -> none:
    if resource_:
      flash_region_close_ resource_
      resource_ = null
    super

// --------------------------------------------------------------------------

flash_region_open_ group client handle offset size:
  #primitive.flash.region_open

flash_region_close_ resource:
  #primitive.flash.region_close

flash_region_read_ resource from bytes:
  #primitive.flash.region_read

flash_region_write_ resource from bytes:
  #primitive.flash.region_write

flash_region_erase_ resource from size:
  #primitive.flash.region_erase
