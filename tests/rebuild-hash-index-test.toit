// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

// The rebuild-hash-index primitive takes its arrays from Toit code. Found by
// the primitive fuzzer: an empty new index indexed out of bounds (VM crash),
// and a non-power-of-two or full index made the probing loop forever.

array-new size/int filler -> List:
  #primitive.core.array-new

rebuild old new -> none:
  #primitive.core.rebuild-hash-index

main:
  old := array-new 2 0
  old[0] = 0x1234
  old[1] = 0x5678
  [0, 3, 6, 7].do: | size |
    expect-throw "OUT_OF_RANGE": rebuild old (array-new size 0)

  // A full index.
  full := array-new 2 7
  expect-throw "OUT_OF_RANGE": rebuild old full

  // Non-smi entries are rejected without touching the new index.
  bad := array-new 2 "x"
  index := array-new 4 0
  expect-throw "INVALID_ARGUMENT": rebuild bad index
  4.repeat: expect-equals 0 index[it]

  // A valid rebuild.
  index = array-new 4 0
  rebuild old index
  expect (index.contains 0x1234)
  expect (index.contains 0x5678)

  // Maps still work (they use the primitive when growing).
  map := {:}
  1000.repeat: map[it] = it * 2
  1000.repeat: expect-equals it * 2 map[it]
