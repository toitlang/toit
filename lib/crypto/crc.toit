// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import .checksum

/**
Cyclic Redundancy Check (CRC).

CRC is an error-detection code.

See https://en.wikipedia.org/wiki/Cyclic_redundancy_check.
*/

/** Base for Cyclic Redundancy Check (CRC) algorithms. */
abstract class CrcBase extends Checksum:
  sum_/int := ?

  /** Constructs a CRC state with the given $sum_. */
  constructor .sum_:

  abstract crc_table_ -> List

  /** See $super. */
  add data from/int to/int -> none:
    /* Karl Malbrain's compact CRC-32. See "A compact CCITT crc16 and crc32 C
     * implementation that balances processor cache usage against speed":
     * http://www.geocities.com/malbrain/
     */
    table ::= crc_table_
    sum := sum_
    if data is string:
      (to - from).repeat:
        b := data.at --raw from + it
        sum = (sum >> 4) ^ table[(sum & 0xF) ^ (b & 0xF)];
        sum = (sum >> 4) ^ table[(sum & 0xF) ^ (b >> 4)];
    else:
      if data is not ByteArray: throw "WRONG_OBJECT_TYPE"
      (to - from).repeat:
        b := data[from + it]
        sum = (sum >> 4) ^ table[(sum & 0xF) ^ (b & 0xF)];
        sum = (sum >> 4) ^ table[(sum & 0xF) ^ (b >> 4)];
    sum_ = sum
