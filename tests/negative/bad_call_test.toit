// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class A:
  constructor:
    super
    super foo := 0
    print foo

  constructor.named:
    print
      super foo := 0
    print foo

  constructor.factory:
    print
      super foo := 0
    print foo
    return A

  static method:
    super foo := 0
    print foo

main:
  foo foo := 0
  debug foo
