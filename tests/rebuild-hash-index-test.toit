// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

rebuild-hash-index old new:
  #primitive.core.rebuild-hash-index

main:
  entry := (5 << 12) | 1

  // A valid rebuild places the entry at its hash slot.
  index := Array_ 4 0
  rebuild-hash-index (Array_ 1 entry) index
  expect-list-equals [0, entry, 0, 0] index

  // An empty index array used to read and write out of bounds.
  expect-throw "INVALID_ARGUMENT":
    rebuild-hash-index (Array_ 1 entry) (Array_ 0 0)

  // An index array without a free slot used to loop forever.
  full := Array_ 4 0
  4.repeat: full[it] = (it + 1) << 12
  expect-throw "INVALID_ARGUMENT":
    rebuild-hash-index (Array_ 1 entry) full
  4.repeat: expect-equals ((it + 1) << 12) full[it]

  // The probing only works for power-of-two index arrays.
  expect-throw "INVALID_ARGUMENT":
    rebuild-hash-index (Array_ 1 entry) (Array_ 3 0)
