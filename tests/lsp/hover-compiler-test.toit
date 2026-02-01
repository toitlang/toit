// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
My class.
*/
class A:
  /**
  My method.
  */
  foo:

  /**
  My constructor.
  */
  constructor --x/int:

  constructor:

  /**
  Named constructor.
  */
  constructor.named:

  /**
  Static method.
  */
  static bar:

  /**
  My field.
  */
  my-field := 0

/**
My global function.
*/
my-global:

main:
  a := A
  a.foo
/*  ^
My method.
*/

  my-global
/*^
My global function.
*/

  A --x=42
/*^
My constructor.
*/

  A.named
/*  ^
Named constructor.
*/

  A.bar
/*  ^
Static method.
*/

no-doc-global:

test-no-doc:
  no-doc-global
/*^
```toit
no-doc-global
```
*/

