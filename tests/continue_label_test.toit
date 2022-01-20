// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

foo [block]: return block.call + 1
bar [block]: return block.call + 10
gee [block]: return block.call + 100

toto fun/Lambda: return fun.call + 1000

test1:
  expect_equals 119
    foo:
      bar:
        gee: 8

  expect_equals 499
    foo: continue.foo 498

  expect_equals 499
    foo:
      bar:
        gee: continue.foo 498

  expect_equals 18
    foo:
      bar:
        gee: continue.bar 7

  expect_equals 117
    foo:
      bar:
        gee: continue.gee 6

  expect_equals 499
    foo:
      bar:
        gee:
          continue.foo 498
          unreachable
        unreachable
      unreachable

  expect_equals 1018
    foo:
      val := bar:
        gee:
          continue.bar 7
          unreachable
        unreachable
      val + 1000

  expect_equals 499
    foo:
      while true:
        bar:
          while true:
            gee: continue.foo 498

  expect_equals 18
    foo:
      bar:
        while true:
          gee: continue.bar 7

  expect_equals 117
    foo:
      bar:
        gee: continue.gee 6

  expect_equals 5
    foo:
      foo:
        foo:
          foo:
            continue.foo 1

  expect_equals 5
    foo:
      foo:
        foo:
          foo:
            bar:
              bar:
                continue.foo 1

  expect_equals 1499
    toto::
      continue.toto 499

  expect_equals 1499
    toto::
      foo:
        continue.foo 498

  expect_equals 1499
    toto::
      foo:
        continue.toto 499

  expect_equals 1499
    toto::
      foo:
        bar:
          bar:
            gee:
              continue.toto 499

  foo:
    bar:
      gee:
        return "all_executed"

  unreachable

test2:
  foo := :
    if it < 0: continue.foo it - 1
    continue.foo it + 1
    unreachable

  expect_equals -2 (foo.call -1)
  expect_equals 499 (foo.call 498)

  bar := ::
    if it < 0: continue.bar it - 2
    continue.bar it + 2
    unreachable

  expect_equals -3 (bar.call -1)
  expect_equals 499 (bar.call 497)

  return "all_executed"

test3:
  // 1000 from toto
  //    0 - 0: skips
  //    3 - 1: 1 + 1 and then +1 inside foo
  //    0 - 2: skips
  //    4 - 3: hits `continue.foo 3` (then incremented by 1 in foo)
  //    0 - 4: skips
  //    7 - 5: 5 + 1 and then +1 inside foo
  //    0 - 6: skips
  //    9 - 7: 7 + 1 and then +1 inside foo
  //    0 - 8 skips
  //    4 - 9: hits `continue.foo 3` (then incremented by 1 in foo)
  // ----
  // 1027
  expect_equals 1027
    toto::
      sum := 0
      10.repeat: |x|
        if x % 2 == 0: continue.repeat
        sum += foo:
          if x % 3 == 0: continue.foo 3 // Returns 3 (incremented by 1)
          expect ([1, 5, 7].contains x)
          x + 1  // Returns 3, 7, 9, which is then incremented by 1 by `foo`.
      sum

  return "all_executed"

named [--name1] [--name2] x y: return (name1.call x) + (name2.call y)

test4:
  expect_equals 499
    named 1 2
      --name1=:
        if it == 1:
          continue.named 400
        unreachable
      --name2=:
        if it == 2:
          continue.named 99
        unreachable
  return "all_executed"

class A:
  foo [block]: return block.call + 1
  bar [block]: return block.call + 10
  gee [block]: return block.call + 100

test5:
  // Check that return-to also works for instance functions.
  a := A
  expect_equals 18
    a.foo:
      a.bar:
        a.gee: continue.bar 7

  expect_equals 117
    a.foo:
      a.bar:
        a.gee: continue.gee 6

  expect_equals 18
    a.foo:
      a.bar:
        while true:
          a.gee: continue.bar 7

main:
  expect_equals "all_executed" test1
  expect_equals "all_executed" test2
  expect_equals "all_executed" test3
  expect_equals "all_executed" test4
