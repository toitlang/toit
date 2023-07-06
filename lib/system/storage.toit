// Copyright (C) 2023 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
User-space side of the service API for key-value storage.

# Examples
Store and read a value in a RAM-backed bucket. The used memory
  survives deep sleep, but not a restart of the device due to
  a reset or power loss.

```
import system.storage

main:
  bucket := storage.Bucket.open --ram "my-bucket"
  bucket["key"] = "value"
  print bucket["key"]
```

Use a 128 byte region in flash to store binary data.
```
import system.storage

main:
  region := storage.Region.open --flash "my-region" --capacity=128
  region.write --from=0 #[0x12, 0x34]
```
*/

import encoding.tison
import reader show Reader

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
  static SCHEME_FLASH ::= "flash"
  static SCHEME_RAM   ::= "ram"

  scheme/string
  path/string

  constructor.internal_ client/StorageServiceClient handle/int
      --.scheme --.path:
    super client handle

  uri -> string:
    return "$scheme:$path"

  /**
  Variant of $(open --scheme --path).

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
  Variant of $(open --scheme --path).

  Opens a storage bucket using the $SCHEME_RAM scheme and the
    given $path.
  */
  static open --ram/bool path/string -> Bucket:
    if not ram: throw "Bad Argument"
    return open --scheme=SCHEME_RAM --path=path

  /**
  Variant of $(open --scheme --path).

  Opens a storage bucket using the $SCHEME_FLASH scheme and the
    given $path.
  */
  static open --flash/bool path/string -> Bucket:
    if not flash: throw "Bad Argument"
    return open --scheme=SCHEME_FLASH --path=path

  /**
  Opens a storage bucket using the given $scheme and $path.
  */
  static open --scheme/string --path/string -> Bucket:
    client := _client_
    if not client: throw "UNSUPPORTED"
    if path.contains ":": throw "Paths cannot contain ':'"
    handle := client.bucket_open --scheme=scheme --path=path
    return Bucket.internal_ client handle --scheme=scheme --path=path

  get key/string -> any:
    return get key --if_present=(: it) --if_absent=(: null)

  get key/string [--if_absent] -> any:
    return get key --if_absent=if_absent --if_present=: it

  get key/string [--if_present] -> any:
    return get key --if_present=if_present --if_absent=: null

  get key/string [--if_present] [--if_absent] -> any:
    bytes := (client_ as StorageServiceClient).bucket_get handle_ key
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

  operator []= key/string value/any -> any:
    (client_ as StorageServiceClient).bucket_set handle_ key (tison.encode value)
    return value

  remove key/string -> none:
    (client_ as StorageServiceClient).bucket_remove handle_ key

