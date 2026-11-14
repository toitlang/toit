// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import crypto.crc
import encoding.base64
import expect show *
import io

/**
Tests that integer operations wrap around at 64 bits.

Ints are 64-bit two's complement numbers. Operations that overflow wrap
  around instead of throwing or growing. The VM used to compute some of these
  results with signed C++ arithmetic, which is undefined behavior on overflow.
*/

MIN ::= -9223372036854775808
MAX ::= 9223372036854775807
MAX-SMI64 ::= 4611686018427387903

main:
  test-add-subtract
  test-multiply
  test-negate
  test-shift-left
  test-folded
  test-stringify
  test-byte-order
  test-crc
  test-base64
  test-time

// Prevents the compiler from constant-folding the operations.
id x: return x

test-add-subtract:
  // Large integer receivers.
  expect-equals MIN ((id MAX) + (id 1))
  expect-equals 0 ((id MAX) + (id MAX) + (id 2))
  expect-equals -2 ((id MAX) + (id MAX))
  expect-equals 0 ((id MIN) + (id MIN))
  expect-equals MAX ((id MIN) - (id 1))
  expect-equals 1 ((id MIN) - (id MAX))
  expect-equals -1 ((id MAX) - (id MIN))
  expect-equals 0xe000_0000_0000_0000 ((id 0x7000_0000_0000_0000) + (id 0x7000_0000_0000_0000))
  // Smi receivers with large integer arguments.
  expect-equals MIN ((id 1) + (id MAX))
  expect-equals MAX ((id -1) + (id MIN))
  expect-equals MAX ((id -2) - (id MAX))
  expect-equals MIN ((id 0) - (id MIN))

test-multiply:
  // Large integer receivers.
  expect-equals -2 ((id MAX) * (id 2))
  expect-equals 0 ((id MIN) * (id 2))
  expect-equals MIN ((id MIN) * (id -1))
  expect-equals 1 ((id MAX) * (id MAX))
  expect-equals 0 ((id 0x4000_0000_0000_0000) * (id 4))
  // Smi receivers.
  expect-equals -2 ((id 2) * (id MAX))
  expect-equals MIN ((id -1) * (id MIN))
  expect-equals (MIN + 1) ((id MAX-SMI64) * (id MAX-SMI64))
  expect-equals MAX ((id MAX-SMI64) * (id -MAX-SMI64))
  // A negative smi argument whose product with the receiver overflows.
  expect-equals 0x4000_0000_7fff_ffff ((id MAX-SMI64) * (id -2147483647))
  expect-equals 0x4000_0000_7fff_ffff ((id -2147483647) * (id MAX-SMI64))
  // Products that don't overflow still work.
  expect-equals 0x8000_0001_0000_0000 ((id 0x1_0000_0000) * (id -2147483647))
  expect-equals -4 ((id 2) * (id -2))

test-negate:
  expect-equals MIN -(id MIN)
  expect-equals (MIN + 1) -(id MAX)
  expect-equals MAX -(id (MIN + 1))

test-shift-left:
  // Large integer receivers.
  expect-equals 0 ((id MIN) << (id 1))
  expect-equals -2 ((id MAX) << (id 1))
  expect-equals MIN ((id MAX) << (id 63))
  expect-equals 0 ((id MIN) << (id 64))
  // Smi receivers.
  expect-equals MIN ((id -1) << (id 63))
  expect-equals MIN ((id 1) << (id 63))
  expect-equals 0xc000_0000_0000_0000 ((id 3) << (id 62))
  expect-equals 0x6000_0000_0000_0000 ((id -5) << (id 61))
  expect-equals -8 ((id -1) << (id 3))
  expect-equals 0 ((id -1) << (id 64))
  expect-equals MIN ((id 0x7fff_ffff_ffff_ff) << (id 63))

