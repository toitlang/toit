// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import encoding.tison
import expect show *
import io show LITTLE-ENDIAN

// TISON is portable between 64-bit and 32-bit VMs, and decoded integers are
// canonical (a smi whenever the value is in the VM's smi range). The
// encoder writes a smi with a smi tag and a large integer with the large
// integer tag, so a 64-bit VM writes smi tags for values up to 2^62, which
// a 32-bit VM rejected as malformed (WRONG_OBJECT_TYPE) above 2^30; and a
// 32-bit VM writes large integers for values a 64-bit VM decoded as large
// integers in its smi range (equal to the smi, but not identical, and
// encoded again as large integers). Found by the VeriFast proof of the
// decoder (verified/cxx/annotated/decoder).

MARKER ::= #[0xf7, 0x01, 0x89, 0xa6]
TAG-POSITIVE-SMI ::= 1
TAG-NEGATIVE-SMI ::= 2
TAG-LARGE-INTEGER ::= 8

/** A TISON message of the given payload. */
message payload/ByteArray -> ByteArray:
  return MARKER + (cardinal payload.size) + payload

/** The cardinal $n >= 0, in digits of 7 bits. */
cardinal n/int -> ByteArray:
  bytes := []
  while n >= 128:
    bytes.add (n & 0x7f) | 0x80
    n >>= 7
  bytes.add n
  return ByteArray bytes.size: bytes[it]

/** $n with a smi tag, as a VM whose smis hold $n writes it. */
smi n/int -> ByteArray:
  if n >= 0: return #[TAG-POSITIVE-SMI] + (cardinal n)
  return #[TAG-NEGATIVE-SMI] + (cardinal -n)

/** $n with the large integer tag, as a VM whose smis don't hold $n writes it. */
large n/int -> ByteArray:
  bytes := ByteArray 8
  LITTLE-ENDIAN.put-int64 bytes 0 n
  return #[TAG-LARGE-INTEGER] + bytes

expect-canonical value/int decoded/int:
  expect-equals value decoded
  // The encoder writes a smi tag exactly for a smi: a decoded value that
  // isn't canonical is encoded with the other tag.
  expect-equals (tison.encode value) (tison.encode decoded)

main:
  values := [
    0, 1, -1, 5, -5,
    (1 << 30) - 1, 1 << 30, -(1 << 30), -(1 << 30) - 1,  // 32-bit smi range.
    1 << 31, -(1 << 31), 1 << 32,
    1_700_000_000_000, -1_700_000_000_000,  // A time in milliseconds.
    (1 << 62) - 1, 1 << 62, -(1 << 62), -(1 << 62) - 1,  // 64-bit smi range.
    int.MAX, int.MIN + 1, int.MIN,
  ]
  values.do: | value/int |
    // int.MIN has no magnitude in int64: only the large integer tag.
    if value != int.MIN:
      expect-canonical value (tison.decode (message (smi value)))
    expect-canonical value (tison.decode (message (large value)))
    expect-canonical value (tison.decode (tison.encode value))

  // A smi tag's magnitude is at most int.MAX: 2^63 is malformed for both
  // signs (int.MIN is only written as a large integer).
  two-63 := (ByteArray 9: 0x80) + #[1]
  expect-throw "WRONG_OBJECT_TYPE": tison.decode (message #[TAG-POSITIVE-SMI] + two-63)
  expect-throw "WRONG_OBJECT_TYPE": tison.decode (message #[TAG-NEGATIVE-SMI] + two-63)
