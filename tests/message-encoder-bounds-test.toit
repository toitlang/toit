// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import encoding.tison

// The size of a list, the bounds of a list slice and the size of a map are
// ordinary instance fields. The message encoder (used by tison and
// process-send_) must not trust them to be within the backing array.

NO-SUCH-PROCESS ::= 0x3fff_ffff

main:
  test-valid
  test-list-size
  test-list-slice
  test-map-size

test-valid:
  list := [1, 2, 3]
  list.add 4
  expect-equals list (tison.decode (tison.encode list))
  // A slice of an array and a slice of a growable list.
  array := Array_ 5 7
  expect-equals [7, 7] (tison.decode (tison.encode (ListSlice_ array 1 3)))
  expect-equals [2, 3] (tison.decode (tison.encode list[1..3]))
  expect-equals [] (tison.decode (tison.encode list[4..4]))
  // A map with deleted entries.
  map := {:}
  10.repeat: map[it] = it * 2
  5.repeat: map.remove (it * 2)
  expect-equals 5 map.size
  decoded := tison.decode (tison.encode map)
  expect-equals 5 decoded.size
  map.do: | key value | expect-equals value decoded[key]
  expect (tison.decode (tison.encode {:})).is-empty

expect-encoding-fails object:
  expect-throw "WRONG_OBJECT_TYPE": tison.encode object
  expect-throw "WRONG_OBJECT_TYPE": process-send_ NO-SUCH-PROCESS 0 object

test-list-size:
  // A list whose size exceeds its backing array.
  expect-encoding-fails (List_.private_ 1 100_000)
  expect-encoding-fails (List_.private_ 0 3)
  list := List_.private_ 3 3
  list.size_ = -1
  expect-encoding-fails list

test-list-slice:
  array := Array_ 2 0
  expect-encoding-fails (ListSlice_ array 0 100_000)
  expect-encoding-fails (ListSlice_ array 2 0)
  expect-encoding-fails (ListSlice_ array -1 1)
  // A slice of a growable list must stay within the list, even if the
  // backing array is larger.
  list := List_.private_ 4 2
  expect-encoding-fails (ListSlice_ list 0 3)
  expect-encoding-fails (ListSlice_ list 0 100_000)
  list.size_ = 100_000
  expect-encoding-fails (ListSlice_ list 0 100_000)

test-map-size:
  map := {1: 2}
  map.size_ = 100_000
  expect-encoding-fails map
  map.size_ = 2
  expect-encoding-fails map
  map.size_ = -1
  expect-encoding-fails map
  // The backing list's size can be larger than its array.
  map = {1: 2, 3: 4}
  map.size_ = 3
  (map.backing_ as List_).size_ = 100_000
  expect-encoding-fails map
