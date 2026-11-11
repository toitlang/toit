// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import encoding.tison
import expect show *

// TISON input is untrusted. A cardinal with bits beyond what it can hold (a
// length or the payload size: the word; a smi's magnitude: 64 bits, also on
// a 32-bit VM, tests/tison-integer-width-test.toit) is malformed; the
// decoder used to drop the high bits, so that 2^64 (2^32 on a 32-bit VM)
// decoded as 0 (found by the VeriFast proof of the decoder,
// verified/cxx/annotated/decoder).

MARKER ::= #[0xf7, 0x01, 0x89, 0xa6]
TAG-POSITIVE-SMI ::= 1
TAG-ARRAY ::= 6

/** A TISON message of the given payload. */
message payload/ByteArray -> ByteArray:
  return MARKER + #[payload.size] + payload

/** The cardinal 2^$bits plus $low, in digits of 7 bits. */
cardinal-power bits/int --low/int=0 -> ByteArray:
  digits := bits / 7
  result := ByteArray digits + 1: 0x80
  result[0] = 0x80 | low
  result[digits] = 1 << (bits % 7)
  return result

main:
  // A 32-bit VM encodes 2^40 as a large integer, a 64-bit one as a smi.
  word-bits := (tison.encode (1 << 40))[MARKER.size + 1] == TAG-POSITIVE-SMI ? 64 : 32

  // Sanity: the encoder's cardinals round-trip.
  expect-equals 5 (tison.decode (message #[TAG-POSITIVE-SMI, 5]))
  expect-equals 300 (tison.decode (message #[TAG-POSITIVE-SMI, 0xac, 0x02]))

  // 2^64 + 5: the high bit falls out of 64 bits (was decoded as 5).
  over := message #[TAG-POSITIVE-SMI] + (cardinal-power 64 --low=5)
  expect-throw "WRONG_OBJECT_TYPE": tison.decode over

  // The same as an array length (was decoded as the empty array).
  array := message #[TAG-ARRAY] + (cardinal-power word-bits)
  expect-throw "WRONG_OBJECT_TYPE": tison.decode array
