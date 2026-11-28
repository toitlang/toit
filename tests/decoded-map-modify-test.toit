// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import encoding.tison
import expect show *

// Maps that come out of the message decoder (TISON, and the arguments and
// results of RPC calls) can be modified like any other map.

main:
  test-add
  test-add-to-single
  test-remove
  test-filter

decoded size/int -> Map:
  map := {:}
  size.repeat: map[it] = "$it"
  return tison.decode (tison.encode map)

test-add:
  map := decoded 20
  map[100] = "100"
  expect-equals 21 map.size
  expect-equals "100" map[100]
  expect-equals "19" map[19]
  map.update 101 --init="" : it + "x"
  expect-equals "x" map[101]
  expect-equals [0, 1, 2] (map.keys.copy 0 3)

test-add-to-single:
  map := tison.decode (tison.encode {"a": 1})
  map["b"] = 2
  expect-structural-equals {"a": 1, "b": 2} map
  map = tison.decode (tison.encode {"a": 1})
  map.remove "a"
  map["b"] = 2
  expect-structural-equals {"b": 2} map

test-remove:
  map := decoded 20
  // Enough removals to compact the backing.
  15.repeat: map.remove it
  expect-equals 5 map.size
  expect-equals [15, 16, 17, 18, 19] map.keys
  map[0] = "0"
  expect-equals "0" map[0]
  expect-equals 6 map.size

test-filter:
  map := decoded 20
  map.filter --in-place: | key value | key >= 15
  expect-equals [15, 16, 17, 18, 19] map.keys
  map[0] = "0"
  expect-equals 6 map.size
