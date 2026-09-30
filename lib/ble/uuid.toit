// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import io
import uuid
import encoding.hex

/**
Bluetooth UUIDs: $BleUuid identifies services, characteristics and
  descriptors in both the `ble` package and `ble.v2`.
*/

/**
A BLE Universally Unique ID.

UUIDs are used to identify services, characteristics and descriptions.

UUIDs can have different sizes, with 16-bit and 128-bit the most common ones.
The 128-bit UUID is referred to as the vendor specific UUID. These must be used when
  making custom services or characteristics.

16-bit UUIDs of the form "XXXX" are short-hands for "0000XXXX-0000-1000-8000-00805F9B34FB",
  where "00000000-0000-1000-8000-00805F9B34FB" comes from the BLE standard and is called
  the "base UUID".
Similarly, a 32-bit UUID of the form "XXXXXXXX" is a short-hand for
  "XXXXXXXX-0000-1000-8000-00805F9B34FB".

See https://www.bluetooth.com/specifications/assigned-numbers/ for a list of
  assigned UUIDs.
*/
class BleUuid:
  data_/io.Data  // Either a ByteArray or a string.

  /**
  Constructs a new UUID from a byte array or a string.

  Does not check if a UUID can be shrunk by using the base UUID.
  */
  constructor data/io.Data:
    if data is not ByteArray and data is not string:
      data = ByteArray.from data
    data_ = data
    if data_ is ByteArray:
      bytes := data_ as ByteArray
      if bytes.size != 2 and bytes.size != 4 and bytes.size != 16: throw "INVALID UUID"
    else if data_ is string:
      str := data_ as string
      if str.size != 4 and str.size != 8 and str.size != 36: throw "INVALID UUID"
      if str.size == 36:
        uuid.Uuid.parse str // This throws an exception if the format is incorrect.
      else:
        if (catch: hex.decode str):
          throw "INVALID UUID $str"
      str = str.to-ascii-lower

  /**
  Constructs a new UUID from a 16-bit UUID where the $bytes are reversed.
  */
  constructor.from-reversed bytes/ByteArray:
    return BleUuid bytes.reverse

  /**
  Returns the UUID as a string of the form "XXXX" (16-bit UUID), "XXXXXXXX"
    (32-bit UUID), or "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX" (other UUIDs).
  */
  to-string -> string:
    if data_ is ByteArray:
      bytes := data_ as ByteArray
      if bytes.size <= 8:
        return hex.encode bytes
      else:
        return (uuid.Uuid bytes).stringify
    else:
      return data_ as string

  /**
  Returns a string representation of this UUID.

  If a deterministic UUID string representation is needed, prefer using $to-string.
  */
  stringify -> string:
    return to-string

  /**
  Returns the UUID as a byte array.

  The result is 2 bytes long for 16-bit UUIDs, 4 bytes long for 32-bit UUIDs,
    and 16 bytes long for 128-bit UUIDs.
  */
  to-byte-array --reversed/bool=false -> ByteArray:
    result/ByteArray := ?
    if data_ is string:
      str := data_ as string
      if str.size <= 8:
        result = hex.decode str
      else:
        result = (uuid.Uuid.parse str).to-byte-array
    else:
      result = data_ as ByteArray
      if reversed: result = result.copy
    if reversed: result.reverse --in-place
    return result

  hash-code -> int:
    return to-byte-array.hash-code

  operator== other/BleUuid:
    return to-byte-array == other.to-byte-array

  /** The size, in bytes, of the UUID. */
  byte-size -> int:
    if data_ is ByteArray: return (data_ as ByteArray).size
    return to-byte-array.size

  /** The size, in bits, of the UUID. */
  bit-size -> int:
    return byte-size * 8
