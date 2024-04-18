// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

some-method p1 p2 p3 p4 p5 p6 [b]:
  expect-equals 1 p1
  expect-equals 2 p2
  expect-equals 3 p3
  expect-equals 4 p4
  expect-equals 5 p5
  expect-equals 6 p6
  expect-equals 7 (b.call 1)
  return "ok"

arg1 := 1

arg2 [b]:
  return b.call 0

arg3 [b]:
  return b.call 1

arg4 x y:
  return x + y - 12

more-arg4s := 4

even-more [b]:
  return b.call 7

foobar x:
  return x + 5

arg5 x [b]:
  return b.call x

more-arg5s := 6

body-of-arg5 x:
  return x - 1

arg6 x:
  return x

more-arg6s := 6

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
  expect-equals "tototiti" x

  x = run:
    some-method
        arg1
        arg2: it + 2
        arg3:
          it * 3
        arg4
            more-arg4s
            even-more:
              foobar it
        arg5
            more-arg5s:
          body-of-arg5 it
        arg6
            more-arg6s:
      7
  expect-equals "ok" x

  x = run:
    some-method
        arg1
        arg2: it + 2
        arg3: |it|
          it * 3
        arg4
            more-arg4s
            even-more: |it|
              foobar it
        arg5
            more-arg5s: |it|
          body-of-arg5 it
        arg6
            more-arg6s: |x|
      7
  expect-equals "ok" x

  x = run:
    some-method
      arg1
      (arg2: it + 2)
      (arg3: it * 3)
      (arg4 more-arg4s (even-more: foobar it))
      (arg5 more-arg5s
            (: body-of-arg5 it))
      (arg6 more-arg6s)
      : 7
  expect-equals "ok" x

  x = true ?
    arg3: it + 2 :
    arg3: it * 2
  expect-equals 3 x

  x = true
    ? arg3: it + 2
    : arg3: it * 2
  expect-equals 3 x

  x = true ?
   arg3: it + 2
  : arg3: it * 2
  expect-equals 3 x

  x = true ?
    arg3: arg3:
      2 + it:
    arg3: it * 2
  expect-equals 3 x

  x = run:
    if foo
        bar:
      "ok"
  expect-equals "ok" x
