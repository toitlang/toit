// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests that 'Object' methods are completed for mixin types.
*/

mixin M1:
  foo:

class A extends Object with M1:

foo:
  a/M1 := A
  a.stringify
/*  ^~~~~~~~~
  + stringify, foo
*/

  a2 := A
  a.foo
/*  ^~~
  + stringify, foo
*/
