// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import encoding.tison
import encoding.json

main:
  test_simple_types
  test_strings
  test_maps
  test_lists
  test_externals
  test_complex

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
  // size
  // slices

test_maps -> none:

test_lists -> none:
  // size
  // slices

test_externals -> none:

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
  expect_equals
      json.stringify x
      json.stringify decoded
