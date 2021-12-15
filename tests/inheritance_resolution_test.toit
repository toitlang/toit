// Copyright (C) 2018 Toitware ApS. All rights reserved.

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
