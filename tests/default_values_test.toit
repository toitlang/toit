// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

foo x=499:
  return x

bar x=1 y=2:
  return x + 2

fun [b]:
  return b.call 489

gee x y=(fun: it + 1):
  return x + y

class A:
  foo:
    return 499

  bar x=foo:
    return x

previous x y=x.size:
  return y

previous2 x y=x[0]:
  return y

minus x=-499:
  return x

literal_list x=[]:
  x.add 499
  return x.size

literal_list2 x=[1, 2]:
  x.add 499
  return x.size

literal_map x={:}:
  x[499] = x.size
  return x[499]

literal_map2 x={
    499 : 42,
    42 : 499
  }:
  x["len"] = x.size
  return x["len"]

literal_set x={}:
  x.add x.size
  return x.size

literal_set2 x={11, 12, 13}:
  x.add x.size
  return x.size

literal_string x="""

1""":
  return x

literal_float x=1.234:
  return x

class B:
  field ::= ?
  constructor .field:

  with --field=field:
    return B field

main:
  expect_equals 499 (foo null)
  expect_equals 3 (bar null null)
  expect_equals 499 (gee 9 null)
  expect_equals 499 ((A).bar null)
  expect_equals 5 (previous [1, 2, 3, 4, 5] null)
  expect_equals 1 (previous2 [1, 2, 3, 4, 5] null)
  expect_equals -499 (minus null)

  // Run each of the following tests twice to ensure that the literals aren't reused.
  expect_equals 1 (literal_list null)
  expect_equals 1 (literal_list null)
  expect_equals 3 (literal_list2 null)
  expect_equals 3 (literal_list2 null)
  expect_equals 0 (literal_map null)
  expect_equals 0 (literal_map null)
  expect_equals 2 (literal_map2 null)
  expect_equals 2 (literal_map2 null)
  expect_equals 1 (literal_set null)
  expect_equals 1 (literal_set null)
  expect_equals 4 (literal_set2 null)
  expect_equals 4 (literal_set2 null)

  expect_equals "\n1" (literal_string null)
  expect_equals 1.234 (literal_float null)

  b := B 499
  b2 := b.with --field=42
  expect_equals 42 b2.field
