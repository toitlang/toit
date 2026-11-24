// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

// The optimizer pushes a `return` of a conditional into the branches of the
// conditional. These tests make sure that the pushed returns leave the same
// block or method as the original one.

invoke [block]: return block.call
invoke-outer [block]: return block.call

block-return x -> List:
  result := [1, 2].map: continue.map (it == x ? 10 : 20)
  return result

block-return-nested-conditional x y -> List:
  result := [1, 2].map: continue.map (it == x ? (y ? 10 : 20) : 30)
  return result

block-return-outer x -> List:
  result := [1, 2].map: | a |
    invoke:
      continue.map (a == x ? 10 : 20)
    99
  return result

block-return-two-levels x -> int:
  result := invoke-outer:
    invoke:
      invoke:
        continue.invoke-outer (x == 1 ? 10 : 20)
      99
    98
  return result + 1

non-local-return x -> int:
  [1, 2].do: | e |
    invoke:
      return (e == x ? 10 : 20)
  return 0

method-return x -> int:
  return (x == 1 ? 10 : 20)

lambda-return x -> int:
  lambda := :: | y | y == x ? 10 : 20
  return lambda.call 1

main:
  expect-equals [10, 20] (block-return 1)
  expect-equals [20, 10] (block-return 2)
  expect-equals [10, 30] (block-return-nested-conditional 1 true)
  expect-equals [30, 20] (block-return-nested-conditional 2 false)
  expect-equals [10, 20] (block-return-outer 1)
  expect-equals 11 (block-return-two-levels 1)
  expect-equals 21 (block-return-two-levels 2)
  expect-equals 10 (non-local-return 1)
  expect-equals 20 (non-local-return 2)
  expect-equals 10 (method-return 1)
  expect-equals 20 (method-return 2)
  expect-equals 10 (lambda-return 1)
  expect-equals 20 (lambda-return 2)