/**
A storage region is a sequence of stored bytes that reside outside
  the current process and that can be persisted across application
  and device restarts.

Regions are referred to via a schema and a path. The scheme
  indicates the volatility and storage medium of the region
  and the path allows separating regions.
*/
class Region extends ServiceResourceProxy:
  static SCHEME_FLASH     ::= "flash"
  static SCHEME_PARTITION ::= "partition"

  scheme/string
  path/string

  /**
  The size of the region in bytes.
  */
  size/int

  /**
  Some regions have storage mediums that only allow setting
    bits or clearing bits as part of writes. See the two
    methods $write_can_set_bits and $write_can_clear_bits.
  */
  static MODE_WRITE_CAN_SET_BITS_   ::= 1 << 0
  static MODE_WRITE_CAN_CLEAR_BITS_ ::= 1 << 1

  // The region holds onto a resource that acts as a capability
  // that allows the region to manipulate the storage.
  resource_ := null

  // The region has a set of mode bits that indicates if stored
  // bits can be flipped in either direction due to writes.
  mode_/int

  // Instead of storing the erase granularity directly, we
  // store the mask to speed up erase operations slightly.
  erase_granularity_mask_/int

  constructor.internal_ client/StorageServiceClient reply/List --.scheme --.path:
    // Once we've gotten a reply from the storage service,
    // we should make sure to construct a proxy and close
    // it on any errors.
    handle := reply[0]
    offset := reply[1]
    size = reply[2]
    erase_granularity := 1 << reply[3]
    erase_granularity_mask_ = erase_granularity - 1
    mode_ = reply[4]
    super client handle
    try:
      resource_ = flash_region_open_
          resource_freeing_module_
          client.id
          handle
          offset
          size
    finally:
      if not resource_: close

  uri -> string:
    return "$scheme:$path"

  /**
  The $erase_value is the value of individual erased bytes
    after a call to $erase.
  */
  erase_value -> int:
    return write_can_set_bits ? 0x00 : 0xff

  /**
  The $erase_granularity is the required alignment of the
    from and to offsets for calls to $erase. As such, it
    is also the smallest number of bytes that can be erased
    by calls to $erase.
  */
  erase_granularity -> int:
    return erase_granularity_mask_ + 1

  /**
  Whether a call to $write can change individual bits
    from 0 to 1.
  */
  write_can_set_bits -> bool:
    return (mode_ & MODE_WRITE_CAN_SET_BITS_) != 0

  /**
  Whether a call to $write can change individual bits
    from 1 to 0.
  */
  write_can_clear_bits -> bool:
    return (mode_ & MODE_WRITE_CAN_CLEAR_BITS_) != 0

  /**
  Variant of $(open --scheme --path --capacity --writable).

  Opens a storage region with using the schema and path parsed
    from the given $uri.

  The format of the $uri is <scheme>:<path> and it is common to
    use qualified paths that include the domain name of the
    region owner, e.g. "flash:toitlang.org/jag".
  */
  static open uri/string -> Region
      --capacity/int?=null
      --writable/bool=true:
    split := uri.index_of ":" --if_absent=: throw "No scheme provided"
    return open
        --scheme=uri[..split]
        --path=uri[split + 1 ..]
        --capacity=capacity
        --writable=writable

  /**
  Variant of $(open --scheme --path --capacity --writable).

  Opens a storage region using the $SCHEME_FLASH scheme and the
    given $path.
  */
  static open --flash/bool path/string -> Region
      --capacity/int?=null
      --writable/bool=true:
    if not flash: throw "Bad Argument"
    return open
        --scheme=SCHEME_FLASH
        --path=path
        --capacity=capacity
        --writable=writable

  /**
  Variant of $(open --scheme --path --capacity --writable).

  Opens a storage region using the $SCHEME_PARTITION scheme and the
    given $path.
  */
  static open --partition/bool path/string -> Region
      --capacity/int?=null
      --writable/bool=true:
    if not partition: throw "Bad Argument"
    return open
        --scheme=SCHEME_PARTITION
        --path=path
        --capacity=capacity
        --writable=writable

  /**
  Opens a storage region using the given $scheme and $path.

  If an existing region matches the $scheme and $path, it
    is opened. An exception is thrown if a $capacity is
    provided and the existing region is smaller than that.

  If no region that match $scheme and $path exists, a new
    one is created. In this case, a non-null $capacity must
    be provided.

  If $writable is true (default), the region is opened for both
    reading and writing. If $writable is false (use --no-writable),
    the region is opened just for reading. Opening a partition
    for writing may require different permissions than opening
    it just for reading.
  */
  static open --scheme/string --path/string -> Region
      --capacity/int?=null
      --writable/bool=true:
    client := _client_
    if not client: throw "UNSUPPORTED"
    if capacity and capacity < 1: throw "Bad Argument"
    if path.contains ":": throw "Paths cannot contain ':'"
    reply := client.region_open
        --scheme=scheme
        --path=path
        --capacity=capacity
        --writable=writable
    return Region.internal_ client reply
        --scheme=scheme
        --path=path

  static delete uri/string -> none:
    split := uri.index_of ":" --if_absent=: throw "No scheme provided"
    delete --scheme=uri[..split] --path=uri[split + 1 ..]

  static delete --flash/bool path/string -> none:
    if not flash: throw "Bad Argument"
    delete --scheme=SCHEME_FLASH --path=path

  static delete --scheme/string --path/string -> none:
    client := _client_
    if not client: throw "UNSUPPORTED"
    client.region_delete --scheme=scheme --path=path

  /**
  Variant of $(list --scheme).

  Returns the $uri for all existing regions with the $SCHEME_FLASH
    scheme as a list of strings.
  */
  static list --flash/bool -> List:
    if not flash: throw "Bad Argument"
    return list --scheme=SCHEME_FLASH

  /**
  Returns the $uri for all existing regions with the given
    $scheme as a list of strings.
  */
  static list --scheme/string -> List:
    client := _client_
    if not client: throw "UNSUPPORTED"
    return client.region_list --scheme=scheme

  read --from/int bytes/ByteArray -> none:
    if not resource_: throw "ALREADY_CLOSED"
    flash_region_read_ resource_ from bytes

  read --from/int --to/int -> ByteArray:
    bytes := ByteArray (to - from)
    read --from=from bytes
    return bytes

  stream --from/int=0 --to/int=size --max_size/int=256 -> Reader:
    if not 0 <= from <= to <= size: throw "OUT_OF_BOUNDS"
    if max_size < 16: throw "Bad Argument"
    return RegionReader_
        --region=this
        --from=from
        --to=to
        --max_size=max_size

  write --from/int bytes/ByteArray -> none:
    if not resource_: throw "ALREADY_CLOSED"
    flash_region_write_ resource_ from bytes

  is_erased --from/int=0 --to/int=size -> bool:
    if not resource_: throw "ALREADY_CLOSED"
    return flash_region_is_erased_ resource_ from (to - from)

  /**
  Erases the bytes in the range starting at $from and ending
    at $to (exclusive) by setting them to $erase_value.

  Both $from and $to must be aligned to $erase_granularity.
  */
  erase --from/int=0 --to/int=size -> none:
    if not resource_: throw "ALREADY_CLOSED"
    if from & erase_granularity_mask_ != 0: throw "Bad Argument"
    if to & erase_granularity_mask_ != 0: throw "Bad Argument"
    flash_region_erase_ resource_ from (to - from)

  close -> none:
    if resource_:
      flash_region_close_ resource_
      resource_ = null
    super

class RegionReader_ implements Reader:
  region_/Region
  from_/int := ?
  to_/int
  max_size_/int

  constructor --region/Region --from/int --to/int --max_size/int:
    region_ = region
    from_ = from
    to_ = to
    max_size_ = max_size

  read -> ByteArray?:
    from := from_
    remaining := to_ - from
    if remaining == 0: return null
    n := min
        // Prefer 16 byte alignment for next read,
        (round_down (from + max_size_) 16) - from
        // unless we're reading the final chunk.
        remaining
    result := ByteArray n
    region_.read --from=from result
    from_ = from + n
    return result

// --------------------------------------------------------------------------

flash_region_open_ group client handle offset size:
  #primitive.flash.region_open

flash_region_close_ resource:
  #primitive.flash.region_close

flash_region_read_ resource from bytes:
  #primitive.flash.region_read

flash_region_write_ resource from bytes:
  #primitive.flash.region_write

flash_region_is_erased_ resource from size:
  #primitive.flash.region_is_erased

flash_region_erase_ resource from size:
  #primitive.flash.region_erase
