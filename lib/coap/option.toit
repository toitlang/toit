// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import binary

OPTION_OBSERVE ::= 6
OPTION_URI_PATH ::= 11
OPTION_BLOCK_2 ::= 23
OPTION_SIZE_2 ::= 28

class Option:
  number/int ::= ?
  value/ByteArray ::= ?

  constructor.bytes .number .value:

  constructor.string .number str/string:
    value = str.to_byte_array

  constructor.uint .number u/int:
    if u == 0:
      value = ByteArray 0
    else if u < 256:
      value = ByteArray 1: u
    else if u < 256 * 256:
      value = ByteArray 2
      binary.BIG_ENDIAN.put_uint16 value 0 u
    else:
      value = ByteArray 4
      binary.BIG_ENDIAN.put_uint32 value 0 u

  as_string: return value.to_string

  as_uint:
    n := 0
    value.do: n = (n << 8) | it
    return n
