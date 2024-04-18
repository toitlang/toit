// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class A:
  static foo:
    super
    unresolved1
  constructor:
    super
    unresolved2
    return A.named
  constructor.named:

main:
  a := A
