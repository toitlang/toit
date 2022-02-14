// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

class A:
  foo := 499
  bar:
    return 42

class B extends A:
  invoke_foo:
    return foo

  invoke_bar:
    return bar

main:
  b := B
  expect_equals 499 b.invoke_foo
  expect_equals 42 b.invoke_bar
