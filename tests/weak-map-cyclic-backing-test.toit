// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import system

// The garbage collector clears the dead values of weak maps by walking the
// map's backing. The backing's fields are ordinary instance fields; a large
// array whose vector contains the large array itself must not make the
// collector recurse without bound.

main:
  test-cyclic
  test-large

test-cyclic:
  vector := Array_ 1
  large := LargeArray_.internal_ vector 10
  vector[0] = large
  map := Map.weak
  map[1] = Object
  (map.backing_ as List_).array_ = large
  system.process-stats --gc

test-large:
  // A weak map large enough to have a large array as backing still has its
  // dead values cleared.
  map := Map.weak
  2000.repeat: map[it] = Object
  keep := Object
  map[2000] = keep
  expect ((map.backing_ as List_).array_ is LargeArray_)
  system.process-stats --gc
  expect-identical keep map[2000]
  expect-null map[0]
