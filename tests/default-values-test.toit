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

literal-list x=[]:
  x.add 499
  return x.size

literal-list2 x=[1, 2]:
  x.add 499
  return x.size

literal-map x={:}:
  x[499] = x.size
  return x[499]

literal-map2 x={
    499 : 42,
    42 : 499
  }:
  x["len"] = x.size
  return x["len"]

literal-set x={}:
  x.add x.size
  return x.size

literal-set2 x={11, 12, 13}:
  x.add x.size
  return x.size

literal-string x="""

1""":
  return x

literal-float x=1.234:
  return x

class B:
  field ::= ?
  constructor .field:

  with --field=field:
    return B field

main:
  expect-equals 499 (foo null)
  expect-equals 3 (bar null null)
  expect-equals 499 (gee 9 null)
  expect-equals 499 ((A).bar null)
  expect-equals 5 (previous [1, 2, 3, 4, 5] null)
  expect-equals 1 (previous2 [1, 2, 3, 4, 5] null)
  expect-equals -499 (minus null)

  // Run each of the following tests twice to ensure that the literals aren't reused.
  expect-equals 1 (literal-list null)
  expect-equals 1 (literal-list null)
  expect-equals 3 (literal-list2 null)
  expect-equals 3 (literal-list2 null)
  expect-equals 0 (literal-map null)
  expect-equals 0 (literal-map null)
  expect-equals 2 (literal-map2 null)
  expect-equals 2 (literal-map2 null)
  expect-equals 1 (literal-set null)
  expect-equals 1 (literal-set null)
  expect-equals 4 (literal-set2 null)
  expect-equals 4 (literal-set2 null)

  expect-equals "\n1" (literal-string null)
  expect-equals 1.234 (literal-float null)

  b := B 499
  b2 := b.with --field=42
  expect-equals 42 b2.field
