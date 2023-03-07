// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

main:
  test_simple

test_simple:
  map := {:}
  id (map.backing_)  // The VM sometimes produced maps with arrays as backing.

id x:
  return x
