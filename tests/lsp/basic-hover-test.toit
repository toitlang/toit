// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
This is a class.
*/
class A:
  /**
  This is a field.
  */
  field := 42

  constructor:

  /**
  This is a method.
  */
  foo:
    return 499

  /**
  This is a named constructor.
  */
  constructor.named:

main:
  a := A
  /*   ^
This is a class.
  */

  a.foo
  /*^
This is a method.
  */

  a.field
  /*  ^
This is a field.
  */

  b := A.named
  /*     ^
This is a named constructor.
  */
