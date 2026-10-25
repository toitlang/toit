// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import encoding.tison
import encoding.ubjson

import .io-utils

main:
  test-simple-types
  test-strings
  test-maps
  test-lists
  test-byte-arrays
  test-complex
  test-too-much-map-nesting

  test-wrong-marker
  test-wrong-version
  test-wrong-size
  test-random-corruption
  test-crafted-input

test-simple-types -> none:
  // null
  test-round-trip null
  // integers
  test-round-trip 0
  test-round-trip 2
  test-round-trip -3
  test-round-trip 9871
  test-round-trip 0x01234567
  test-round-trip 0x12345678
  test-round-trip 0xfedecafe
  test-round-trip -(0xfedecafe)
  test-round-trip 0x12345678910
  // floats
  test-round-trip 0.11
  test-round-trip -7.19
  // bools
  test-round-trip true
  test-round-trip false

test-strings -> none:
  test-round-trip "fisk"
  test-round-trip "hest"
  test-round-trip "hest"[0..1]
  test-round-trip "hest"[2..4]
  x := "fiskhest"
  15.repeat:
    x += "$x$x.size"
    test-round-trip x
    test-round-trip x[0..x.size / 2]

test-maps -> none:
  test-round-trip {:}
  test-round-trip {"foo": 42}
  test-round-trip {"bar": {"baz": null}}

test-lists -> none:
  test-round-trip [0, 1, 2, 3]
  test-round-trip [1, 2, 3, 4]
  test-round-trip [1, 2, 3, 4][0..1]
  test-round-trip [1, 2, 3, 4][2..4]
  x := [0, 1, 2, 3, 4, 5, 6, 7, 8]
  10.repeat:
    x += x + [x.size]
    // TODO(kasper): encoding.tison deals incorrectly with large lists.
    if x is List_ and (x as List_).array_ is LargeArray_:
      expect-throw "WRONG_OBJECT_TYPE": test-round-trip x
      expect-throw "WRONG_OBJECT_TYPE": test-round-trip x[0..x.size / 2]
    else:
      test-round-trip x
      test-round-trip x[0..x.size / 2]
  // TISON decodes lists to simpler arrays. Make sure
  // we deal correctly with slices of those too.
  array := tison.decode (tison.encode [0, 1, 2, 3])
  test-round-trip array
  test-round-trip array[0..1]

test-byte-arrays -> none:
  test-round-trip (ByteArray 0)
  test-round-trip (ByteArray 4: it)
  test-round-trip (ByteArray 9: it * 793)
  test-round-trip #[1, 2, 3, 4]
  test-round-trip #[0, 1, 2, 3]
  test-round-trip #[1, 2, 3, 4]
  test-round-trip #[1, 2, 3, 4][0..1]
  test-round-trip #[1, 2, 3, 4][2..4]
  x := #[1, 2, 3, 4, 5, 6, 7, 8]
  15.repeat:
    x += x + #[x.size & 0xff]
    test-round-trip x
    test-round-trip x[0..x.size / 2]

test-complex -> none:
  test-round-trip {
    "identity": "foo.bar",
    "payload": {
      "fisk": [ 1, 2, 3, "baz" ],
      "bims": null,
      "buz": 999,
    },
  }

test-too-much-map-nesting -> none:
  nested := {
    "foo": "bar"
  }
  nested["baz"] = nested
  expect-throw "NESTING_TOO_DEEP":
    test-round-trip nested

test-round-trip x/any -> none:
  encoded := tison.encode x
  decoded := tison.decode encoded
  decoded2 := tison.decode (FakeData encoded)
  expect-structural-equals decoded decoded2
  expect-bytes-equal
      ubjson.encode x
      ubjson.encode decoded

test-wrong-marker:
  x := tison.encode {:}
  x[0] ^= 99
  expect-throw "WRONG_OBJECT_TYPE": tison.decode x

