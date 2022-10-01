// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import encoding.tison
import encoding.ubjson

main:
  test_simple_types
  test_strings
  test_maps
  test_lists
  test_byte_arrays
  test_complex

  test_wrong_marker
  test_wrong_version
  test_wrong_size

test_simple_types -> none:
  // null
  test_round_trip null
  // integers
  test_round_trip 0
  test_round_trip 2
  test_round_trip -3
  test_round_trip 9871
  test_round_trip 0x01234567
  test_round_trip 0x12345678
  test_round_trip 0xfedecafe
  test_round_trip -(0xfedecafe)
  test_round_trip 0x12345678910
  // floats
  test_round_trip 0.11
  test_round_trip -7.19
  // bools
  test_round_trip true
  test_round_trip false

test_strings -> none:
  test_round_trip "fisk"
  test_round_trip "hest"
  test_round_trip "hest"[0..1]
  test_round_trip "hest"[2..4]
  x := "fiskhest"
  15.repeat:
    x += "$x$x.size"
    test_round_trip x
    test_round_trip x[0..x.size / 2]

test_maps -> none:
  test_round_trip {:}
  test_round_trip {"foo": 42}
  test_round_trip {"bar": {"baz": null}}

test_lists -> none:
  test_round_trip [0, 1, 2, 3]
  test_round_trip [1, 2, 3, 4]
  // TODO(kasper): encoding.tison deals incorrectly with large
  // lists and list slices.
  expect_throw "WRONG_OBJECT_TYPE": test_round_trip [1, 2, 3, 4][0..1]
  expect_throw "WRONG_OBJECT_TYPE": test_round_trip [1, 2, 3, 4][2..4]
  x := [0, 1, 2, 3, 4, 5, 6, 7, 8]
  10.repeat:
    x += x + [x.size]
    if x is List_ and (x as List_).array_ is LargeArray_:
      expect_throw "WRONG_OBJECT_TYPE": test_round_trip x
    else:
      test_round_trip x
    expect_throw "WRONG_OBJECT_TYPE": test_round_trip x[0..x.size / 2]

test_byte_arrays -> none:
  test_round_trip (ByteArray 0)
  test_round_trip (ByteArray 4: it)
  test_round_trip (ByteArray 9: it * 793)
  test_round_trip #[1, 2, 3, 4]
  test_round_trip #[0, 1, 2, 3]
  test_round_trip #[1, 2, 3, 4]
  test_round_trip #[1, 2, 3, 4][0..1]
  test_round_trip #[1, 2, 3, 4][2..4]
  x := #[1, 2, 3, 4, 5, 6, 7, 8]
  15.repeat:
    x += x + #[x.size & 0xff]
    test_round_trip x
    test_round_trip x[0..x.size / 2]

test_complex -> none:
  test_round_trip {
    "identity": "foo.bar",
    "payload": {
      "fisk": [ 1, 2, 3, "baz" ],
      "bims": null,
      "buz": 999,
    },
  }

test_round_trip x/any -> none:
  encoded := tison.encode x
  decoded := tison.decode encoded
  expect_bytes_equal
      ubjson.encode x
      ubjson.encode decoded

test_wrong_marker:
  x := tison.encode {:}
  x[0] ^= 99
  expect_throw "WRONG_OBJECT_TYPE": tison.decode x

test_wrong_version:
  x := tison.encode {:}
  x[1] ^= 99
  expect_throw "WRONG_OBJECT_TYPE": tison.decode x

test_wrong_size:
  x := tison.encode {:}
  expect_throw "WRONG_OBJECT_TYPE": tison.decode x[0..x.size - 1]
  expect_throw "WRONG_OBJECT_TYPE": tison.decode (x + #[42])
