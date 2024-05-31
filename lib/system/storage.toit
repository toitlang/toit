// Copyright (C) 2023 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
User-space side of the service API for storage.

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
  region.write --at=0 #[0x12, 0x34]
```
*/

import encoding.tison
import io

import system.api.storage show StorageService StorageServiceClient
import system.services show ServiceResourceProxy

_client_/StorageServiceClient? ::= (StorageServiceClient).open
    --if-absent=: null

/**
A storage bucket is a key-value mapping that resides outside the
  current process and that can be persisted across application
  and device restarts.

Buckets are referred to via a schema and a path. The scheme
  indicates the volatility and storage medium of the bucket
  and the path allows separating buckets.
*/
class Bucket extends ServiceResourceProxy:
  static SCHEME-FLASH ::= "flash"
  static SCHEME-RAM   ::= "ram"

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
    split := uri.index-of ":" --if-absent=: throw "No scheme provided"
    return open --scheme=uri[..split] --path=uri[split + 1 ..]

  /**
  Variant of $(open --scheme --path).

  Opens a storage bucket using the $SCHEME-RAM scheme and the
    given $path.
  */
  static open --ram/bool path/string -> Bucket:
    if not ram: throw "Bad Argument"
    return open --scheme=SCHEME-RAM --path=path

  /**
  Variant of $(open --scheme --path).

  Opens a storage bucket using the $SCHEME-FLASH scheme and the
    given $path.
  */
  static open --flash/bool path/string -> Bucket:
    if not flash: throw "Bad Argument"
    return open --scheme=SCHEME-FLASH --path=path

  /**
  Opens a storage bucket using the given $scheme and $path.
  */
  static open --scheme/string --path/string -> Bucket:
    client := _client_
    if not client: throw "UNSUPPORTED"
    if path.contains ":": throw "Paths cannot contain ':'"
    handle := client.bucket-open --scheme=scheme --path=path
    return Bucket.internal_ client handle --scheme=scheme --path=path

  get key/string -> any:
    return get key --if-present=(: it) --if-absent=(: null)

  get key/string [--if-absent] -> any:
    return get key --if-absent=if-absent --if-present=: it

  get key/string [--if-present] -> any:
    return get key --if-present=if-present --if-absent=: null

  get key/string [--if-present] [--if-absent] -> any:
    bytes := (client_ as StorageServiceClient).bucket-get handle_ key
    if bytes:
      // Play it safe and handle the case where a bucket ended up
      // with illegal encoded bits by treating it as an absent entry.
      decoded := null
      exception := catch: decoded = tison.decode bytes
      if not exception: return if-present.call decoded
    return if-absent.call key

  get key/string [--init]:
    return get key
      --if-absent=:
        initial-value := init.call
        this[key] = initial-value
        return initial-value
      --if-present=: it

  operator [] key/string -> any:
    return get key --if-present=(: it) --if-absent=(: throw "key not found")

  operator []= key/string value/any -> any:
    (client_ as StorageServiceClient).bucket-set handle_ key (tison.encode value)
    return value

  remove key/string -> none:
    (client_ as StorageServiceClient).bucket-remove handle_ key

/**
A storage region is a sequence of stored bytes that reside outside
  the current process and that can be persisted across application
  and device restarts.

Regions are referred to via a schema and a path. The scheme
  indicates the volatility and storage medium of the region
  and the path allows separating regions.
*/
class Region extends ServiceResourceProxy:
  static SCHEME-FLASH     ::= "flash"
  static SCHEME-PARTITION ::= "partition"

  scheme/string
  path/string

  /**
  The size of the region in bytes.
  */
  size/int

  /**
  Some regions have storage mediums that only allow setting
    bits or clearing bits as part of writes. See the two
    methods $write-can-set-bits and $write-can-clear-bits.
  */
  static MODE-WRITE-CAN-SET-BITS_   ::= 1 << 0
  static MODE-WRITE-CAN-CLEAR-BITS_ ::= 1 << 1

  // The region holds onto a resource that acts as a capability
  // that allows the region to manipulate the storage.
  resource_ := null

  // The region has a set of mode bits that indicates if stored
  // bits can be flipped in either direction due to writes.
  mode_/int

  // Instead of storing the erase granularity directly, we
  // store the mask to speed up erase operations slightly.
  erase-granularity-mask_/int

  constructor.internal_ client/StorageServiceClient reply/List --.scheme --.path:
    // Once we've gotten a reply from the storage service,
    // we should make sure to construct a proxy and close
    // it on any errors.
    handle := reply[0]
    offset := reply[1]
    size = reply[2]
    erase-granularity := 1 << reply[3]
    erase-granularity-mask_ = erase-granularity - 1
    mode_ = reply[4]
    super client handle
    try:
      resource_ = flash-region-open_
          resource-freeing-module_
          client.id
          handle
          offset
          size
    finally:
      if not resource_: close

  uri -> string:
    return "$scheme:$path"

  /**
  The $erase-value is the value of individual erased bytes
    after a call to $erase.
  */
  erase-value -> int:
    return write-can-set-bits ? 0x00 : 0xff

  /**
  The $erase-granularity is the required alignment of the
    from and to offsets for calls to $erase. As such, it
    is also the smallest number of bytes that can be erased
    by calls to $erase.
  */
  erase-granularity -> int:
    return erase-granularity-mask_ + 1

  /**
  Whether a call to $write can change individual bits
    from 0 to 1.
  */
  write-can-set-bits -> bool:
    return (mode_ & MODE-WRITE-CAN-SET-BITS_) != 0

  /**
  Whether a call to $write can change individual bits
    from 1 to 0.
  */
  write-can-clear-bits -> bool:
    return (mode_ & MODE-WRITE-CAN-CLEAR-BITS_) != 0

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
    split := uri.index-of ":" --if-absent=: throw "No scheme provided"
    return open
        --scheme=uri[..split]
        --path=uri[split + 1 ..]
        --capacity=capacity
        --writable=writable

  /**
  Variant of $(open --scheme --path --capacity --writable).

  Opens a storage region using the $SCHEME-FLASH scheme and the
    given $path.
  */
  static open --flash/bool path/string -> Region
      --capacity/int?=null
      --writable/bool=true:
    if not flash: throw "Bad Argument"
    return open
        --scheme=SCHEME-FLASH
        --path=path
        --capacity=capacity
        --writable=writable

  /**
  Variant of $(open --scheme --path --capacity --writable).

  Opens a storage region using the $SCHEME-PARTITION scheme and the
    given $path.
  */
  static open --partition/bool path/string -> Region
      --capacity/int?=null
      --writable/bool=true:
    if not partition: throw "Bad Argument"
    return open
        --scheme=SCHEME-PARTITION
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
    reply := client.region-open
        --scheme=scheme
        --path=path
        --capacity=capacity
        --writable=writable
    return Region.internal_ client reply
        --scheme=scheme
        --path=path

  static delete uri/string -> none:
    split := uri.index-of ":" --if-absent=: throw "No scheme provided"
    delete --scheme=uri[..split] --path=uri[split + 1 ..]

  static delete --flash/bool path/string -> none:
    if not flash: throw "Bad Argument"
    delete --scheme=SCHEME-FLASH --path=path

  static delete --scheme/string --path/string -> none:
    client := _client_
    if not client: throw "UNSUPPORTED"
    client.region-delete --scheme=scheme --path=path

  /**
  Variant of $(list --scheme).

  Returns the $uri for all existing regions with the $SCHEME-FLASH
    scheme as a list of strings.
  */
  static list --flash/bool -> List:
    if not flash: throw "Bad Argument"
    return list --scheme=SCHEME-FLASH

  /**
  Returns the $uri for all existing regions with the given
    $scheme as a list of strings.
  */
  static list --scheme/string -> List:
    client := _client_
    if not client: throw "UNSUPPORTED"
    return client.region-list --scheme=scheme

  read --from/int bytes/ByteArray -> none:
    if not resource_: throw "ALREADY_CLOSED"
    flash-region-read_ resource_ from bytes

  read --from/int --to/int -> ByteArray:
    bytes := ByteArray (to - from)
    read --from=from bytes
    return bytes

  stream --from/int=0 --to/int=size --max-size/int=256 -> io.Reader:
    if not 0 <= from <= to <= size: throw "OUT_OF_BOUNDS"
    if max-size < 16: throw "Bad Argument"
    return RegionReader_
        --region=this
        --from=from
        --to=to
        --max-size=max-size

  /**
  Deprecated. Use $(write --at bytes) instead.
  */
  write --from/int bytes/ByteArray -> none:
    if not resource_: throw "ALREADY_CLOSED"
    flash-region-write_ resource_ from bytes

  /**
  Writes the given $data into the region at the given offset $at.

  If the region has already data, the new data might be combined
    with the existing data. See $erase-value, $write-can-clear-bits,
    and $write-can-set-bits. Use $erase to reset areas to the $erase-value
    after which this method will write the data as given.
  */
  write --at/int data/io.Data -> none:
    if not resource_: throw "ALREADY_CLOSED"
    flash-region-write_ resource_ at data

  is-erased --from/int=0 --to/int=size -> bool:
    if not resource_: throw "ALREADY_CLOSED"
    return flash-region-is-erased_ resource_ from (to - from)

  /**
  Erases the bytes in the range starting at $from and ending
    at $to (exclusive) by setting them to $erase-value.

  Both $from and $to must be aligned to $erase-granularity.
  */
  erase --from/int=0 --to/int=size -> none:
    if not resource_: throw "ALREADY_CLOSED"
    if from & erase-granularity-mask_ != 0: throw "Bad Argument"
    if to & erase-granularity-mask_ != 0: throw "Bad Argument"
    flash-region-erase_ resource_ from (to - from)

  close -> none:
    if resource_:
      flash-region-close_ resource_
      resource_ = null
    super

class RegionReader_ extends io.Reader:
  region_/Region
  from_/int := ?
  to_/int
  max-size_/int
  content-size/int

  constructor --region/Region --from/int --to/int --max-size/int:
    region_ = region
    from_ = from
    to_ = to
    max-size_ = max-size
    content-size = to - from

  read_ -> ByteArray?:
    from := from_
    remaining := to_ - from
    if remaining == 0: return null
    n := min
        // Prefer 16 byte alignment for next read,
        (round-down (from + max-size_) 16) - from
        // unless we're reading the final chunk.
        remaining
    result := ByteArray n
    region_.read --from=from result
    from_ = from + n
    return result

flash-region-open_ group client handle offset size:
  #primitive.flash.region-open

flash-region-close_ resource:
  #primitive.flash.region-close

flash-region-read_ resource from bytes:
  #primitive.flash.region-read

flash-region-write_ resource at data:
  #primitive.flash.region-write: | error |
    return io.primitive-redo-io-data_ error data: | bytes |
      flash-region-write_ resource at bytes


flash-region-is-erased_ resource from size:
  #primitive.flash.region-is-erased

flash-region-erase_ resource from size:
  #primitive.flash.region-erase
