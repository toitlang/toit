// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import io show BIG-ENDIAN

OPTION-OBSERVE ::= 6
OPTION-URI-PATH ::= 11
OPTION-BLOCK-2 ::= 23
OPTION-SIZE-2 ::= 28

class Option:
  number/int ::= ?
  value/ByteArray ::= ?

  constructor.bytes .number .value:

  constructor.string .number str/string:
    value = str.to-byte-array

  constructor.uint .number u/int:
    if u == 0:
      value = ByteArray 0
    else if u < 256:
      value = ByteArray 1 --initial=u
    else if u < 256 * 256:
      value = ByteArray 2
      BIG-ENDIAN.put-uint16 value 0 u
    else:
      value = ByteArray 4
      BIG-ENDIAN.put-uint32 value 0 u

  as-string: return value.to-string

  as-uint:
    n := 0
    value.do: n = (n << 8) | it
    return n
