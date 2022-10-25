// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .constructor_receiver2_test as prefix

class A:
  static FOO ::= 499

  constructor x:

class B:
  static FOO ::= 42

class C:
  foo: 42

class D:
  constructor.named:

  static FOO ::= 42

main:
  print A.FOOO
  print B.FOOO
  print C.foo
  print D.FOOO

  print prefix.A.FOOO
  print prefix.B.FOOO
  print prefix.C.foo
  print prefix.D.FOOO
