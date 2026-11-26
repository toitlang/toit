// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

// The vector of a large array is an ordinary field and can be another large
// array. The interpreter's fast path for indexing must not recurse through an
// arbitrarily long chain of them (and overflow the C stack).

main:
  test-normal
  test-chain
  test-deep

test-normal:
  // Large arrays as the core library creates them, with a large array as
  // vector for the biggest one.
  [501, 250_001].do: | size |
    array := Array_ size
    expect array is LargeArray_
    size.repeat: array[it] = it
    expect-equals 0 array[0]
    expect-equals (size - 1) array[size - 1]
    list := List size
    expect-equals null list[size - 1]
    list[size - 1] = 42
    list.add 87
    expect-equals 42 list[size - 1]
    expect-equals 87 list[size]

// A chain of $length large arrays, each one the vector of the next, with
// decreasing sizes. Element 0 of each is the arraylet $inner.
make-chain length/int inner/Array_ -> LargeArray_:
  chain := LargeArray_ 501 inner
  for i := 1; i < length; i++:
    chain = LargeArray_.internal_ chain (501 + i)
  return chain

test-chain:
  inner := Array_ 500 null
  inner[0] = inner
  // Deeper than the fast path goes. The core library's operator [] gets the
  // element.
  chain := make-chain 100 inner
  expect-identical inner chain[0]
  chain[0] = 42
  expect-equals 42 inner[0]

test-deep:
  inner := Array_ 500 null
  inner[0] = inner
  chain := make-chain 1_000_000 inner
  expect-throw "STACK_OVERFLOW": chain[0]
  list := List_.from-array_ chain
  list.size_ = 0
  expect-throw "STACK_OVERFLOW": list.add 42
