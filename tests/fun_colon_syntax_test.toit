// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

foo:
  return 42

foo x:
  return x + 1

foo [y]:
  return y.call 123

bar
    x:
 return 40 + x

bar
    [y]:
  return y.call 499

bar
    x y z
 :
 return x + y +z

gee arg1
    arg2
    arg3
    arg4:
  return arg1 + arg2 + arg3 + arg4

main:
  expect_equals 42 foo
  expect_equals 499 (foo 498)
  expect_equals 120 (foo: it - 3)
  expect_equals 42 (bar 2)
  expect_equals -499 (bar: -it)
  expect_equals 10 (gee 1 2 3 4)
