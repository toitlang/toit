// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

some_method p1 p2 p3 p4 p5 p6 [b]:
  expect_equals 1 p1
  expect_equals 2 p2
  expect_equals 3 p3
  expect_equals 4 p4
  expect_equals 5 p5
  expect_equals 6 p6
  expect_equals 7 (b.call 1)
  return "ok"

arg1 := 1

arg2 [b]:
  return b.call 0

arg3 [b]:
  return b.call 1

arg4 x y:
  return x + y - 12

more_arg4s := 4

even_more [b]:
  return b.call 7

foobar x:
  return x + 5

arg5 x [b]:
  return b.call x

more_arg5s := 6

body_of_arg5 x:
  return x - 1

arg6 x:
  return x

more_arg6s := 6

foo x y:
  return x + y

toto := "toto"
titi := "titi"

foo x:
  return true

bar := "tete"

run [b]:
  return b.call

main:
  x := run:
    foo toto
        titi
  expect_equals "tototiti" x

  x = run:
    some_method
        arg1
        arg2: it + 2
        arg3:
          it * 3
        arg4
            more_arg4s
            even_more:
              foobar it
        arg5
            more_arg5s:
          body_of_arg5 it
        arg6
            more_arg6s:
      7
  expect_equals "ok" x

  x = run:
    some_method
        arg1
        arg2: it + 2
        arg3: |it|
          it * 3
        arg4
            more_arg4s
            even_more: |it|
              foobar it
        arg5
            more_arg5s: |it|
          body_of_arg5 it
        arg6
            more_arg6s: |x|
      7
  expect_equals "ok" x

  x = run:
    some_method
      arg1
      (arg2: it + 2)
      (arg3: it * 3)
      (arg4 more_arg4s (even_more: foobar it))
      (arg5 more_arg5s
            (: body_of_arg5 it))
      (arg6 more_arg6s)
      : 7
  expect_equals "ok" x

  x = true ?
    arg3: it + 2 :
    arg3: it * 2
  expect_equals 3 x

  x = true
    ? arg3: it + 2
    : arg3: it * 2
  expect_equals 3 x

  x = true ?
   arg3: it + 2
  : arg3: it * 2
  expect_equals 3 x

  x = true ?
    arg3: arg3:
      2 + it:
    arg3: it * 2
  expect_equals 3 x

  x = run:
    if foo
        bar:
      "ok"
  expect_equals "ok" x
