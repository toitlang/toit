// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

interface I:
  /** Doc for I.foo */
  foo

class A implements I:
  /** Doc for A.foo */
  foo: return 42

main:
  i/I := A
  i.foo
  /*^
Doc for I.foo
  */

  a := A
  a.foo
  /*^
Doc for A.foo
  */
