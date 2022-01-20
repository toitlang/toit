// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

// When checking whether an implicit 'super' call is needed in the constructor,
//   we must not visit global/static fields (resolved as 'Method') that are the
//   left-hand side of assignments.
// See #1564.

global := null
class A:
  static a_ := null
  constructor:
    a_ = this

  constructor.named:
    global = this

main:
  a0 := A
  a1 := A.named
  // These checks aren't really necessary. If the program doesn't
  //   crash, we fixed the problem.
  expect_equals a0 A.a_
  expect_equals a1 global
