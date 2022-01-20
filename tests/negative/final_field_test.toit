// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class A:
  field ::= null
  constructor:
    super
    field = 499
    unresolved

  constructor.named:
    foo 1
    field = 499
    unresolved

  constructor.named2:
    foo (if true: field = 499)
    unresolved

  constructor.named3:
    field = foo 499
    unresolved

  constructor.named4 arg:
    if arg:
      field--  // A hidden assignment.
    else:
      foo 12

  foo x:
    "instance method"

main:
  a := A
  a = A.named
  a = A.named2
  a = A.named3
