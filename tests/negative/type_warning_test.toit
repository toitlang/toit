// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class A:
  gee x/B:

class B:
  bar x/B:

foo b/B -> A:
  return b

class C:
  x /A := ?
  constructor:
    x = B

interface I:

class D implements I:

main:
  a := A
  b := B
  a.gee a
  a.bar a
  b.gee a
  b.bar a
  b = foo a
  c := C
  (D is I).foo
  (A is B).foo
  (not c).foo
  (a or a).foo
  (b and b).foo

  unresolved
