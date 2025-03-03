// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import bitmap show blit OR
import ..io as io

ENCODING-MAP_ ::= create-encoding-map_

create-encoding-map_ -> ByteArray:
  result := ByteArray 0x100
  "0123456789abcdef".write-to-byte-array result
  return result

/**
Takes an input $data and returns the corresponding string of hex digits.
# Examples
```
  hex.encode #[0x12, 0x34]  // Evaluates to the string "1234".
  hex.encode #[0x00, 0x42]  // Evaluates to the string "0042".
  hex.encode "A*"           // Evaluates to the string "412a".
  hex.encode #[]            // Evaluates to the empty string "".
```
*/
encode data/io.Data -> string:
  if data.byte-size == 0: return ""
  if data.byte-size == 1:
    c := data.byte-at 0
    return "$(%02x c)"
  result := ByteArray data.byte-size * 2
  blit data result data.byte-size
      --destination-pixel-stride=2
      --shift=4
      --mask=0b1111
  blit data result[1..] data.byte-size
      --destination-pixel-stride=2
      --mask=0b1111
  blit result result result.byte-size
      --lookup-table=ENCODING-MAP_
  return result.to-string

DECODING-MAP_ ::= create-decoding-map_

create-decoding-map_ -> ByteArray:
  result := ByteArray 0x100 --initial=0x10
  10.repeat:
    result['0' + it] = it
  6.repeat:
    result['a' + it] = it + 10
    result['A' + it] = it + 10
  return result

/**
Takes an input string consisting only of valid hexadecimal digits
  and returns the corresponding bytes in big-endian order.
# Example
```
  hex.decode "f00d"   // Evaluates to #[0xf0, 0x0d].
  hex.decode "7CAFE"  // Evaluates to #[0x07, 0xca, 0xfe].
```
*/
decode str/string -> ByteArray:
  if str.size == 0: return #[]
  if str.size <= 2: return #[int.parse --radix=16 str]
  checker := #[0]
  blit str checker str.size
      --destination-pixel-stride=0
      --lookup-table=DECODING-MAP_
      --operation=OR
  if checker[0] & 0x10 != 0: throw "INVALID_ARGUMENT"
  odd := str.size & 1
  result := ByteArray (str.size >> 1) + odd
  // Put high nibbles.
  blit str[odd..] result[odd..] (result.size - odd)
      --source-pixel-stride=2
      --lookup-table=DECODING-MAP_
      --shift=-4
  // Or in the low nibbles.
  blit str[odd ^ 1..] result result.size
      --source-pixel-stride=2
      --lookup-table=DECODING-MAP_
      --operation=OR
  return result
