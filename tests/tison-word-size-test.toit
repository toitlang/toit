// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import encoding.tison
import expect show *

/**
Tests that TISON written by a VM of one word size decodes to the same
  integers on a VM of the other word size.

A 64-bit VM writes integers of up to 62 bits with the smi tags. A 32-bit
  VM writes integers beyond 30 bits as large integers.
*/

// Tags of the encoding. Must match src/messaging.cc.
TAG-POSITIVE-SMI ::= 1
TAG-NEGATIVE-SMI ::= 2
TAG-LARGE-INTEGER ::= 8

main:
  values := [
    0, 5, -5,
    0x3fff_ffff, -(0x4000_0000),  // The 32-bit smi range.
    0x4000_0000, -(0x4000_0001),
    3_000_000_000, -3_000_000_000,
    0x3fff_ffff_ffff_ffff, -(0x4000_0000_0000_0000),  // The 64-bit smi range.
  ]
  values.do: | value/int |
    // As a 64-bit VM writes it.
    from-64 := value >= 0
        ? make-tison #[TAG-POSITIVE-SMI] + (encode-cardinal value)
        : make-tison #[TAG-NEGATIVE-SMI] + (encode-cardinal -value)
    // As a 32-bit VM writes it if it isn't a 32-bit smi.
    from-32 := make-tison #[TAG-LARGE-INTEGER] + (ByteArray 8: (value >> (it * 8)) & 0xff)
    [from-64, from-32].do: | bytes/ByteArray |
      decoded := tison.decode bytes
      expect-equals value decoded
      expect (identical value decoded)
    expect (identical value (tison.decode (tison.encode value)))

encode-cardinal value/int -> ByteArray:
  assert: value >= 0
  bytes := []
  while value >= 128:
    bytes.add (value & 0x7f) | 0x80
    value >>= 7
  bytes.add value
  return ByteArray bytes.size: bytes[it]

/**
Wraps the given $payload in a TISON header with the correct payload size.
*/
make-tison payload/ByteArray -> ByteArray:
  marker := (tison.encode null)[..4]
  return marker + (encode-cardinal payload.size) + payload
