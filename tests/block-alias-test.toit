// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

aliased x [b]:
  c := b
  return c.call x

aliased-twice x [b]:
  c := b
  d := c
  return d.call x

aliased-in-block x [b]:
  c := b
  return [1].reduce --initial=0: | acc _ | acc + (c.call x)

aliased-outer x [b]:
  return [1].reduce --initial=0: | acc _ |
    c := b
    acc + (c.call x)

aliased-passed x [b]:
  c := b
  return aliased x c

local-alias x:
  c := : it + 1
  d := c
  return d.call x

local-alias-in-block x:
  c := : it + 1
  d := c
  return [1].reduce --initial=0: | acc _ | acc + (d.call x)

main:
  expect-equals 1 (aliased 1: it)
  expect-equals 2 (aliased-twice 1: it + 1)
  expect-equals 3 (aliased-in-block 1: it + 2)
  expect-equals 4 (aliased-outer 1: it + 3)
  expect-equals 5 (aliased-passed 1: it + 4)
  expect-equals 2 (local-alias 1)
  expect-equals 2 (local-alias-in-block 1)

  // Mutate a captured local through an alias.
  count := 0
  aliased 1: count += it
  expect-equals 1 count