test-folded:
  // The compiler folds these operations on constants. The results must be
  // the same as the ones computed at run time.
  expect-equals MIN (MAX + 1)
  expect-equals MAX (MIN - 1)
  expect-equals -2 (MAX * 2)
  expect-equals MIN (MIN * -1)
  expect-equals MIN (1 << 63)
  expect-equals 0xc000_0000_0000_0000 (3 << 62)
  expect-equals 0x6000_0000_0000_0000 (-5 << 61)
  // The compiler used to crash on these.
  expect-equals MIN (MIN / -1)
  expect-equals 0 (MIN % -1)

test-stringify:
  expect-equals "-8000000000000000" ((id MIN).stringify 16)
  expect-equals "-1y2p0ij32e8e8" ((id MIN).stringify 36)
  expect-equals "-9223372036854775808" (id MIN).stringify
  expect-equals "-1000000000000000000000000000000000000000000000000000000000000000" ((id MIN).stringify 2)

test-byte-order:
  all-ones := ByteArray 8: 0xff
  min-bytes := ByteArray 8
  min-bytes[0] = 0x80
  expect-equals -1 (io.BIG-ENDIAN.int64 all-ones 0)
  expect-equals -1 (io.LITTLE-ENDIAN.int64 all-ones 0)
  expect-equals MIN (io.BIG-ENDIAN.int64 min-bytes 0)
  expect-equals MIN (io.LITTLE-ENDIAN.int64 (ByteArray 8: it == 7 ? 0x80 : 0) 0)
  bytes := #[0xfe, 0xdc, 0xba, 0x98, 0x76, 0x54, 0x32, 0x10]
  expect-equals 0xfedc_ba98_7654_3210 (io.BIG-ENDIAN.int64 bytes 0)
  expect-equals 0x1032_5476_98ba_dcfe (io.LITTLE-ENDIAN.int64 bytes 0)
  expect-equals -19088744 (io.BIG-ENDIAN.int32 bytes 0)
  expect-equals -1732584194 (io.LITTLE-ENDIAN.int32 bytes 0)
  expect-equals -74566 (io.BIG-ENDIAN.int24 bytes 0)
  expect-equals -8962 (io.LITTLE-ENDIAN.int16 bytes 0)

/**
Computes a big-endian 64-bit CRC bit by bit, without the VM's table-driven
  primitive.
*/
crc64-big-endian data/ByteArray --polynomial/int --initial-state/int --xor-result/int -> int:
  sum := initial-state
  data.do: | byte |
    sum ^= byte << 56
    8.repeat:
      sum = (sum & MIN) != 0 ? ((sum << 1) ^ polynomial) : (sum << 1)
  return sum ^ xor-result

test-crc:
  // CRC-64/WE starts with an all-ones state, so the accumulator is negative.
  polynomial := 0x42f0_e1eb_a9ea_3693
  summer := crc.Crc.big-endian 64 --polynomial=polynomial --initial-state=-1 --xor-result=-1
  summer.add "123456789"
  expect-equals 0x62ec_59e3_f1a4_f00a summer.get-as-int
  data := ByteArray 100: it * 37
  summer = crc.Crc.big-endian 64 --polynomial=polynomial --initial-state=-1 --xor-result=-1
  summer.add data
  expected := crc64-big-endian data --polynomial=polynomial --initial-state=-1 --xor-result=-1
  expect-equals expected summer.get-as-int

test-base64:
  // Longer inputs shift the encoder's bit buffer past the word size.
  expect-equals "TWFueSBoYW5kcyBtYWtlIGxpZ2h0IHdvcmsu"
      base64.encode "Many hands make light work."
  data := ByteArray 1000: it * 13
  expect-equals data (base64.decode (base64.encode data))
  expect-equals data (base64.decode --url-mode (base64.encode --url-mode data))
  // Invalid characters are rejected.
  expect-throw "OUT_OF_RANGE": base64.decode "TW!u"
  expect-throw "OUT_OF_RANGE": base64.decode "TW!="
  expect-throw "OUT_OF_RANGE": base64.decode "T!=="

test-time:
  // The year is converted to a C 'tm' year by subtracting 1900. This must not
  // overflow for the smallest 32-bit year. The result itself isn't meaningful.
  catch: Time.local -2147483648 1 1
