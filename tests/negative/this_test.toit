// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

bar x:
  return x

class A:
  foo:
    return 499

  constructor:
    foo
    super

  constructor.named:
    bar this
    super

  field := foo
  field2 := bar this

  static gee:
    return this + foo

main:
  a := A