test-wrong-version:
  x := tison.encode {:}
  x[1] ^= 99
  expect-throw "WRONG_OBJECT_TYPE": tison.decode x

test-wrong-size:
  x := tison.encode {:}
  expect-throw "WRONG_OBJECT_TYPE": tison.decode x[0..x.size - 1]
  expect-throw "WRONG_OBJECT_TYPE": tison.decode (x + #[42])

test-random-corruption:
  variants := [ null, 1, -2, {:}, [7, 9, 13], ByteArray 19: it ]
  variants.do: | input |
    encoded := tison.encode input
    100_000.repeat:
      copy := encoded.copy
      copy[random copy.size] ^= 1 << (random 8)
      decoded := null
      exception := catch: decoded = tison.decode copy
      if exception:
        expect-equals "WRONG_OBJECT_TYPE" exception

// Tags of the encoding. Must match src/messaging.cc.
TAG-POSITIVE-SMI ::= 1
TAG-NEGATIVE-SMI ::= 2
TAG-NULL ::= 3
TAG-ARRAY ::= 6
TAG-MAP ::= 9
TAG-STRING-INLINE ::= 11
TAG-BYTE-ARRAY-INLINE ::= 13

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

test-crafted-input:
  // Sanity check the helpers.
  expect-null (tison.decode (make-tison #[TAG-NULL]))
  expect-equals 0x3fff_ffff
      tison.decode (make-tison #[TAG-POSITIVE-SMI] + (encode-cardinal 0x3fff_ffff))
  expect-equals -(0x4000_0000)
      tison.decode (make-tison #[TAG-NEGATIVE-SMI] + (encode-cardinal 0x4000_0000))
  expect-equals "abc"
      tison.decode (make-tison #[TAG-STRING-INLINE, 3, 'a', 'b', 'c'])
  expect-bytes-equal #[1, 2]
      tison.decode (make-tison #[TAG-BYTE-ARRAY-INLINE, 2, 1, 2])
  expect-structural-equals [null, null]
      tison.decode (make-tison #[TAG-ARRAY, 2, TAG-NULL, TAG-NULL])
  expect-structural-equals {5: null}
      tison.decode (make-tison #[TAG-MAP, 1, TAG-POSITIVE-SMI, 5, TAG-NULL])

  // Strings and byte arrays that are longer than the remaining input.
  [TAG-STRING-INLINE, TAG-BYTE-ARRAY-INLINE].do: | tag/int |
    [4, 100, 1_000_000, 0x3fff_ffff].do: | length/int |
      payload := #[tag] + (encode-cardinal length) + #['a', 'b', 'c']
      expect-throw "WRONG_OBJECT_TYPE": tison.decode (make-tison payload)

  // Arrays and maps with more entries than the input could hold.
  [TAG-ARRAY, TAG-MAP].do: | tag/int |
    [3, 1000, 0x3fff_ffff].do: | length/int |
      payload := #[tag] + (encode-cardinal length) + #[TAG-NULL, TAG-NULL]
      expect-throw "WRONG_OBJECT_TYPE": tison.decode (make-tison payload)

  // Smis that are outside the Smi range.
  // 2^62 is too big for a positive Smi on all platforms.
  two-62 := #[0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x40]
  // 2^62 + 1 is too big for a negative Smi on all platforms.
  two-62-plus-1 := #[0x81, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x40]
  // 2^63 is too big for any Smi.
  two-63 := #[0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01]
  expect-throw "WRONG_OBJECT_TYPE": tison.decode (make-tison #[TAG-POSITIVE-SMI] + two-62)
  expect-throw "WRONG_OBJECT_TYPE": tison.decode (make-tison #[TAG-POSITIVE-SMI] + two-63)
  expect-throw "WRONG_OBJECT_TYPE": tison.decode (make-tison #[TAG-NEGATIVE-SMI] + two-62-plus-1)
  expect-throw "WRONG_OBJECT_TYPE": tison.decode (make-tison #[TAG-NEGATIVE-SMI] + two-63)
