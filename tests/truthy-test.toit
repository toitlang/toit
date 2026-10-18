// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

// 'truthy' values are conditions: there are no runtime checks, and
// non-boolean values keep their truthiness.

count list/List [predicate any -> truthy] -> int:
  result := 0
  list.do: if predicate.call it: result++
  return result

identity x/truthy -> truthy:
  return x

monitor Latch:
  message_ := null
  done_ := false
  set message: message_ = message
  finish: done_ = true
  wait-for-either: await: message_ or done_

main:
  list := [1, null, "str", 0, false]
  expect-equals 3 (count list: it)
  expect-equals 1 (count list: it == 1)
  expect-equals 3 (count list: identity it)
  expect (list.any: it)
  expect-not (list.every: it)
  expect-equals [1, "str", 0] (list.filter: it)

  str/any := "str"
  x := identity str
  expect (x ? true : false)
  nothing/any := null
  y := identity nothing
  expect-not (y ? true : false)

  latch := Latch
  task:: latch.set "hello"
  latch.wait-for-either
