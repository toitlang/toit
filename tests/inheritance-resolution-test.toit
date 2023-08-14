// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

class A:
  foo := 499
  bar:
    return 42

class B extends A:
  invoke-foo:
    return foo

  invoke-bar:
    return bar

main:
  b := B
  expect-equals 499 b.invoke-foo
  expect-equals 42 b.invoke-bar
